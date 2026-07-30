import Foundation
import Testing
import AgentRuntime
@testable import OrgEngine
import GraphCore

/// FakeAdapter (решение 5A): скриптованные события вместо Process —
/// вся оркестрация этапа гоняется в памяти за миллисекунды.
private struct FakeAdapter: AgentAdapter {
    let cliID: String
    let script: [AgentEvent]

    func run(_ request: AgentRequest) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish()
        }
    }
}

@Suite("StageRunner: оркестрация этапа на FakeAdapter")
struct StageRunnerTests {
    private let t0 = Date(timeIntervalSince1970: 5000)

    private func makeRun() -> OrganizationRun {
        var org = Organization.makeDefault()
        let repo = RepoRef(name: "demo", path: "/tmp/demo")
        org.repos = [repo]
        let task = OrgTask(
            title: "Экспорт", details: "детали",
            taskTypeID: org.taskTypes[0].id, repoID: repo.id, jiraKey: "DN-1"
        )
        return try! Engine.startRun(organization: org, task: task, now: t0)
    }

    private func makeStore() throws -> EventStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("petable-runner-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return EventStore(root: root)
    }

    private func runner(_ store: EventStore, script: [AgentEvent], cli: String = "claude") -> StageRunner {
        StageRunner(
            store: store,
            registry: AdapterRegistry([FakeAdapter(cliID: cli, script: script)]),
            now: { self.t0 }
        )
    }

    @Test("done: сессия запомнена, стоимость накоплена, переход к ревью, слепок в журнале")
    func doneAdvances() async throws {
        let store = try makeStore()
        let run = makeRun()
        let script: [AgentEvent] = [
            .started(sessionID: "sess-1"),
            .log("пишу код"),
            .finished(Verdict(status: .done), usage: AgentUsage(outputTokens: 10, costEstimate: 0.25)),
        ]
        let result = await runner(store, script: script)
            .runCurrentStage(run, worktree: URL(fileURLWithPath: "/tmp")).run

        #expect(result.currentStage?.kind == .review)
        #expect(result.status == .running)
        #expect(result.costEstimate == 0.25)
        #expect(result.stageSessions[run.currentStageID] == "sess-1")

        guard case let .events(events) = store.load(orgID: run.orgID, runID: run.id) else {
            Issue.record("журнал не читается")
            return
        }
        let kinds = events.compactMap(\.kindValue)
        #expect(kinds.contains(.stageStarted))
        #expect(kinds.contains(.log))
        #expect(kinds.contains(.stageFinished))
        #expect(kinds.contains(.snapshot))
        #expect(EventStore.restoreRun(from: events) == result)
    }

    @Test("needsInput: этап останавливается в «требует внимания», вопрос в журнале")
    func needsInputStops() async throws {
        let store = try makeStore()
        let run = makeRun()
        let result = await runner(store, script: [
            .started(sessionID: "s"),
            .needsInput(prompt: "какой API-ключ?"),
        ]).runCurrentStage(run, worktree: URL(fileURLWithPath: "/tmp")).run

        #expect(result.status == .needsAttention)
        #expect(result.statusReason.contains("какой API-ключ?"))
        guard case let .events(events) = store.load(orgID: run.orgID, runID: run.id) else { return }
        #expect(events.compactMap(\.kindValue).contains(.needsInput))
        #expect(events.compactMap(\.kindValue).contains(.needsAttention))
    }

    @Test("failed и обрыв стрима без вердикта → требует внимания")
    func failures() async throws {
        let store = try makeStore()
        let run = makeRun()
        let failed = await runner(store, script: [.failed("процесс убит")])
            .runCurrentStage(run, worktree: URL(fileURLWithPath: "/tmp")).run
        #expect(failed.status == .needsAttention)
        #expect(failed.statusReason == "процесс убит")

        let hung = await runner(store, script: [.started(sessionID: "s")])
            .runCurrentStage(run, worktree: URL(fileURLWithPath: "/tmp")).run
        #expect(hung.status == .needsAttention)
        #expect(hung.statusReason.contains("без вердикта"))
    }

    @Test("CLI не установлен → «требует внимания» с именем исполнителя (матрица 4A)")
    func missingCLI() async throws {
        let store = try makeStore()
        let run = makeRun()
        let result = await runner(store, script: [], cli: "gemini")
            .runCurrentStage(run, worktree: URL(fileURLWithPath: "/tmp")).run
        #expect(result.status == .needsAttention)
        #expect(result.statusReason.contains("claude"))
    }

    @Test("Промпт: роль + задача + причина возврата + вердикт-блок; ревью — свой блок")
    func promptComposition() {
        var run = makeRun()
        run.statusReason = "нет тестов"
        let stage = run.currentStage!
        let employee = run.employee(for: stage)!
        let prompt = StageRunner.prompt(run: run, stage: stage, employee: employee, extra: "чат: поправь отступы")
        #expect(prompt.contains(employee.rolePrompt))
        #expect(prompt.contains("[DN-1]"))
        #expect(prompt.contains("Причина возврата: нет тестов"))
        #expect(prompt.contains("чат: поправь отступы"))
        #expect(prompt.contains(#""status""#))
        #expect(StageRunner.verdictInstruction(for: .review).contains("changesRequested"))
        #expect(StageRunner.verdictInstruction(for: .decompose).contains("subtasks"))
    }
}

@Suite("XPC-конверт (1A)")
struct WireTests {
    @Test("pack/unpack round-trip команды и состояния")
    func roundTrip() throws {
        var org = Organization.makeDefault()
        org.repos = [RepoRef(name: "r", path: "/tmp/r")]
        let command = StartRunCommand(organization: org, taskID: UUID())
        let data = try WireEnvelope.pack(.startRun, command)
        let (type, envelope) = try WireEnvelope.unpack(data)
        #expect(type == .startRun)
        #expect(envelope.v == WireEnvelope.protocolVersion)
        #expect(try envelope.payload(as: StartRunCommand.self) == command)
    }

    @Test("Незнакомый тип сообщения → nil-тип, не ошибка (minor-дрейф, П0)")
    func unknownTypeTolerated() throws {
        let envelope = WireEnvelope(type: "futureFeature", payload: Data("{}".utf8))
        let data = try JSONEncoder().encode(envelope)
        let (type, decoded) = try WireEnvelope.unpack(data)
        #expect(type == nil)
        #expect(decoded.type == "futureFeature")
    }
}
