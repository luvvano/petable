import Foundation
import GraphCore

/// Статус запуска. Персистентный string-raw enum (П1c).
public enum RunStatus: String, Codable, Sendable {
    /// Этап исполняется (LLM работает / тесты бегут).
    case running
    /// Этап завершён, ждёт человека на гейте (Принять/Вернуть).
    case waitingGate
    /// «Требует внимания»: лимит возвратов, cannotComplete, failed,
    /// вопрос CLI, конфликт rebase — с причиной, не крутится вечно (П5).
    case needsAttention
    /// Родитель декомпозиции на join: ждёт терминала всех дочерних.
    case waitingChildren
    /// Принято на финальном гейте: очередь merge → rebase → тесты → merge.
    case merging
    /// Терминал; исход — в `outcome`.
    case finished
}

/// Запуск задачи по снапшоту флоу. Runtime-сущность: живёт у демона,
/// в документ возвращается только RunSummary (П1′).
///
/// Снапшот полный (T4): флоу, резолвнутые сотрудники, задача, репозиторий,
/// test-команда — правка организации не меняет активный запуск (П3).
public struct OrganizationRun: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var orgID: UUID
    public var task: OrgTask
    public var flow: OrgFlow
    /// Резолвнутые сотрудники этапов на момент старта.
    public var employees: [Employee]
    public var repo: RepoRef
    public var branchName: String
    /// SHA базового коммита (T4); пустой до создания worktree.
    public var baseSHA: String

    public var status: RunStatus
    /// Причина `needsAttention` — человеку, не в лог.
    public var statusReason: String
    public var currentStageID: UUID
    /// Пройденный путь токена (id этапов) — по нему работает правило
    /// возврата «ближайший work вверх по пути» (П5).
    public var path: [UUID]
    /// Единый счётчик возвратов задачи: ревью + тесты + Reject (П5).
    public var returnCount: Int
    /// Сессии CLI по этапам — ключи resume для чата (П9).
    public var stageSessions: [UUID: String]
    /// Накопленная оценка стоимости (отображение, не enforce).
    public var costEstimate: Double
    public var startedAt: Date
    public var finishedAt: Date?
    public var outcome: RunOutcome?
    /// Родительский запуск (этот — подзадача декомпозиции); nil — корневой.
    public var parentRunID: UUID?
    /// Дочерние запуски decompose-этапа; nil/пусто — детей нет.
    public var childRunIDs: [UUID]?
    /// Момент последнего события запуска — «последнее событие N сек
    /// назад» и тихий пульс активного этапа (6A). Опционал: старые
    /// журналы поля не знают.
    public var lastEventAt: Date?
    /// Версия флоу на момент снапшота — бейдж «Запуск идёт по vN» (2A).
    public var flowVersion: Int?
    /// Итог merge для терминальной карточки (6A): SHA, ссылка (nil при
    /// отказе push — деградация до хеша, T7.4), дифф-стат.
    public var mergeSHA: String?
    public var commitURL: String?
    public var diffStat: String?
    public var pushFailed: Bool?
    /// Experimental-запуски (тени и форки, слайсы 12–13): без Jira
    /// write-back, без push, терминальны до финального гейта — merge
    /// недостижим по построению (side effects только у primary).
    public var experimental: Bool?
    /// Primary-запуск, копией которого едет тень; nil — не тень.
    public var shadowOf: UUID?
    /// Запуск, из которого сделан fork (⌥Enter дебаггера); nil — не форк.
    public var forkOf: UUID?

    public init(
        id: UUID = UUID(),
        orgID: UUID,
        task: OrgTask,
        flow: OrgFlow,
        employees: [Employee],
        repo: RepoRef,
        branchName: String,
        startStageID: UUID,
        startedAt: Date
    ) {
        self.id = id
        self.orgID = orgID
        self.task = task
        self.flow = flow
        self.employees = employees
        self.repo = repo
        self.branchName = branchName
        self.baseSHA = ""
        self.status = .running
        self.statusReason = ""
        self.currentStageID = startStageID
        self.path = [startStageID]
        self.returnCount = 0
        self.stageSessions = [:]
        self.costEstimate = 0
        self.startedAt = startedAt
        self.finishedAt = nil
        self.outcome = nil
        self.parentRunID = nil
        self.childRunIDs = nil
        self.lastEventAt = nil
        self.flowVersion = flow.version
        self.mergeSHA = nil
        self.commitURL = nil
        self.diffStat = nil
        self.pushFailed = nil
        self.experimental = nil
        self.shadowOf = nil
        self.forkOf = nil
    }

    public var isExperimental: Bool { experimental == true }

    public var currentStage: OrgStage? { flow.stage(currentStageID) }

    public func employee(for stage: OrgStage) -> Employee? {
        guard let id = stage.employeeID else { return nil }
        return employees.first(where: { $0.id == id })
    }

    /// Саммари для документа; nil — запуск ещё не терминален.
    public var summary: RunSummary? {
        guard let outcome, let finishedAt else { return nil }
        return RunSummary(
            runID: id,
            taskTitle: task.title,
            jiraKey: task.jiraKey,
            outcome: outcome,
            startedAt: startedAt,
            finishedAt: finishedAt,
            returnCount: returnCount,
            costEstimate: costEstimate,
            mergeSHA: mergeSHA,
            commitURL: commitURL,
            diffStat: diffStat,
            experimental: experimental
        )
    }
}

