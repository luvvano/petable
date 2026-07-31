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

@Suite("Декомпозиция: fan-out → дети → join (слайс 8)")
struct DecomposeTests {
    private let t0 = Date(timeIntervalSince1970: 11000)

    /// Организация: флоу «Фича» = Архитектор(decompose) → Join;
    /// подзадачи типа «Задача» едут дефолтным линейным флоу.
    private func makeWorld(
        claudeScripts: [[AgentEvent]],
        codexScripts: [[AgentEvent]],
        github: GitHubClient = GitHubClient()
    ) throws -> (DaemonCore, Organization, OrgTask, EventStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("petable-decompose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = EventStore(root: root)

        var org = Organization.makeDefault()
        let architect = OrganizationPresets.preset("architect")!.makeEmployee()
        org.employees.append(architect)
        let join = OrgStage(name: "Слияние", kind: .join)
        let decompose = OrgStage(
            name: "Архитектор", kind: .decompose, employeeID: architect.id, next: [join.id]
        )
        let featureFlow = OrgFlow(name: "Фича", stages: [decompose, join])
        let featureType = OrgTaskType(name: "Фича")
        org.flows.append(featureFlow)
        org.taskTypes.append(featureType)
        org.routes.append(OrgRoute(taskTypeID: featureType.id, flowID: featureFlow.id))

        let backend = RepoRef(name: "backend", path: "/nonexistent/backend")
        let frontend = RepoRef(name: "frontend", path: "/nonexistent/frontend")
        org.repos = [backend, frontend]

        let task = OrgTask(
            title: "Большая фича", taskTypeID: featureType.id, repoID: backend.id, jiraKey: "DN-9"
        )
        org.tasks = [task]

        #expect(featureFlow.validate().isEmpty)

        let core = DaemonCore(
            store: store,
            registry: AdapterRegistry([
                QueueAdapter(cliID: "claude", scripts: claudeScripts),
                QueueAdapter(cliID: "codex", scripts: codexScripts),
            ]),
            github: github,
            now: { self.t0 }
        )
        return (core, org, task, store)
    }

    private func send<T: Codable>(_ core: DaemonCore, _ type: WireType, _ payload: T) async throws {
        try await core.handle(WireEnvelope.pack(type, payload))
    }

    @Test("Fan-out: архитектор порождает 2 подзадачи, дети едут своим флоу, родитель ждёт и мёржится после детей")
    func fullFanOut() async throws {
        let decomposeVerdict = Verdict(
            status: .done,
            subtasks: [
                .init(title: "API экспорта", taskType: "Задача", repo: "backend"),
                .init(title: "Экран экспорта", taskType: "Задача", repo: "frontend"),
            ]
        )
        let done: [AgentEvent] = [.finished(Verdict(status: .done), usage: AgentUsage())]
        let (core, org, task, _) = try makeWorld(
            claudeScripts: [
                [.finished(decomposeVerdict, usage: AgentUsage())], // архитектор
                done, // work ребёнка 1
                done, // work ребёнка 2
            ],
            codexScripts: [done, done] // ревью обоих детей
        )
        try await send(core, .startRun, StartRunCommand(organization: org, taskID: task.id))
        let parentID = try #require(await core.runID(forTask: task.id))
        var parent = try #require(await core.run(parentID))
        #expect(parent.status == .waitingChildren)
        #expect(parent.currentStage?.kind == .join)
        let childIDs = try #require(parent.childRunIDs)
        #expect(childIDs.count == 2)

        // Дети доехали до финального гейта и несут родителя/ключи.
        for (index, childID) in childIDs.enumerated() {
            let child = try #require(await core.run(childID))
            #expect(child.parentRunID == parentID)
            #expect(child.status == .waitingGate)
            #expect(child.task.jiraKey == "DN-9.\(index + 1)")
        }
        var repos: Set<String> = []
        for childID in childIDs {
            if let name = await core.run(childID)?.repo.name { repos.insert(name) }
        }
        #expect(repos == ["backend", "frontend"])

        // Принять первого — родитель всё ещё ждёт второго.
        try await send(core, .approve, childIDs[0])
        parent = try #require(await core.run(parentID))
        #expect(parent.status == .waitingChildren)

        // Принять второго — родитель мёржится.
        try await send(core, .approve, childIDs[1])
        parent = try #require(await core.run(parentID))
        #expect(parent.status == .finished)
        #expect(parent.outcome == .merged)
    }

    @Test("Декомпозиция без подзадач → требует внимания, не пустой join")
    func emptyDecomposition() async throws {
        let (core, org, task, _) = try makeWorld(
            claudeScripts: [[.finished(Verdict(status: .done, subtasks: []), usage: AgentUsage())]],
            codexScripts: []
        )
        try await send(core, .startRun, StartRunCommand(organization: org, taskID: task.id))
        let parentID = try #require(await core.runID(forTask: task.id))
        let parent = try #require(await core.run(parentID))
        #expect(parent.status == .needsAttention)
        #expect(parent.statusReason.contains("без подзадач"))
    }

    @Test("Отмена ребёнка → родитель «требует внимания», не вечное ожидание")
    func cancelledChildAlertsParent() async throws {
        let decomposeVerdict = Verdict(
            status: .done,
            subtasks: [.init(title: "Единственная", taskType: "Задача", repo: "backend")]
        )
        let done: [AgentEvent] = [.finished(Verdict(status: .done), usage: AgentUsage())]
        let (core, org, task, _) = try makeWorld(
            claudeScripts: [[.finished(decomposeVerdict, usage: AgentUsage())], done],
            codexScripts: [done]
        )
        try await send(core, .startRun, StartRunCommand(organization: org, taskID: task.id))
        let parentID = try #require(await core.runID(forTask: task.id))
        let childID = try #require(await core.run(parentID)?.childRunIDs?.first)

        try await send(core, .cancel, childID)
        let parent = try #require(await core.run(parentID))
        #expect(parent.status == .needsAttention)
        #expect(parent.statusReason.contains("не merge"))
    }

    @Test("Правка №5: подзадача с незнакомым репо — репозиторий создаётся через GitHub (фейк) и клонируется в хранилище")
    func decomposeCreatesRepo() async throws {
        // Живой git-источник — «GitHub» отдаёт его путь как clone_url.
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("petable-ghsrc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        _ = DaemonCore.shell(
            "git init -q -b main && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init",
            cwd: src
        )

        let decomposeVerdict = Verdict(
            status: .done,
            subtasks: [.init(title: "Новый сервис", taskType: "Задача", repo: "svc-new")]
        )
        let done: [AgentEvent] = [.finished(Verdict(status: .done), usage: AgentUsage())]
        let (core, org, task, store) = try makeWorld(
            claudeScripts: [[.finished(decomposeVerdict, usage: AgentUsage())], done],
            codexScripts: [done],
            github: GitHubClient(transport: FakeGitHubTransport(cloneURL: src.path))
        )
        try await send(core, .configure, ConfigureCommand(githubToken: "t"))
        try await send(core, .startRun, StartRunCommand(organization: org, taskID: task.id))

        let parentID = try #require(await core.runID(forTask: task.id))
        let childID = try #require(await core.run(parentID)?.childRunIDs?.first)
        let child = try #require(await core.run(childID))
        #expect(child.repo.name == "svc-new")
        #expect(child.repo.path.hasPrefix(
            store.root.appendingPathComponent("repos").path
        ))
        #expect(FileManager.default.fileExists(atPath: child.repo.path + "/.git"))
    }
}

/// «GitHub», отдающий фиксированный clone_url на createRepo.
private final class FakeGitHubTransport: JiraHTTPTransport, @unchecked Sendable {
    let cloneURL: String

    init(cloneURL: String) {
        self.cloneURL = cloneURL
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        (Data("{\"clone_url\":\"\(cloneURL)\"}".utf8), 201)
    }
}
