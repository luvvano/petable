import Foundation
import Testing
import AgentRuntime
@testable import OrgEngine
import GraphCore

// MARK: - Швы

/// Скриптованный HTTP: запросы копятся, ответы выдаются по очереди.
private final class FakeTransport: JiraHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    private var responses: [(Data, Int)]

    init(_ responses: [(String, Int)]) {
        self.responses = responses.map { (Data($0.0.utf8), $0.1) }
    }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.withLock {
            requests.append(request)
            return responses.isEmpty ? (Data("{}".utf8), 200) : responses.removeFirst()
        }
    }
}

/// Фейковый шлюз Jira для DaemonCore: фиксирует эффекты.
private final class FakeJiraGateway: JiraGateway, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var comments: [(issueKey: String, body: String)] = []
    private(set) var transitioned: [String] = []
    var existingMarkers: Set<String> = []
    var failComments = false

    func addComment(_ config: JiraConfig, issueKey: String, body: String) async throws {
        try lock.withLock {
            if failComments { throw JiraError(statusCode: 500, message: "недоступна") }
            comments.append((issueKey, body))
        }
    }

    func hasComment(_ config: JiraConfig, issueKey: String, marker: String) async throws -> Bool {
        lock.withLock { existingMarkers.contains(marker) }
    }

    func transitionToDone(_ config: JiraConfig, issueKey: String) async throws {
        lock.withLock { transitioned.append(issueKey) }
    }

    func transitionBestMatch(
        _ config: JiraConfig, issueKey: String, hints: [String], category: String?
    ) async throws {
        lock.withLock { stageTransitions.append((issueKey, hints)) }
    }

    private(set) var stageTransitions: [(issueKey: String, hints: [String])] = []
}

private let config = JiraConfig(
    baseURL: "https://team.atlassian.net", email: "e@x.com", token: "tok"
)

// MARK: - Клиент

@Suite("JiraClient: REST v2 на фикстурах")
struct JiraClientTests {
    private let searchFixture = """
    {"issues":[
      {"key":"DN-101","fields":{"summary":"Починить парсер","description":"Детали",
       "issuetype":{"name":"Bug"},"project":{"key":"DN"}}},
      {"key":"OPS-7","fields":{"summary":"Фича","description":null,
       "issuetype":{"name":"Story"},"project":{"key":"OPS"}}}
    ]}
    """

    @Test("searchIssues: URL, basic-auth и разбор полей (null-описание не ломает)")
    func search() async throws {
        let transport = FakeTransport([(searchFixture, 200)])
        let issues = try await JiraClient(transport: transport)
            .searchIssues(config, jql: "project in (DN)")

        let request = try #require(transport.requests.first)
        let url = try #require(request.url?.absoluteString)
        // Новый endpoint /search/jql: старый /search удалён Atlassian
        // (HTTP 410, CHANGE-2046).
        #expect(url.hasPrefix("https://team.atlassian.net/rest/api/2/search/jql?"))
        #expect(url.contains("jql=project"))
        let auth = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(auth == "Basic \(Data("e@x.com:tok".utf8).base64EncodedString())")

        #expect(issues == [
            JiraIssue(key: "DN-101", summary: "Починить парсер", description: "Детали",
                      typeName: "Bug", projectKey: "DN"),
            JiraIssue(key: "OPS-7", summary: "Фича", description: "",
                      typeName: "Story", projectKey: "OPS"),
        ])
    }

    @Test("addComment: POST в issue/{key}/comment с телом {body}")
    func comment() async throws {
        let transport = FakeTransport([("{}", 201)])
        try await JiraClient(transport: transport)
            .addComment(config, issueKey: "DN-101", body: "готово")

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/rest/api/2/issue/DN-101/comment")
        let body = try JSONSerialization.jsonObject(
            with: try #require(request.httpBody)
        ) as? [String: String]
        #expect(body == ["body": "готово"])
    }

    @Test("hasComment: маркер найден в теле → true; нет → false")
    func hasComment() async throws {
        let page = """
        {"comments":[{"body":"шум"},{"body":"готово [petable:ABC]"}]}
        """
        let client = JiraClient(transport: FakeTransport([(page, 200), (page, 200)]))
        #expect(try await client.hasComment(config, issueKey: "DN-1", marker: "[petable:ABC]"))
        #expect(!(try await client.hasComment(config, issueKey: "DN-1", marker: "[petable:XYZ]")))
    }

    @Test("transitionToDone: выбирает переход категории done и постит его id")
    func transition() async throws {
        let transitions = """
        {"transitions":[
          {"id":"11","name":"In Progress","to":{"statusCategory":{"key":"indeterminate"}}},
          {"id":"31","name":"Готово","to":{"statusCategory":{"key":"done"}}}
        ]}
        """
        let transport = FakeTransport([(transitions, 200), ("{}", 204)])
        try await JiraClient(transport: transport).transitionToDone(config, issueKey: "DN-1")

        #expect(transport.requests.count == 2)
        let post = transport.requests[1]
        #expect(post.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(
            with: try #require(post.httpBody)
        ) as? [String: [String: String]]
        #expect(body == ["transition": ["id": "31"]])
    }

    @Test("transitionToDone: перехода в done нет (уже Done) — no-op, не ошибка")
    func transitionAbsent() async throws {
        let transport = FakeTransport([("{\"transitions\":[]}", 200)])
        try await JiraClient(transport: transport).transitionToDone(config, issueKey: "DN-1")
        #expect(transport.requests.count == 1)
    }

    @Test("transitionBestMatch: имя приоритетнее категории; регистронезависимо")
    func bestMatchByName() async throws {
        let transitions = """
        {"transitions":[
          {"id":"21","name":"На ревью","to":{"statusCategory":{"key":"indeterminate"}}},
          {"id":"11","name":"In Progress","to":{"statusCategory":{"key":"indeterminate"}}}
        ]}
        """
        let transport = FakeTransport([(transitions, 200), ("{}", 204)])
        try await JiraClient(transport: transport).transitionBestMatch(
            config, issueKey: "DN-1", hints: ["review", "ревью"], category: "indeterminate"
        )
        let body = try JSONSerialization.jsonObject(
            with: try #require(transport.requests[1].httpBody)
        ) as? [String: [String: String]]
        #expect(body == ["transition": ["id": "21"]]) // «На ревью» по подсказке
    }

    @Test("transitionBestMatch: имя не нашлось — берётся категория; ничего — no-op")
    func bestMatchFallback() async throws {
        let transitions = """
        {"transitions":[{"id":"11","name":"Doing","to":{"statusCategory":{"key":"indeterminate"}}}]}
        """
        let transport = FakeTransport([(transitions, 200), ("{}", 204)])
        try await JiraClient(transport: transport).transitionBestMatch(
            config, issueKey: "DN-1", hints: ["review"], category: "indeterminate"
        )
        #expect(transport.requests.count == 2) // fallback на категорию

        let none = FakeTransport([(transitions, 200)])
        try await JiraClient(transport: none).transitionBestMatch(
            config, issueKey: "DN-1", hints: ["review"], category: nil
        )
        #expect(none.requests.count == 1) // no-op
    }

    @Test("OAuth-коннектор: bearerToken приоритетнее Basic; без кред — nil")
    func bearerPriority() async throws {
        let oauth = JiraConfig(
            baseURL: "https://api.atlassian.com/ex/jira/cloud1",
            email: "e@x.com", token: "tok", bearerToken: "BR"
        )
        #expect(oauth.authorizationHeader == "Bearer BR")
        #expect(oauth.isComplete)
        #expect(JiraConfig(baseURL: "https://x").isComplete == false)

        let transport = FakeTransport([("{\"issues\":[]}", 200)])
        _ = try await JiraClient(transport: transport).searchIssues(oauth, jql: "x")
        let request = try #require(transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer BR")
        #expect(request.url?.absoluteString.hasPrefix(
            "https://api.atlassian.com/ex/jira/cloud1/rest/api/2/search/jql"
        ) == true)
    }

    @Test("401 → JiraError со statusCode для баннера переавторизации")
    func unauthorized() async throws {
        let client = JiraClient(transport: FakeTransport([("{}", 401)]))
        await #expect(throws: JiraError.self) {
            _ = try await client.searchIssues(config, jql: "x")
        }
        do {
            _ = try await JiraClient(transport: FakeTransport([("{}", 401)]))
                .searchIssues(config, jql: "x")
        } catch let error as JiraError {
            #expect(error.statusCode == 401)
        }
    }
}

// MARK: - Маппинг импорта

@Suite("JiraImporter: маппинг П4″ без сети")
struct JiraImporterTests {
    private func makeOrg() -> Organization {
        var org = Organization.makeDefault()
        org.repos = [RepoRef(name: "demo", path: "/x", jiraProject: "DN")]
        org.taskTypes[0].jiraType = "Bug"
        org.taskTypes.append(OrgTaskType(name: "Story"))
        return org
    }

    @Test("Тип из поля Jira → jiraType, затем имя, затем первый; проект → репо")
    func mapping() {
        let org = makeOrg()
        let result = JiraImporter.map(
            issues: [
                JiraIssue(key: "DN-1", summary: "Баг", typeName: "Bug", projectKey: "DN"),
                JiraIssue(key: "DN-2", summary: "Стори", typeName: "story", projectKey: "dn"),
                JiraIssue(key: "DN-3", summary: "Эпик", typeName: "Epic", projectKey: "DN"),
            ],
            organization: org, existingKeys: []
        )
        #expect(result.skipped.isEmpty)
        #expect(result.tasks.count == 3)
        #expect(result.tasks[0].taskTypeID == org.taskTypes[0].id)
        #expect(result.tasks[1].taskTypeID == org.taskTypes[1].id) // имя, регистронезависимо
        #expect(result.tasks[2].taskTypeID == org.taskTypes[0].id) // fallback: первый
        #expect(result.tasks.allSatisfy { $0.repoID == org.repos[0].id })
        #expect(result.tasks.allSatisfy { $0.source == .jira })
        #expect(result.tasks[0].jiraKey == "DN-1")
    }

    @Test("Непривязанный проект: один репозиторий — берётся сам; несколько — repoID nil (агент выберет на старте)")
    func unmappedProject() {
        var single = makeOrg() // один репозиторий
        single.repos[0].jiraProject = ""
        let one = JiraImporter.map(
            issues: [JiraIssue(key: "OPS-7", summary: "Фича", projectKey: "OPS")],
            organization: single, existingKeys: []
        )
        #expect(one.skipped.isEmpty)
        #expect(one.tasks.first?.repoID == single.repos[0].id)

        var multi = makeOrg()
        multi.repos.append(RepoRef(name: "beta", path: "/y"))
        let many = JiraImporter.map(
            issues: [JiraIssue(key: "OPS-7", summary: "Фича", projectKey: "OPS")],
            organization: multi, existingKeys: []
        )
        #expect(many.skipped.isEmpty)
        #expect(many.tasks.first?.repoID == nil)
    }

    @Test("Пустой реестр — задачи всё равно импортируются: репозиторий найдётся на старте")
    func emptyRegistry() {
        var org = makeOrg()
        org.repos = []
        let result = JiraImporter.map(
            issues: [JiraIssue(key: "DN-1", summary: "Баг", projectKey: "DN")],
            organization: org, existingKeys: []
        )
        #expect(result.skipped.isEmpty)
        #expect(result.tasks.count == 1)
        #expect(result.tasks[0].repoID == nil)
    }

    @Test("Повторный импорт идемпотентен: существующие ключи молча пропускаются")
    func dedup() {
        let result = JiraImporter.map(
            issues: [JiraIssue(key: "DN-1", summary: "Баг", projectKey: "DN")],
            organization: makeOrg(), existingKeys: ["DN-1"]
        )
        #expect(result.tasks.isEmpty)
        #expect(result.skipped.isEmpty)
    }
}

// MARK: - Write-back через DaemonCore

@Suite("DaemonCore: Jira write-back при финале (T2)")
struct JiraWriteBackTests {
    private let t0 = Date(timeIntervalSince1970: 9000)

    private func makeWorld(
        gateway: FakeJiraGateway
    ) throws -> (DaemonCore, Organization, OrgTask, EventStore) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("petable-jira-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = EventStore(root: root)
        var org = Organization.makeDefault()
        let repo = RepoRef(name: "demo", path: "/nonexistent/demo", jiraProject: "DN")
        org.repos = [repo]
        let task = OrgTask(
            title: "Экспорт", taskTypeID: org.taskTypes[0].id, repoID: repo.id,
            source: .jira, jiraKey: "DN-7"
        )
        org.tasks = [task]
        let done: [AgentEvent] = [
            .started(sessionID: "s"),
            .finished(Verdict(status: .done), usage: AgentUsage(costEstimate: 0.1)),
        ]
        let core = DaemonCore(
            store: store,
            registry: AdapterRegistry([
                ScriptedJiraAdapter(cliID: "claude", scripts: [done, done, done]),
                ScriptedJiraAdapter(cliID: "codex", scripts: [done, done, done]),
            ]),
            jira: gateway,
            now: { self.t0 }
        )
        return (core, org, task, store)
    }

    private func send<T: Codable>(_ core: DaemonCore, _ type: WireType, _ payload: T) async throws {
        try await core.handle(WireEnvelope.pack(type, payload))
    }

    private func events(_ store: EventStore, orgID: UUID, runID: UUID) -> [RunEvent] {
        for (id, loaded) in store.listRuns(orgID: orgID) where id == runID {
            if case let .events(events) = loaded { return events }
        }
        return []
    }

    @Test("Секреты есть: merged → комментарий с маркером, переход в Done, intent+подтверждение")
    func writeBackWithConfig() async throws {
        let gateway = FakeJiraGateway()
        let (core, org, task, store) = try makeWorld(gateway: gateway)

        try await send(core, .configure, ConfigureCommand(jira: config))
        try await send(core, .startRun, StartRunCommand(organization: org, taskID: task.id))
        let runID = try #require(await core.runID(forTask: task.id))
        try await send(core, .approve, runID)

        let run = try #require(await core.run(runID))
        #expect(run.outcome == .merged)
        #expect(gateway.comments.count == 1)
        #expect(gateway.comments[0].issueKey == "DN-7")
        #expect(gateway.comments[0].body.contains(DaemonCore.jiraMarker(runID)))
        #expect(gateway.transitioned == ["DN-7"])

        let log = events(store, orgID: org.orgID, runID: runID)
        let key = "jira:\(runID.uuidString)"
        #expect(log.contains { $0.kindValue == .intent && $0.intentKey == key })
        #expect(log.contains { $0.kindValue == .effectConfirmed && $0.intentKey == key })
        #expect(EventStore.pendingIntents(in: log).isEmpty)
    }

    @Test("Секретов нет: эффект копится в очереди и уходит при configure")
    func queuedUntilConfigure() async throws {
        let gateway = FakeJiraGateway()
        let (core, org, task, store) = try makeWorld(gateway: gateway)

        try await send(core, .startRun, StartRunCommand(organization: org, taskID: task.id))
        let runID = try #require(await core.runID(forTask: task.id))
        try await send(core, .approve, runID)

        #expect(gateway.comments.isEmpty) // конвейер не блокирован, эффект отложен
        let pendingLog = events(store, orgID: org.orgID, runID: runID)
        #expect(EventStore.pendingIntents(in: pendingLog) == ["jira:\(runID.uuidString)"])

        try await send(core, .configure, ConfigureCommand(jira: config))
        #expect(gateway.comments.count == 1)
        #expect(gateway.transitioned == ["DN-7"])
        let log = events(store, orgID: org.orgID, runID: runID)
        #expect(EventStore.pendingIntents(in: log).isEmpty)
    }

    @Test("Задача борда (source=board): write-back не делается")
    func boardTaskSkipped() async throws {
        let gateway = FakeJiraGateway()
        let (core, org, _, _) = try makeWorld(gateway: gateway)
        var boardOrg = org
        let boardTask = OrgTask(
            title: "Локальная", taskTypeID: org.taskTypes[0].id, repoID: org.repos[0].id
        )
        boardOrg.tasks = [boardTask]

        try await send(core, .configure, ConfigureCommand(jira: config))
        try await send(core, .startRun, StartRunCommand(organization: boardOrg, taskID: boardTask.id))
        let runID = try #require(await core.runID(forTask: boardTask.id))
        try await send(core, .approve, runID)

        let run = try #require(await core.run(runID))
        #expect(run.outcome == .merged)
        #expect(gateway.comments.isEmpty)
        #expect(gateway.transitioned.isEmpty)
    }

    @Test("Jira упала: элемент остаётся в очереди, следующий configure добивает без дубля")
    func retryAfterFailure() async throws {
        let gateway = FakeJiraGateway()
        gateway.failComments = true
        let (core, org, task, _) = try makeWorld(gateway: gateway)

        try await send(core, .configure, ConfigureCommand(jira: config))
        try await send(core, .startRun, StartRunCommand(organization: org, taskID: task.id))
        let runID = try #require(await core.runID(forTask: task.id))
        try await send(core, .approve, runID)
        #expect(gateway.comments.isEmpty)

        gateway.failComments = false
        try await send(core, .configure, ConfigureCommand(jira: config))
        #expect(gateway.comments.count == 1)
        #expect(gateway.comments[0].body.contains(DaemonCore.jiraMarker(runID)))
    }

    @Test("Статусы Jira следуют за конвейером: work → review → test (правка №7)")
    func stageStatusSync() async throws {
        let gateway = FakeJiraGateway()
        let (core, org, task, _) = try makeWorld(gateway: gateway)

        try await send(core, .configure, ConfigureCommand(jira: config))
        try await send(core, .startRun, StartRunCommand(organization: org, taskID: task.id))

        // Дефолтный флоу: Разработка → Ревью → Тесты(пусто) → Merge-гейт.
        let hintFirsts = gateway.stageTransitions.map { $0.hints.first ?? "" }
        #expect(gateway.stageTransitions.allSatisfy { $0.issueKey == "DN-7" })
        #expect(hintFirsts == ["in progress", "review", "test", "review"])

        // Принять: финал уходит транзишеном в Done, не повторным синком.
        let runID = try #require(await core.runID(forTask: task.id))
        try await send(core, .approve, runID)
        #expect(gateway.transitioned == ["DN-7"])
    }

    @Test("Кастомный маппинг статусов (№7): имя из jiraStatusMap приоритетнее эвристики; merge наследует review")
    func customStatusMapSync() async throws {
        let gateway = FakeJiraGateway()
        let (core, org, task, _) = try makeWorld(gateway: gateway)
        var custom = org
        custom.jiraStatusMap = ["work": "В доработке", "review": "Код-ревью"]

        try await send(core, .configure, ConfigureCommand(jira: config))
        try await send(core, .startRun, StartRunCommand(organization: custom, taskID: task.id))

        let hintFirsts = gateway.stageTransitions.map { $0.hints.first ?? "" }
        #expect(hintFirsts == ["В доработке", "Код-ревью", "test", "Код-ревью"])
    }

    @Test("customStatus: свой вид → как задан; decompose/join наследуют work; пустые значения игнорируются")
    func customStatusInheritance() {
        let map = ["work": "В разработке", "review": "Код-ревью", "test": "  "]
        #expect(DaemonCore.customStatus(for: .work, map: map) == "В разработке")
        #expect(DaemonCore.customStatus(for: .decompose, map: map) == "В разработке")
        #expect(DaemonCore.customStatus(for: .join, map: map) == "В разработке")
        #expect(DaemonCore.customStatus(for: .merge, map: map) == "Код-ревью")
        #expect(DaemonCore.customStatus(for: .test, map: map) == nil)
        #expect(DaemonCore.customStatus(for: .work, map: nil) == nil)
    }

    @Test("Recovery T2: незакрытый интент восстановлен; факт сверен по маркеру — дубля комментария нет")
    func recoveryChecksFact() async throws {
        let gateway = FakeJiraGateway()
        let (core, org, task, store) = try makeWorld(gateway: gateway)

        // Финал без секретов: интент повис в журнале.
        try await send(core, .startRun, StartRunCommand(organization: org, taskID: task.id))
        let runID = try #require(await core.runID(forTask: task.id))
        try await send(core, .approve, runID)

        // «Рестарт демона»: новое ядро на том же журнале. Комментарий в
        // Jira уже есть (эффект прошёл, подтверждение не записалось).
        let gateway2 = FakeJiraGateway()
        gateway2.existingMarkers = [DaemonCore.jiraMarker(runID)]
        let core2 = DaemonCore(
            store: store, registry: AdapterRegistry([]), jira: gateway2, now: { self.t0 }
        )
        await core2.recover(orgID: org.orgID)
        try await core2.handle(WireEnvelope.pack(.configure, ConfigureCommand(jira: config)))

        #expect(gateway2.comments.isEmpty) // повторный эффект невозможен по построению
        #expect(gateway2.transitioned == ["DN-7"])
        let log = events(store, orgID: org.orgID, runID: runID)
        #expect(EventStore.pendingIntents(in: log).isEmpty)
    }
}

// MARK: - Выбор репозитория агентом

@Suite("DaemonCore: репозиторий задачи выбирает агент (правка автора)")
struct RepoResolutionTests {
    private let t0 = Date(timeIntervalSince1970: 9000)

    private func makeWorld(
        repos: [RepoRef], scripts: [[AgentEvent]]
    ) throws -> (DaemonCore, Organization, OrgTask) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("petable-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var org = Organization.makeDefault()
        org.repos = repos
        let task = OrgTask(title: "Починить логин", taskTypeID: org.taskTypes[0].id)
        org.tasks = [task]
        let core = DaemonCore(
            store: EventStore(root: root),
            registry: AdapterRegistry([
                ScriptedJiraAdapter(cliID: "claude", scripts: scripts),
                ScriptedJiraAdapter(cliID: "codex", scripts: scripts),
            ]),
            jira: FakeJiraGateway(),
            now: { self.t0 }
        )
        return (core, org, task)
    }

    @Test("Несколько репозиториев: LLM-ответ в note выбирает по имени")
    func agentPicks() async throws {
        let resolver: [AgentEvent] = [
            .started(sessionID: "r"),
            .finished(Verdict(status: .done, note: "beta"), usage: AgentUsage()),
        ]
        let work: [AgentEvent] = [
            .started(sessionID: "s"),
            .finished(Verdict(status: .done), usage: AgentUsage()),
        ]
        let (core, org, task) = try makeWorld(
            repos: [
                RepoRef(name: "alpha", path: "/nonexistent/a"),
                RepoRef(name: "beta", path: "/nonexistent/b"),
            ],
            scripts: [resolver, work, work]
        )
        try await core.handle(WireEnvelope.pack(
            .startRun, StartRunCommand(organization: org, taskID: task.id)
        ))
        let runID = try #require(await core.runID(forTask: task.id))
        let run = try #require(await core.run(runID))
        #expect(run.repo.name == "beta")
        #expect(run.status == .waitingGate) // конвейер поехал дальше
    }

    @Test("Пустой реестр: агент выбирает GitHub-кандидата, демон клонирует его сам")
    func cloneFromCandidate() async throws {
        // Живой локальный «GitHub»: репозиторий с коммитом.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("petable-candidate-\(UUID().uuidString)")
        let origin = base.appendingPathComponent("beta")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        func git(_ args: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = origin
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try git("init", "-q")
        try "x".write(to: origin.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init")

        let resolver: [AgentEvent] = [
            .started(sessionID: "r"),
            .finished(Verdict(status: .done, note: "выбираю beta"), usage: AgentUsage()),
        ]
        let work: [AgentEvent] = [
            .started(sessionID: "s"),
            .finished(Verdict(status: .done), usage: AgentUsage()),
        ]
        let (core, org, task) = try makeWorld(repos: [], scripts: [resolver, work, work])
        try await core.handle(WireEnvelope.pack(
            .startRun,
            StartRunCommand(organization: org, taskID: task.id, candidates: [
                RemoteRepoCandidate(name: "alpha", sshURL: "/nonexistent/alpha", httpsURL: ""),
                RemoteRepoCandidate(name: "beta", sshURL: origin.path, httpsURL: ""),
            ])
        ))
        let runID = try #require(await core.runID(forTask: task.id))
        let run = try #require(await core.run(runID))
        #expect(run.repo.name == "beta")
        #expect(run.repo.path.contains("/repos/beta"))
        #expect(FileManager.default.fileExists(atPath: run.repo.path + "/a.txt"))
        #expect(run.status == .waitingGate)
    }

    @Test("Один репозиторий: берётся без вызова агента")
    func singleRepoNoAgent() async throws {
        let work: [AgentEvent] = [
            .started(sessionID: "s"),
            .finished(Verdict(status: .done), usage: AgentUsage()),
        ]
        // Скриптов ровно на work+review: лишний вызов резолвера сломал бы
        // конвейер («сценарии кончились» → failed).
        let (core, org, task) = try makeWorld(
            repos: [RepoRef(name: "solo", path: "/nonexistent/solo")],
            scripts: [work, work]
        )
        try await core.handle(WireEnvelope.pack(
            .startRun, StartRunCommand(organization: org, taskID: task.id)
        ))
        let runID = try #require(await core.runID(forTask: task.id))
        let run = try #require(await core.run(runID))
        #expect(run.repo.name == "solo")
        #expect(run.status == .waitingGate)
    }
}

/// Скриптованный адаптер (копия харнесса DaemonCoreTests — тот private).
private final class ScriptedJiraAdapter: AgentAdapter, @unchecked Sendable {
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

// MARK: - Ссылка на коммит

@Suite("WorktreeManager.commitURL: remote → https-ссылка")
struct CommitURLTests {
    @Test("ssh и https remote дают одинаковую ссылку; мусор — nil")
    func forms() {
        #expect(
            WorktreeManager.commitURL(remote: "git@github.com:luvvano/petable.git", sha: "abc")
                == "https://github.com/luvvano/petable/commit/abc"
        )
        #expect(
            WorktreeManager.commitURL(remote: "https://github.com/luvvano/petable.git", sha: "abc")
                == "https://github.com/luvvano/petable/commit/abc"
        )
        #expect(
            WorktreeManager.commitURL(remote: "https://github.com/luvvano/petable", sha: "abc")
                == "https://github.com/luvvano/petable/commit/abc"
        )
        #expect(WorktreeManager.commitURL(remote: "/local/bare.git", sha: "abc") == nil)
    }
}
