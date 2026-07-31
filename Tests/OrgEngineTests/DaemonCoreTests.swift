import Foundation
import Testing
import AgentRuntime
@testable import OrgEngine
import GraphCore

/// Скриптованный адаптер: очередь сценариев по одному на каждый вызов —
/// «сотрудник» отвечает по-разному на повторных этапах.
private final class ScriptedAdapter: AgentAdapter, @unchecked Sendable {
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

@Suite("DaemonCore: пустой конвейер (слайс 2/3)")
struct DaemonCoreTests {
    private let t0 = Date(timeIntervalSince1970: 9000)

    private func makeWorld(
        claudeScripts: [[AgentEvent]],
        codexScripts: [[AgentEvent]]
    ) throws -> (DaemonCore, Organization, OrgTask, EventStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("petable-daemon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = EventStore(root: root)
        var org = Organization.makeDefault()
        // Репозиторий-фантом: git-ветка DaemonCore выключается, тесты
        // гоняют чистую оркестрацию (git покрыт WorktreeManagerTests).
        let repo = RepoRef(name: "demo", path: "/nonexistent/demo")
        org.repos = [repo]
        let task = OrgTask(
            title: "Экспорт", taskTypeID: org.taskTypes[0].id, repoID: repo.id, jiraKey: "DN-2"
        )
        org.tasks = [task]
        let core = DaemonCore(
            store: store,
            registry: AdapterRegistry([
                ScriptedAdapter(cliID: "claude", scripts: claudeScripts),
                ScriptedAdapter(cliID: "codex", scripts: codexScripts),
            ]),
            now: { self.t0 }
        )
        return (core, org, task, store)
    }

    private func send<T: Codable>(_ core: DaemonCore, _ type: WireType, _ payload: T) async throws {
        try await core.handle(WireEnvelope.pack(type, payload))
    }

    @Test("Сквозной прогон: startRun → work → review → тесты(пусто) → гейт → Принять → merged; события дошли до подписчика")
    func endToEnd() async throws {
        let done: [AgentEvent] = [
            .started(sessionID: "s"),
            .finished(Verdict(status: .done), usage: AgentUsage(costEstimate: 0.1)),
        ]
        let (core, org, task, store) = try makeWorld(
            claudeScripts: [done], codexScripts: [done]
        )
        let states = StateCollector()
        await core.subscribe { states.collect($0) }

        try await send(core, .startRun, StartRunCommand(organization: org, taskID: task.id))
        let runID = try #require(await core.runID(forTask: task.id))
        var run = try #require(await core.run(runID))
        #expect(run.status == .waitingGate)
        #expect(run.currentStage?.kind == .merge)
        #expect(run.costEstimate == 0.2)

        try await send(core, .approve, run.id)
        run = try #require(await core.run(run.id))
        #expect(run.status == .finished)
        #expect(run.outcome == .merged)

        // Подписчик видел путь состояний.
        let seen = states.runStates()
        #expect(seen.contains { $0.status == .waitingGate })
        #expect(seen.last?.status == .finished)

        // Журнал восстановит терминальное состояние.
        guard case let .events(events) = store.load(orgID: run.orgID, runID: run.id) else {
            Issue.record("журнал не читается")
            return
        }
        #expect(EventStore.restoreRun(from: events)?.outcome == .merged)
        // Реконсиляция документа.
        var document = org
        document.reconcile(summaries: store.summaries(orgID: org.orgID))
        #expect(document.runSummaries.map(\.outcome) == [.merged])
    }

    @Test("Ревьюер вернул → work перезапущен → done → merged; счётчик = 1")
    func reviewReturnLoop() async throws {
        let done: [AgentEvent] = [.finished(Verdict(status: .done), usage: AgentUsage())]
        let (core, org, task, _) = try makeWorld(
            claudeScripts: [done, done], // work, повторный work
            codexScripts: [
                [.finished(Verdict(status: .changesRequested, note: "нет тестов"), usage: AgentUsage())],
                done, // повторное ревью
            ]
        )
        try await send(core, .startRun, StartRunCommand(organization: org, taskID: task.id))
        let runID = try #require(await core.runID(forTask: task.id))
        var run = try #require(await core.run(runID))
        #expect(run.returnCount == 1)
        #expect(run.status == .waitingGate)
        try await send(core, .approve, run.id)
        run = try #require(await core.run(run.id))
        #expect(run.outcome == .merged)
    }

    @Test("Reject с гейта: комментарий уходит причиной возврата в повторный work")
    func rejectFromGate() async throws {
        let done: [AgentEvent] = [.finished(Verdict(status: .done), usage: AgentUsage())]
        let (core, org, task, _) = try makeWorld(
            claudeScripts: [done, done],
            codexScripts: [done, done]
        )
        try await send(core, .startRun, StartRunCommand(organization: org, taskID: task.id))
        let runID = try #require(await core.runID(forTask: task.id))
        try await send(core, .reject, ChatCommand(runID: runID, text: "не тот экран"))
        let run = try #require(await core.run(runID))
        // Возврат прогнал конвейер заново до гейта.
        #expect(run.returnCount == 1)
        #expect(run.status == .waitingGate)
    }

    @Test("cannotComplete → требует внимания; чат разблокирует и доводит до гейта (П9)")
    func chatUnblocksAttention() async throws {
        let done: [AgentEvent] = [.finished(Verdict(status: .done), usage: AgentUsage())]
        let (core, org, task, _) = try makeWorld(
            claudeScripts: [
                [.finished(Verdict(status: .cannotComplete, note: "не хватает контекста"), usage: AgentUsage())],
                done, // рестарт-с-контекстом после чата
            ],
            codexScripts: [done]
        )
        try await send(core, .startRun, StartRunCommand(organization: org, taskID: task.id))
        let runID = try #require(await core.runID(forTask: task.id))
        var run = try #require(await core.run(runID))
        #expect(run.status == .needsAttention)

        try await send(core, .chat, ChatCommand(runID: runID, text: "контекст: поле называется exportedAt"))
        run = try #require(await core.run(runID))
        #expect(run.status == .waitingGate) // дошёл до финального гейта
    }

    @Test("Отмена терминальна; незнакомый Wire-тип игнорируется (дрейф протокола)")
    func cancelAndUnknownType() async throws {
        let (core, org, task, _) = try makeWorld(
            claudeScripts: [[.finished(Verdict(status: .cannotComplete), usage: AgentUsage())]],
            codexScripts: []
        )
        try await send(core, .startRun, StartRunCommand(organization: org, taskID: task.id))
        let runID = try #require(await core.runID(forTask: task.id))
        try await send(core, .cancel, runID)
        let run = try #require(await core.run(runID))
        #expect(run.outcome == .cancelled)

        let unknown = WireEnvelope(type: "quantumRun", payload: Data("{}".utf8))
        try await core.handle(JSONEncoder().encode(unknown)) // не бросает
    }

    @Test("Оркестратор на старте: тип без маршрута — LLM выбирает флоу по типу и Jira-статусу; задача едет")
    func orchestratorPicksFlow() async throws {
        let done: [AgentEvent] = [.finished(Verdict(status: .done), usage: AgentUsage())]
        let pick: [AgentEvent] = [
            .finished(Verdict(status: .done, note: "беру Хотфикс"), usage: AgentUsage()),
        ]
        let (core, org, task, _) = try makeWorld(
            claudeScripts: [pick, done], codexScripts: []
        )
        var custom = org
        let developer = custom.employees[0]
        let merge = OrgStage(name: "Merge", kind: .merge, gate: .human)
        let work = OrgStage(name: "Фикс", kind: .work, employeeID: developer.id, next: [merge.id])
        custom.flows.append(OrgFlow(name: "Хотфикс", stages: [work, merge]))
        let bugType = OrgTaskType(name: "Баг") // маршрута на флоу НЕТ
        custom.taskTypes.append(bugType)
        custom.tasks[0].taskTypeID = bugType.id
        custom.tasks[0].jiraStatus = "In Progress"

        try await send(core, .startRun, StartRunCommand(organization: custom, taskID: task.id))
        let runID = try #require(await core.runID(forTask: task.id))
        let run = try #require(await core.run(runID))
        #expect(run.flow.name == "Хотфикс")
        #expect(run.status == .waitingGate)
        #expect(run.currentStage?.kind == .merge)
    }

    @Test("Переписка этапа персистентна (П9): chat и комментарий Вернуть пишутся в журнал chatMessage-событиями")
    func chatPersistsInJournal() async throws {
        let done: [AgentEvent] = [.finished(Verdict(status: .done), usage: AgentUsage())]
        let (core, org, task, store) = try makeWorld(
            claudeScripts: [done, done, done], codexScripts: [done, done]
        )
        try await send(core, .startRun, StartRunCommand(organization: org, taskID: task.id))
        let runID = try #require(await core.runID(forTask: task.id))
        #expect(await core.run(runID)?.status == .waitingGate) // merge-гейт

        try await send(core, .reject, ChatCommand(runID: runID, text: "поправь отступы"))
        // Возврат довёл до гейта снова — чат с гейта.
        try await send(core, .chat, ChatCommand(runID: runID, text: "и переименуй функцию"))

        let run = try #require(await core.run(runID))
        guard case let .events(events) = store.load(orgID: run.orgID, runID: runID) else {
            Issue.record("журнал не читается")
            return
        }
        let messages = events
            .filter { $0.kindValue == .chatMessage }
            .compactMap(\.text)
        #expect(messages == ["поправь отступы", "и переименуй функцию"])
    }

    @Test("Оркестратор: валидных флоу нет совсем — линейная запаска из пресетов, запуск не блокируется")
    func orchestratorFallbackFlow() async throws {
        let done: [AgentEvent] = [.finished(Verdict(status: .done), usage: AgentUsage())]
        let (core, org, task, _) = try makeWorld(
            claudeScripts: [done], codexScripts: [done]
        )
        var custom = org
        custom.flows = [OrgFlow(name: "Битый", stages: [])]
        custom.routes = [OrgRoute(taskTypeID: custom.taskTypes[0].id, flowID: custom.flows[0].id)]

        try await send(core, .startRun, StartRunCommand(organization: custom, taskID: task.id))
        let runID = try #require(await core.runID(forTask: task.id))
        let run = try #require(await core.run(runID))
        #expect(run.flow.name.contains("запаска"))
        #expect(run.status == .waitingGate)
        #expect(run.currentStage?.kind == .merge)
    }

    @Test("Drain (П0): новые этапы не начинаются, drained уходит подписчику; recoverAll свежего демона доводит запуск")
    func drainThenRecoverAll() async throws {
        let done: [AgentEvent] = [.finished(Verdict(status: .done), usage: AgentUsage())]
        let (core, org, task, store) = try makeWorld(
            claudeScripts: [done], codexScripts: [done]
        )
        let states = StateCollector()
        await core.subscribe { states.collect($0) }

        try await send(core, .drain, 0)
        #expect(states.drainedCount() == 1) // этапов нет — drained сразу

        try await send(core, .startRun, StartRunCommand(organization: org, taskID: task.id))
        let runID = try #require(await core.runID(forTask: task.id))
        let run = try #require(await core.run(runID))
        #expect(run.status == .running)   // остался на старте:
        #expect(run.path.count == 1)      // drain не пустил в первый этап
        #expect(states.drainedCount() >= 2)

        // «Рестарт демона»: свежее ядро с теми же журналами — recoverAll
        // поднимает запуск и доводит до финального гейта.
        let fresh = DaemonCore(
            store: store,
            registry: AdapterRegistry([
                ScriptedAdapter(cliID: "claude", scripts: [done]),
                ScriptedAdapter(cliID: "codex", scripts: [done]),
            ]),
            now: { self.t0 }
        )
        await fresh.recoverAll()
        let recovered = try #require(await fresh.run(runID))
        #expect(recovered.status == .waitingGate)
        #expect(recovered.currentStage?.kind == .merge)
    }
}

/// Сбор Wire-событий подписчика (EventSink приложения).
private final class StateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [Data] = []

    func collect(_ data: Data) {
        lock.lock()
        messages.append(data)
        lock.unlock()
    }

    func runStates() -> [OrganizationRun] {
        lock.lock()
        defer { lock.unlock() }
        return messages.compactMap { data in
            guard let (type, envelope) = try? WireEnvelope.unpack(data), type == .runState,
                  let message = try? envelope.payload(as: RunStateMessage.self)
            else { return nil }
            return message.run
        }
    }

    func drainedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return messages.filter { data in
            (try? WireEnvelope.unpack(data))?.type == .drained
        }.count
    }
}
