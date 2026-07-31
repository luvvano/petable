import Foundation
import Testing
@testable import GraphCore

@Suite("Организация: модель, конверт, валидатор")
struct OrganizationTests {
    // MARK: Конверт v14

    @Test("Round-trip: организация переживает encode/decode, версия v14")
    func envelopeRoundTrip() throws {
        var org = Organization.makeDefault()
        org.repos = [RepoRef(name: "petable", path: "/tmp/petable", testCommand: "swift test")]
        org.tasks = [OrgTask(title: "Экспорт отчёта", taskTypeID: org.taskTypes[0].id)]
        org.runSummaries = [RunSummary(
            runID: UUID(), taskTitle: "Прошлая задача", outcome: .merged,
            startedAt: Date(timeIntervalSince1970: 100),
            finishedAt: Date(timeIntervalSince1970: 200),
            returnCount: 1, costEstimate: 0.4
        )]
        let envelope = Envelope(
            stages: [.init(graph: Fixtures.closeMonth())],
            organization: org
        )
        let decoded = try Envelope.decode(try envelope.encoded())
        #expect(decoded.version == 14)
        #expect(decoded.organization == org)
    }

    @Test("Регрессия: файл без организации (v13 и раньше) читается, organization == nil")
    func oldFileWithoutOrganization() throws {
        let envelope = Envelope(graph: Fixtures.closeMonth())
        var json = try JSONSerialization.jsonObject(
            with: envelope.encoded()
        ) as! [String: Any]
        json["version"] = 13
        json.removeValue(forKey: "organization")
        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try Envelope.decode(data)
        #expect(decoded.organization == nil)
        #expect(decoded.version == Envelope.currentVersion)
    }

    @Test("Регрессия: v15 → понятная ошибка, организация не гадается")
    func futureVersionStillFails() {
        let json = #"{"version": 15, "stages": []}"#.data(using: .utf8)!
        #expect(throws: Envelope.EnvelopeError.unsupportedVersion(found: 15, supported: 14)) {
            try Envelope.decode(json)
        }
    }

    @Test("Битые данные организации не тихо съедаются: неверная форма секции — ошибка")
    func malformedOrganizationThrows() {
        let json = #"{"version": 14, "stages": [], "organization": {"orgID": 42}}"#
            .data(using: .utf8)!
        #expect(throws: (any Error).self) { try Envelope.decode(json) }
    }

    // MARK: Маршрутизация

    @Test("Маршрутизация: тип задачи находит флоу; тип без маршрута — nil (вопрос человеку)")
    func routing() {
        let org = Organization.makeDefault()
        let routed = org.flow(for: org.taskTypes[0].id)
        #expect(routed?.id == org.flows[0].id)
        #expect(org.flow(for: UUID()) == nil)
    }

    // MARK: Пресеты

    @Test("Семь пресетов из коробки, id уникальны, ревьюер на другом CLI и read-only")
    func presets() {
        #expect(OrganizationPresets.all.count == 7)
        #expect(Set(OrganizationPresets.all.map(\.id)).count == 7)
        let reviewer = OrganizationPresets.preset("reviewer")
        #expect(reviewer?.adapter.cli == "codex")
        #expect(reviewer?.adapter.permissionProfile == "readOnly")
        #expect(reviewer?.defaultKind == .review)
        // Тестировщик — work-этап «написать тесты», не test-этап без LLM.
        #expect(OrganizationPresets.preset("tester")?.defaultKind == .work)
        #expect(OrganizationPresets.preset("architect")?.defaultKind == .decompose)
    }

    @Test("Дефолтная организация валидна и готова к запуску")
    func defaultOrganizationIsValid() {
        let org = Organization.makeDefault()
        #expect(org.flows.count == 1)
        #expect(org.flows[0].validate().isEmpty)
        #expect(org.flows[0].startStage?.kind == .work)
        // Ревью и разработка — разные CLI (ревьюер не соглашатель).
        let work = org.flows[0].stages.first { $0.kind == .work }
        let review = org.flows[0].stages.first { $0.kind == .review }
        let workCLI = org.employee(work?.employeeID)?.adapter.cli
        let reviewCLI = org.employee(review?.employeeID)?.adapter.cli
        #expect(workCLI != nil && reviewCLI != nil && workCLI != reviewCLI)
    }

    // MARK: Валидатор (инварианты T1)

    private func makeEmployee() -> Employee { Employee(name: "Разработчик") }

    @Test("Пустой флоу невалиден")
    func emptyFlow() {
        #expect(OrgFlow(name: "Пустой").validate() == [.empty])
    }

    @Test("Цикл ловится")
    func cycleDetected() {
        let employee = makeEmployee()
        var a = OrgStage(name: "A", kind: .work, employeeID: employee.id)
        var b = OrgStage(name: "B", kind: .work, employeeID: employee.id)
        let merge = OrgStage(name: "Merge", kind: .merge)
        a.next = [b.id]
        b.next = [a.id, merge.id]
        let issues = OrgFlow(name: "Цикл", stages: [a, b, merge]).validate()
        #expect(issues.contains { if case .cycle = $0 { return true }; return false })
    }

    @Test("Ребро в несуществующий этап ловится")
    func danglingEdge() {
        let ghost = UUID()
        let employee = makeEmployee()
        let merge = OrgStage(name: "Merge", kind: .merge)
        let a = OrgStage(name: "A", kind: .work, employeeID: employee.id, next: [merge.id, ghost])
        let issues = OrgFlow(name: "Битое ребро", stages: [a, merge]).validate()
        #expect(issues.contains(.danglingEdge(from: a.id, to: ghost)))
    }

    @Test("Два стартовых этапа ловятся")
    func twoStarts() {
        let employee = makeEmployee()
        let merge = OrgStage(name: "Merge", kind: .merge)
        let a = OrgStage(name: "A", kind: .work, employeeID: employee.id, next: [merge.id])
        let b = OrgStage(name: "B", kind: .work, employeeID: employee.id, next: [merge.id])
        let issues = OrgFlow(name: "Два старта", stages: [a, b, merge]).validate()
        #expect(issues.contains(.startCount(2)))
    }

    @Test("Этап без пути к терминалу ловится")
    func unreachableTerminal() {
        let employee = makeEmployee()
        let deadEnd = OrgStage(name: "Тупик", kind: .work, employeeID: employee.id)
        let issues = OrgFlow(name: "Тупик", stages: [deadEnd]).validate()
        #expect(issues.contains(.unreachableTerminal(stage: deadEnd.id)))
    }

    @Test("join без decompose и decompose без join ловятся")
    func decomposeJoinPairing() {
        let employee = makeEmployee()
        // join без decompose: work → join
        let join = OrgStage(name: "Join", kind: .join)
        let work = OrgStage(name: "Работа", kind: .work, employeeID: employee.id, next: [join.id])
        let issues1 = OrgFlow(name: "join-сирота", stages: [work, join]).validate()
        #expect(issues1.contains(.joinWithoutDecompose(stage: join.id)))

        // decompose без join: decompose → merge
        let merge = OrgStage(name: "Merge", kind: .merge)
        let decompose = OrgStage(
            name: "Декомпозиция", kind: .decompose, employeeID: employee.id, next: [merge.id]
        )
        let issues2 = OrgFlow(name: "decompose-сирота", stages: [decompose, merge]).validate()
        #expect(issues2.contains(.decomposeWithoutJoin(stage: decompose.id)))
    }

    @Test("Этап после join запрещён (v1: join терминален)")
    func stageAfterJoin() {
        let employee = makeEmployee()
        let merge = OrgStage(name: "Merge", kind: .merge)
        let join = OrgStage(name: "Join", kind: .join, next: [merge.id])
        let decompose = OrgStage(
            name: "Декомпозиция", kind: .decompose, employeeID: employee.id, next: [join.id]
        )
        let issues = OrgFlow(name: "После join", stages: [decompose, join, merge]).validate()
        #expect(issues.contains(.stageAfterJoin(stage: join.id)))
    }

    @Test("LLM-этап без сотрудника ловится; test/merge без сотрудника — ок")
    func missingEmployee() {
        let merge = OrgStage(name: "Merge", kind: .merge)
        let tests = OrgStage(name: "Тесты", kind: .test, next: [merge.id])
        let work = OrgStage(name: "Работа", kind: .work, next: [tests.id])
        let issues = OrgFlow(name: "Без сотрудника", stages: [work, tests, merge]).validate()
        #expect(issues.contains(.missingEmployee(stage: work.id)))
        #expect(issues.filter { if case .missingEmployee = $0 { return true }; return false }.count == 1)
    }

    @Test("Валидный fan-out: decompose → две ветки → join")
    func validFanOut() {
        let employee = makeEmployee()
        let join = OrgStage(name: "Join", kind: .join)
        let back = OrgStage(name: "Backend", kind: .work, employeeID: employee.id, next: [join.id])
        let front = OrgStage(name: "Frontend", kind: .work, employeeID: employee.id, next: [join.id])
        let decompose = OrgStage(
            name: "Архитектор", kind: .decompose, employeeID: employee.id,
            next: [back.id, front.id]
        )
        let flow = OrgFlow(name: "Фича", stages: [decompose, back, front, join])
        #expect(flow.validate().isEmpty)
        #expect(flow.startStage?.id == decompose.id)
    }

    @Test("Экспорт/импорт сотрудника: JSON-round-trip не теряет ни одного поля конфигурации")
    func employeeJSONRoundTrip() throws {
        let employee = Employee(
            name: "Фронтенд-разработчик",
            rolePrompt: "Ты пишешь интерфейсы",
            adapter: AdapterConfig(
                cli: "claude",
                model: "opus",
                effort: "high",
                allowedTools: ["Edit", "Bash"],
                limits: StageLimits(maxTokens: 120_000, maxMinutes: 45, maxChatIterations: 3),
                skills: ["swiftui"],
                harness: "Следуй DESIGN.md",
                permissionProfile: "write"
            ),
            presetID: "frontend-developer"
        )
        let data = try JSONEncoder().encode(employee)
        let decoded = try JSONDecoder().decode(Employee.self, from: data)
        #expect(decoded == employee)

        // Импорт создаёт НОВОГО сотрудника: id перегенерируется, всё
        // остальное совпадает — конфликтов с существующими нет.
        var imported = decoded
        imported.id = UUID()
        #expect(imported.id != employee.id)
        #expect(imported.adapter == employee.adapter)
        #expect(imported.rolePrompt == employee.rolePrompt)
    }

    @Test("Дефолтные модели движка: пустая модель сотрудника получает дефолт своего CLI, своя — сильнее")
    func defaultModels() {
        var org = Organization.makeDefault()
        org.employees[0].adapter.model = "" // claude-разработчик
        org.employees[1].adapter.model = "своя-модель" // codex-ревьюер
        let updated = org.applyingDefaultModels(["claude": "opus-x", "codex": "gpt-y"])
        #expect(updated.employees[0].adapter.model == "opus-x")
        #expect(updated.employees[1].adapter.model == "своя-модель")
        // Пустые значения дефолтов ничего не трогают.
        #expect(org.applyingDefaultModels(["claude": ""]) == org)
    }

    @Test("Версия флоу (2A): старый JSON без поля version читается как v1, свежая пишется")
    func flowVersionBackcompat() throws {
        let flow = OrgFlow(name: "Флоу", stages: [], version: 7)
        let data = try JSONEncoder().encode(flow)
        let roundTrip = try JSONDecoder().decode(OrgFlow.self, from: data)
        #expect(roundTrip.version == 7)

        var json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        json["version"] = nil
        let stripped = try JSONSerialization.data(withJSONObject: json)
        let legacy = try JSONDecoder().decode(OrgFlow.self, from: stripped)
        #expect(legacy.version == 1)
    }
}
