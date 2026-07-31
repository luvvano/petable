import Foundation

/// Раздел «Организация» документа: ИИ-сотрудники и настраиваемые флоу.
///
/// Документ хранит только ОПРЕДЕЛЕНИЕ организации (роли, флоу, маршруты,
/// реестр репозиториев, бэклог борда) и компактные саммари завершённых
/// запусков. Runtime-история (event-стримы, логи, диффы, чаты) живёт в
/// хранилище демона и находится по `orgID` — см. дизайн-док, П1′.
public struct Organization: Codable, Equatable, Sendable {
    /// Персистентный идентификатор организации: создаётся один раз и
    /// переживает копирование/Save As документа — по нему runtime-хранилище
    /// (`…/Petable/runs/<orgID>/`) находит историю запусков.
    public var orgID: UUID
    public var employees: [Employee]
    public var flows: [OrgFlow]
    public var taskTypes: [OrgTaskType]
    /// Маршрутизация: тип задачи → флоу. Тип без маршрута не стартует —
    /// вопрос человеку, не догадка движка.
    public var routes: [OrgRoute]
    /// Реестр репозиториев, над которыми работает организация.
    public var repos: [RepoRef]
    /// Бэклог борда: задачи до старта — обычные undoable-операции документа;
    /// после старта статус ведёт демон, в документ возвращается RunSummary.
    public var tasks: [OrgTask]
    /// Саммари завершённых запусков; пишутся идемпотентно по runID при
    /// реконсиляции (открытие документа/коннект), НЕ undoable.
    public var runSummaries: [RunSummary]
    /// Конфигурируемый маппинг статусной модели Jira (правка №7):
    /// вид этапа (StageKind.rawValue) → имя статуса Jira. Пусто/nil —
    /// подбор по смыслу (эвристика hints движка).
    public var jiraStatusMap: [String: String]?

    public init(
        orgID: UUID = UUID(),
        employees: [Employee] = [],
        flows: [OrgFlow] = [],
        taskTypes: [OrgTaskType] = [],
        routes: [OrgRoute] = [],
        repos: [RepoRef] = [],
        tasks: [OrgTask] = [],
        runSummaries: [RunSummary] = [],
        jiraStatusMap: [String: String]? = nil
    ) {
        self.orgID = orgID
        self.employees = employees
        self.flows = flows
        self.taskTypes = taskTypes
        self.routes = routes
        self.repos = repos
        self.tasks = tasks
        self.runSummaries = runSummaries
        self.jiraStatusMap = jiraStatusMap
    }

    /// Флоу для типа задачи; nil — маршрута нет (вопрос человеку).
    public func flow(for taskType: UUID) -> OrgFlow? {
        guard let route = routes.first(where: { $0.taskTypeID == taskType }) else { return nil }
        return flows.first(where: { $0.id == route.flowID })
    }

    public func employee(_ id: UUID?) -> Employee? {
        guard let id else { return nil }
        return employees.first(where: { $0.id == id })
    }

    /// Идемпотентная реконсиляция саммари (П1′): дописывает только новые
    /// runID, существующие не трогает и не дублирует — копия документа
    /// с тем же orgID дубликатов не плодит.
    public mutating func reconcile(summaries: [RunSummary]) {
        let known = Set(runSummaries.map(\.runID))
        let fresh = summaries.filter { !known.contains($0.runID) }
        guard !fresh.isEmpty else { return }
        runSummaries.append(contentsOf: fresh.sorted { $0.finishedAt < $1.finishedAt })
    }
}

/// Сотрудник: ролевой промпт + конфигурация исполнителя.
/// Создаётся из пресета (`presetID`) и правится поверх; движок работает
/// с уже РЕЗОЛВНУТОЙ конфигурацией — снапшот запуска копирует её целиком,
/// правка сотрудника не трогает активные запуски (П3).
public struct Employee: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Ролевой промпт — «кто ты и как работаешь» этого сотрудника.
    public var rolePrompt: String
    public var adapter: AdapterConfig
    /// Из какого пресета создан; nil — с нуля.
    public var presetID: String?

    public init(
        id: UUID = UUID(),
        name: String,
        rolePrompt: String = "",
        adapter: AdapterConfig = AdapterConfig(),
        presetID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.rolePrompt = rolePrompt
        self.adapter = adapter
        self.presetID = presetID
    }
}

/// Конфигурация исполнителя сотрудника. Трансляция полей во флаги —
/// забота конкретного адаптера; поле без аналога у CLI помечается в UI
/// «не поддерживается этим исполнителем», молча не игнорируется.
public struct AdapterConfig: Codable, Equatable, Sendable {
    /// Какой CLI исполняет сотрудника: `claude` | `codex` (строка —
    /// третий адаптер не должен требовать миграции формата).
    public var cli: String
    /// Модель CLI; пустая строка — дефолт CLI.
    public var model: String
    /// Reasoning/effort; пустая строка — дефолт CLI.
    public var effort: String
    /// Allowlist инструментов; пустой список — дефолт CLI.
    public var allowedTools: [String]
    /// Лимиты этапа. Деньги не enforce — только токены/время/итерации
    /// (T7.5): из usage-полей CLI, стоимость — отображаемая оценка.
    public var limits: StageLimits
    /// Skills, доступные сотруднику (имена/пути); трансляция — адаптером.
    public var skills: [String]
    /// Harness-инструкции сотрудника (AGENTS.md/CLAUDE.md): материализуются
    /// в worktree per-worktree exclude'ом ИЛИ уходят append-to-system-prompt
    /// при коллизии с файлом репозитория (П8).
    public var harness: String
    /// Профиль прав: `readOnly` | `write` — адаптер транслирует во флаги
    /// песочницы своего CLI (ревьюеру запись не выдаётся).
    public var permissionProfile: String

    public init(
        cli: String = "claude",
        model: String = "",
        effort: String = "",
        allowedTools: [String] = [],
        limits: StageLimits = StageLimits(),
        skills: [String] = [],
        harness: String = "",
        permissionProfile: String = "write"
    ) {
        self.cli = cli
        self.model = model
        self.effort = effort
        self.allowedTools = allowedTools
        self.limits = limits
        self.skills = skills
        self.harness = harness
        self.permissionProfile = permissionProfile
    }
}

/// Лимиты одного этапа; 0 = «без лимита».
public struct StageLimits: Codable, Equatable, Sendable {
    public var maxTokens: Int
    public var maxMinutes: Int
    /// Максимум чат-итераций внутри этапа (П9); возвраты задачи считает
    /// отдельный единый счётчик запуска, не этот лимит.
    public var maxChatIterations: Int

    public init(maxTokens: Int = 0, maxMinutes: Int = 30, maxChatIterations: Int = 0) {
        self.maxTokens = maxTokens
        self.maxMinutes = maxMinutes
        self.maxChatIterations = maxChatIterations
    }
}

/// Тип задачи — ключ маршрутизации «тип → флоу».
public struct OrgTaskType: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Значение поля Jira, которое маппится в этот тип (пустое — не из Jira).
    public var jiraType: String

    public init(id: UUID = UUID(), name: String, jiraType: String = "") {
        self.id = id
        self.name = name
        self.jiraType = jiraType
    }
}

/// Строка таблицы маршрутизации TaskType → Flow.
public struct OrgRoute: Codable, Equatable, Sendable {
    public var taskTypeID: UUID
    public var flowID: UUID

    public init(taskTypeID: UUID, flowID: UUID) {
        self.taskTypeID = taskTypeID
        self.flowID = flowID
    }
}

/// Вид этапа. Персистентный enum — string-raw (П1c: никаких
/// ассоциированных значений в персистентных enum).
public enum StageKind: String, Codable, Sendable, CaseIterable {
    /// LLM-этап с артефактом-коммитом (код, макет).
    case work
    /// LLM-этап с вердиктом approve/changesRequested; артефакт (отчёт)
    /// живёт в run-хранилище, в дифф не попадает.
    case review
    /// LLM-этап, порождающий подзадачи `{заголовок, тип, репо}` —
    /// fan-out в дочерние запуски. Глубина в v1 = 1.
    case decompose
    /// Ждёт терминального статуса всех дочерних запусков; в v1 терминален.
    case join
    /// Тест-команда репозитория (exit 0), без LLM.
    case test
    /// Финальный гейт: Принять → rebase → повторные тесты → merge.
    case merge
}

/// Гейт этапа: продолжать автоматически или ждать человека.
public enum StageGate: String, Codable, Sendable {
    case auto
    case human
}

/// Этап флоу.
public struct OrgStage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: StageKind
    public var gate: StageGate
    /// Сотрудник этапа; nil допустим только для этапов без LLM (test/join/merge).
    public var employeeID: UUID?
    /// Шаблон промпта этапа; подставляется поверх ролевого промпта сотрудника.
    public var promptTemplate: String
    /// Исходящие рёбра — id следующих этапов (направленный граф).
    public var next: [UUID]

    public init(
        id: UUID = UUID(),
        name: String,
        kind: StageKind,
        gate: StageGate = .auto,
        employeeID: UUID? = nil,
        promptTemplate: String = "",
        next: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.gate = gate
        self.employeeID = employeeID
        self.promptTemplate = promptTemplate
        self.next = next
    }
}

/// Флоу — направленный граф этапов. Валидность — `validate()`;
/// невалидный флоу можно рисовать, но нельзя запускать (гейт старта).
public struct OrgFlow: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var stages: [OrgStage]
    /// Версия определения: бампается при содержательной правке — бейдж
    /// «Запуск идёт по v12 · текущий флоу v14» (2A). Активные запуски
    /// едут по своему снапшоту (П3).
    public var version: Int

    public init(id: UUID = UUID(), name: String, stages: [OrgStage] = [], version: Int = 1) {
        self.id = id
        self.name = name
        self.stages = stages
        self.version = version
    }

    /// Старые документы/журналы без поля version читаются как v1.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        stages = try container.decode([OrgStage].self, forKey: .stages)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }

    public func stage(_ id: UUID) -> OrgStage? {
        stages.first(where: { $0.id == id })
    }

    /// Стартовый этап: единственный без входящих рёбер.
    public var startStage: OrgStage? {
        let targets = Set(stages.flatMap(\.next))
        let starts = stages.filter { !targets.contains($0.id) }
        return starts.count == 1 ? starts.first : nil
    }

    // MARK: Правки редактора (слайс 9)

    /// Вставка этапа в цепочку после `afterID` (nil — в начало): новый
    /// этап наследует исходящие рёбра предшественника. Линейная операция
    /// редактора v1; произвольные рёбра — руками через `next`.
    public mutating func insertStage(_ stage: OrgStage, after afterID: UUID?) {
        var inserted = stage
        if let afterID, let index = stages.firstIndex(where: { $0.id == afterID }) {
            inserted.next = stages[index].next
            stages[index].next = [inserted.id]
            stages.insert(inserted, at: index + 1)
        } else {
            if let start = startStage {
                inserted.next = [start.id]
            }
            stages.insert(inserted, at: 0)
        }
    }

    /// Удаление этапа с перешивкой рёбер: предшественники наследуют его
    /// исходящие рёбра — цепочка не рвётся.
    public mutating func removeStage(_ id: UUID) {
        guard let removed = stage(id) else { return }
        for index in stages.indices where stages[index].next.contains(id) {
            var next = stages[index].next.filter { $0 != id }
            for target in removed.next where !next.contains(target) {
                next.append(target)
            }
            stages[index].next = next
        }
        stages.removeAll { $0.id == id }
    }

    // MARK: Валидатор (инварианты T1)

    /// Нарушение инварианта графа флоу. НЕ персистентный тип —
    /// живёт в памяти (issues-навигатор редактора, гейт старта).
    public enum FlowIssue: Equatable, Sendable {
        /// Рёбер в несуществующий этап.
        case danglingEdge(from: UUID, to: UUID)
        /// Цикл: этап достижим из самого себя.
        case cycle(stage: UUID)
        /// Не ровно один стартовый этап (0 — все в цикле, 2+ — рассыпан).
        case startCount(Int)
        /// Из этапа недостижим терминал (merge или join).
        case unreachableTerminal(stage: UUID)
        /// join без decompose выше по графу.
        case joinWithoutDecompose(stage: UUID)
        /// decompose, ни одна ветка которого не приводит в join.
        case decomposeWithoutJoin(stage: UUID)
        /// join в v1 терминален — этапов после него нет.
        case stageAfterJoin(stage: UUID)
        /// LLM-этап без сотрудника.
        case missingEmployee(stage: UUID)
        /// Пустой флоу.
        case empty
    }

    /// Проверка инвариантов. Пустой список = флоу запускаем.
    public func validate() -> [FlowIssue] {
        guard !stages.isEmpty else { return [.empty] }
        var issues: [FlowIssue] = []
        let byID = Dictionary(uniqueKeysWithValues: stages.map { ($0.id, $0) })

        for stage in stages {
            for target in stage.next where byID[target] == nil {
                issues.append(.danglingEdge(from: stage.id, to: target))
            }
            if stage.kind == .join, !stage.next.isEmpty {
                issues.append(.stageAfterJoin(stage: stage.id))
            }
            let needsEmployee = stage.kind == .work || stage.kind == .review || stage.kind == .decompose
            if needsEmployee, stage.employeeID == nil {
                issues.append(.missingEmployee(stage: stage.id))
            }
        }

        // Циклы: DFS с раскраской. Битые рёбра уже зафиксированы — пропускаем.
        var color: [UUID: Int] = [:] // 0/nil — белый, 1 — серый, 2 — чёрный
        var cyclic: Set<UUID> = []
        func dfs(_ id: UUID) {
            color[id] = 1
            for target in byID[id]?.next ?? [] where byID[target] != nil {
                if color[target] == 1 { cyclic.insert(target) } else if color[target] == nil { dfs(target) }
            }
            color[id] = 2
        }
        for stage in stages where color[stage.id] == nil { dfs(stage.id) }
        for id in cyclic.sorted(by: { $0.uuidString < $1.uuidString }) {
            issues.append(.cycle(stage: id))
        }

        let targets = Set(stages.flatMap(\.next))
        let starts = stages.filter { !targets.contains($0.id) }
        if starts.count != 1 { issues.append(.startCount(starts.count)) }

        // Достижимость терминала (merge/join) из каждого этапа.
        var reachesTerminal: [UUID: Bool] = [:]
        func reaches(_ id: UUID, _ visiting: inout Set<UUID>) -> Bool {
            if let cached = reachesTerminal[id] { return cached }
            guard let stage = byID[id] else { return false }
            if stage.kind == .merge || stage.kind == .join {
                reachesTerminal[id] = true
                return true
            }
            guard visiting.insert(id).inserted else { return false } // цикл
            defer { visiting.remove(id) }
            let result = stage.next.contains { reaches($0, &visiting) }
            reachesTerminal[id] = result
            return result
        }
        for stage in stages {
            var visiting: Set<UUID> = []
            if !reaches(stage.id, &visiting) {
                issues.append(.unreachableTerminal(stage: stage.id))
            }
        }

        // Парность decompose/join: join требует decompose среди предков,
        // decompose — join среди достижимых.
        let decomposes = stages.filter { $0.kind == .decompose }
        let joins = stages.filter { $0.kind == .join }
        func reachable(from id: UUID) -> Set<UUID> {
            var seen: Set<UUID> = []
            var queue = [id]
            while let current = queue.popLast() {
                for target in byID[current]?.next ?? [] where seen.insert(target).inserted {
                    queue.append(target)
                }
            }
            return seen
        }
        for join in joins {
            let feeders = decomposes.contains { reachable(from: $0.id).contains(join.id) }
            if !feeders { issues.append(.joinWithoutDecompose(stage: join.id)) }
        }
        for decompose in decomposes {
            let reached = reachable(from: decompose.id)
            if !joins.contains(where: { reached.contains($0.id) }) {
                issues.append(.decomposeWithoutJoin(stage: decompose.id))
            }
        }

        return issues
    }
}

extension OrgFlow.FlowIssue {
    /// Этап, к которому привязано нарушение; nil — нарушение всего флоу.
    /// Issues-навигатор редактора подсвечивает по нему узел (12A).
    public var stageID: UUID? {
        switch self {
        case let .danglingEdge(from, _): return from
        case let .cycle(stage), let .unreachableTerminal(stage),
             let .joinWithoutDecompose(stage), let .decomposeWithoutJoin(stage),
             let .stageAfterJoin(stage), let .missingEmployee(stage):
            return stage
        case .startCount, .empty: return nil
        }
    }
}

extension OrgFlow {
    /// Человеческий текст нарушения — словарь 8A, без технотерминов.
    public func describe(_ issue: FlowIssue) -> String {
        func name(_ id: UUID) -> String { stage(id)?.name ?? "этап" }
        switch issue {
        case let .danglingEdge(from, _):
            return "«\(name(from))»: стрелка ведёт в удалённый этап"
        case let .cycle(stage):
            return "«\(name(stage))»: этапы ходят по кругу"
        case .startCount(0):
            return "Нет стартового этапа — все этапы в кольце"
        case let .startCount(count):
            return "Стартовых этапов \(count), нужен один"
        case let .unreachableTerminal(stage):
            return "Из «\(name(stage))» не добраться до Merge"
        case let .joinWithoutDecompose(stage):
            return "«\(name(stage))»: слияние веток без декомпозиции выше"
        case let .decomposeWithoutJoin(stage):
            return "«\(name(stage))»: декомпозиция без слияния веток ниже"
        case let .stageAfterJoin(stage):
            return "«\(name(stage))»: после слияния веток этапов не бывает"
        case let .missingEmployee(stage):
            return "«\(name(stage))»: не назначен сотрудник"
        case .empty:
            return "Флоу пуст — добавь этапы"
        }
    }
}

/// Репозиторий из реестра организации.
public struct RepoRef: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Абсолютный путь к локальному клону.
    public var path: String
    /// Per-repo тест-команда (`swift test`, `make test`…); успех = exit 0.
    public var testCommand: String
    /// Jira-проект, чьи задачи идут в этот репозиторий (маппинг импорта).
    public var jiraProject: String

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        testCommand: String = "",
        jiraProject: String = ""
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.testCommand = testCommand
        self.jiraProject = jiraProject
    }
}

/// Источник задачи. Персистентный string-raw enum.
public enum OrgTaskSource: String, Codable, Sendable {
    case board
    case jira
}

/// Задача борда/импорта — вход конвейера. До старта живёт в документе
/// и правится с undo; стартовавшая уходит в runtime, обратно приходит
/// только RunSummary.
public struct OrgTask: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var title: String
    public var details: String
    public var taskTypeID: UUID?
    public var repoID: UUID?
    public var source: OrgTaskSource
    /// Ключ Jira (`DN-341`); пустой — задача борда.
    public var jiraKey: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        details: String = "",
        taskTypeID: UUID? = nil,
        repoID: UUID? = nil,
        source: OrgTaskSource = .board,
        jiraKey: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.taskTypeID = taskTypeID
        self.repoID = repoID
        self.source = source
        self.jiraKey = jiraKey
        self.createdAt = createdAt
    }
}

/// Терминальный статус запуска. Персистентный string-raw enum.
public enum RunOutcome: String, Codable, Sendable {
    case merged
    case cancelled
    /// Закрыт человеком из «требует внимания» без merge.
    case closed
    /// Каталог запуска в хранилище не читается (карантин 3A).
    case broken
}

/// Компактное саммари завершённого запуска — единственное, что runtime
/// возвращает в документ. Пишется один раз при реконсиляции, идемпотентно
/// по `runID`, вне undo-стека (П1′).
public struct RunSummary: Codable, Equatable, Identifiable, Sendable {
    public var runID: UUID
    public var taskTitle: String
    public var jiraKey: String
    public var outcome: RunOutcome
    public var startedAt: Date
    public var finishedAt: Date
    /// Итог единого счётчика возвратов задачи.
    public var returnCount: Int
    /// Отображаемая оценка стоимости в долларах; 0 — адаптер не отдал usage.
    public var costEstimate: Double
    /// SHA merge-коммита (терминальная карточка 6A); nil — не merged.
    public var mergeSHA: String?
    /// Ссылка на коммит в origin; nil — remote нет или push не прошёл
    /// (ссылка деградирует до хеша, T7.4).
    public var commitURL: String?
    /// Краткий дифф-стат merge.
    public var diffStat: String?
    /// Experimental-запуск (тень/форк): в истории с пометкой, задачу
    /// с борда не снимает.
    public var experimental: Bool?

    public var id: UUID { runID }

    public init(
        runID: UUID,
        taskTitle: String,
        jiraKey: String = "",
        outcome: RunOutcome,
        startedAt: Date,
        finishedAt: Date,
        returnCount: Int = 0,
        costEstimate: Double = 0,
        mergeSHA: String? = nil,
        commitURL: String? = nil,
        diffStat: String? = nil,
        experimental: Bool? = nil
    ) {
        self.runID = runID
        self.taskTitle = taskTitle
        self.jiraKey = jiraKey
        self.outcome = outcome
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.returnCount = returnCount
        self.costEstimate = costEstimate
        self.mergeSHA = mergeSHA
        self.commitURL = commitURL
        self.diffStat = diffStat
        self.experimental = experimental
    }
}
