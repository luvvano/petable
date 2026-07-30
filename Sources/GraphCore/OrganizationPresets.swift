import Foundation

/// Пресет сотрудника «из коробки» (П8): готовая роль с настройками,
/// из которой создаётся редактируемая копия-Employee в организации.
/// Пресеты определены кодом (не ресурсом): текст наш, типобезопасность
/// дороже подмены файла; рассинхрон с числом «7» ловит тест.
public struct EmployeePreset: Equatable, Sendable {
    public let id: String
    public let name: String
    public let rolePrompt: String
    public let adapter: AdapterConfig
    /// Типовой вид этапа для этой роли (подсказка редактора флоу):
    /// тестировщик — work-этап «написать тесты», НЕ test-этап без LLM.
    public let defaultKind: StageKind

    /// Employee-копия пресета для организации.
    public func makeEmployee() -> Employee {
        Employee(name: name, rolePrompt: rolePrompt, adapter: adapter, presetID: id)
    }
}

public enum OrganizationPresets {
    /// Семь ролей из коробки (дизайн-док, П8).
    public static let all: [EmployeePreset] = [
        EmployeePreset(
            id: "product-manager",
            name: "Продакт-менеджер",
            rolePrompt: """
            Ты продакт-менеджер. Твоя работа — дискавери: уточнить задачу, \
            выделить пользовательскую ценность и критерии приёмки, отсечь лишний скоуп. \
            Пиши коротко и конкретно; выход — уточнённая постановка задачи.
            """,
            adapter: AdapterConfig(cli: "claude", permissionProfile: "readOnly"),
            defaultKind: .work
        ),
        EmployeePreset(
            id: "architect",
            name: "Архитектор",
            rolePrompt: """
            Ты архитектор. Твоя работа — декомпозиция: разбить задачу на \
            минимальный набор подзадач по репозиториям (backend/frontend/…), \
            каждой подзадаче — тип и репозиторий из реестра организации. \
            Не пиши код. Не дроби без необходимости.
            """,
            adapter: AdapterConfig(cli: "claude", permissionProfile: "readOnly"),
            defaultKind: .decompose
        ),
        EmployeePreset(
            id: "backend-developer",
            name: "Backend-разработчик",
            rolePrompt: """
            Ты backend-разработчик. Реализуй задачу в текущем worktree: \
            следуй конвенциям репозитория, пиши тесты рядом с кодом, \
            гоняй сборку и тесты перед завершением.
            """,
            adapter: AdapterConfig(cli: "claude", permissionProfile: "write"),
            defaultKind: .work
        ),
        EmployeePreset(
            id: "frontend-developer",
            name: "Frontend-разработчик",
            rolePrompt: """
            Ты frontend-разработчик. Реализуй интерфейс по макету/спеке из \
            артефакта предыдущего этапа: состояния (пустое, ошибка, загрузка), \
            клавиатура и доступность — часть задачи, не опция.
            """,
            adapter: AdapterConfig(cli: "claude", permissionProfile: "write"),
            defaultKind: .work
        ),
        EmployeePreset(
            id: "designer",
            name: "Дизайнер",
            rolePrompt: """
            Ты продуктовый дизайнер. По постановке задачи сделай макет: \
            самодостаточный HTML-файл со всеми состояниями экрана. \
            Иерархия, пустые состояния и словарь интерфейса — обязательны.
            """,
            adapter: AdapterConfig(cli: "claude", permissionProfile: "write"),
            defaultKind: .work
        ),
        EmployeePreset(
            id: "reviewer",
            name: "Ревьюер",
            rolePrompt: """
            Ты код-ревьюер. Прочитай дифф ветки против базовой: корректность, \
            edge-кейсы, тесты, соответствие конвенциям. Вердикт честный: \
            approve только если готов влить это в свой репозиторий.
            """,
            adapter: AdapterConfig(cli: "codex", permissionProfile: "readOnly"),
            defaultKind: .review
        ),
        EmployeePreset(
            id: "tester",
            name: "Тестировщик",
            rolePrompt: """
            Ты тест-инженер. Допиши недостающие тесты к изменению: \
            граничные случаи, пути ошибок, регрессии. Таблично, поведенчески, \
            без тестов ради тестов.
            """,
            adapter: AdapterConfig(cli: "claude", permissionProfile: "write"),
            defaultKind: .work
        ),
    ]

    public static func preset(_ id: String) -> EmployeePreset? {
        all.first(where: { $0.id == id })
    }
}

extension Organization {
    /// Дефолтная организация (слайс 1, T7.6): линейный флоу
    /// «Разработка → Ревью → Тесты → Merge» и тип задачи «Задача»,
    /// смаршрутизированный на него. Слайсы 2–8 живут без редактора
    /// флоу и без хардкодов в коде движка.
    public static func makeDefault() -> Organization {
        let developer = OrganizationPresets.preset("backend-developer")!.makeEmployee()
        let reviewer = OrganizationPresets.preset("reviewer")!.makeEmployee()

        let merge = OrgStage(name: "Merge", kind: .merge, gate: .human)
        let tests = OrgStage(name: "Тесты", kind: .test, next: [merge.id])
        let review = OrgStage(
            name: "Ревью", kind: .review, employeeID: reviewer.id, next: [tests.id]
        )
        let work = OrgStage(
            name: "Разработка", kind: .work, employeeID: developer.id, next: [review.id]
        )
        let flow = OrgFlow(name: "Задача → merge", stages: [work, review, tests, merge])

        let taskType = OrgTaskType(name: "Задача")
        return Organization(
            employees: [developer, reviewer],
            flows: [flow],
            taskTypes: [taskType],
            routes: [OrgRoute(taskTypeID: taskType.id, flowID: flow.id)]
        )
    }
}
