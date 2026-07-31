import Foundation
import Testing
import AgentRuntime
@testable import OrgEngine
import GraphCore

/// Адаптер с очередью сценариев (по одному на вызов).
private final class QueueAdapter: AgentAdapter, @unchecked Sendable {
    let cliID: String
    private let lock = NSLock()
    private var scripts: [[AgentEvent]]

    init(cliID: String, scripts: [[AgentEvent]]) {
        self.cliID = cliID
        self.scripts = scripts
    }

    func run(_ request: AgentRequest) -> AsyncStream<AgentEvent> {
        lock.lock()
        let script = scripts.isEmpty ? [AgentEvent.failed("сценарии кончились")] : scripts.removeFirst()
        lock.unlock()
        return AsyncStream { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// Адаптер, запоминающий модель каждого запроса.
private final class ModelSpyAdapter: AgentAdapter, @unchecked Sendable {
    let cliID: String
    private let lock = NSLock()
    private(set) var models: [String] = []

    init(cliID: String) {
        self.cliID = cliID
    }

    func run(_ request: AgentRequest) -> AsyncStream<AgentEvent> {
        lock.lock()
        models.append(request.config.model)
        lock.unlock()
        return AsyncStream { continuation in
            continuation.yield(.finished(Verdict(status: .done), usage: AgentUsage()))
            continuation.finish()
        }
    }

    func recordedModels() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return models
    }
}

@Suite("Тени и форки: experimental-запуски (слайсы 12–13)")
struct ShadowForkTests {
    private let t0 = Date(timeIntervalSince1970: 13000)

    private func makeWorld(
        claudeScripts: [[AgentEvent]],
        codexScripts: [[AgentEvent]]
    ) throws -> (DaemonCore, Organization, OrgTask, EventStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("petable-shadow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = EventStore(root: root)
        var org = Organization.makeDefault()
        let repo = RepoRef(name: "demo", path: "/nonexistent/demo")
        org.repos = [repo]
        let task = OrgTask(
            title: "Экспорт", taskTypeID: org.taskTypes[0].id, repoID: repo.id,
            source: .jira, jiraKey: "DN-3"
        )
        org.tasks = [task]
        let core = DaemonCore(
            store: store,
            registry: AdapterRegistry([
                QueueAdapter(cliID: "claude", scripts: claudeScripts),
                QueueAdapter(cliID: "codex", scripts: codexScripts),
            ]),
            now: { self.t0 }
        )
        return (core, org, task, store)
    }

    private func send<T: Codable>(_ core: DaemonCore, _ type: WireType, _ payload: T) async throws {
        try await core.handle(WireEnvelope.pack(type, payload))
    }

    @Test("Тень: едет по экспериментальному флоу, ветка org/shadow/, Принять на merge — закрыто, НЕ merged; primary приоритетнее в runID(forTask:)")
    func shadowRunLifecycle() async throws {
        let done: [AgentEvent] = [.finished(Verdict(status: .done), usage: AgentUsage())]
        let (core, org, task, _) = try makeWorld(
            claudeScripts: [done, done], codexScripts: [done, done]
        )
        // Primary доезжает до финального гейта.
        try await send(core, .startRun, StartRunCommand(organization: org, taskID: task.id))
        let primaryID = try #require(await core.runID(forTask: task.id))

        // Тень по тому же флоу (экспериментальный выбор v1 — любой флоу).
        try await send(core, .shadowRun, ShadowRunCommand(
            organization: org, taskID: task.id, flowID: org.flows[0].id
        ))
        // Primary всё ещё главный ответ на runID(forTask:).
        #expect(await core.runID(forTask: task.id) == primaryID)

        let shadow = try #require(await core.allRuns().first(where: { $0.isExperimental }))
        #expect(shadow.shadowOf == primaryID)
        #expect(shadow.branchName.hasPrefix("org/shadow/"))
        #expect(shadow.status == .waitingGate)
        #expect(shadow.currentStage?.kind == .merge)

        // Принять на experimental: закрыт итогом, merge недостижим.
        try await send(core, .approve, shadow.id)
        let settled = try #require(await core.run(shadow.id))
        #expect(settled.status == .finished)
        #expect(settled.outcome == .closed)
        #expect(settled.summary?.experimental == true)

        // Primary не пострадал: Принять — настоящий merge.
        try await send(core, .approve, primaryID)
        #expect(await core.run(primaryID)?.outcome == .merged)
    }

    @Test("Fork (⌥Enter): с текущего этапа, override модели у всех сотрудников, experimental")
    func forkOverridesModel() async throws {
        let claude = ModelSpyAdapter(cliID: "claude")
        let codex = ModelSpyAdapter(cliID: "codex")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("petable-fork-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = EventStore(root: root)
        var org = Organization.makeDefault()
        let repo = RepoRef(name: "demo", path: "/nonexistent/demo")
        org.repos = [repo]
        let task = OrgTask(title: "Экспорт", taskTypeID: org.taskTypes[0].id, repoID: repo.id)
        org.tasks = [task]
        let core = DaemonCore(
            store: store,
            registry: AdapterRegistry([claude, codex]),
            now: { self.t0 }
        )

        try await core.handle(WireEnvelope.pack(
            .startRun, StartRunCommand(organization: org, taskID: task.id)
        ))
        let primaryID = try #require(await core.runID(forTask: task.id))
        #expect(await core.run(primaryID)?.status == .waitingGate) // merge-гейт

        try await core.handle(WireEnvelope.pack(
            .forkRun, ForkRunCommand(runID: primaryID, model: "opus-x")
        ))
        let fork = try #require(await core.allRuns().first(where: { $0.forkOf == primaryID }))
        #expect(fork.isExperimental)
        #expect(fork.branchName.hasPrefix("org/fork/"))
        #expect(fork.employees.allSatisfy { $0.adapter.model == "opus-x" })
        // Источник на merge-гейте → форк тоже ждёт гейта (вход в merge = гейт).
        #expect(fork.status == .waitingGate)

        // Принять форк: закрыт, НЕ merged; primary независим.
        try await core.handle(WireEnvelope.pack(.approve, fork.id))
        #expect(await core.run(fork.id)?.outcome == .closed)
        #expect(await core.run(primaryID)?.status == .waitingGate)
    }
}
