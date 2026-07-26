import Foundation

/// Карточка работы — описание по структуре AJTBD:
/// «когда … хочу … чтобы …» плюс частота выполнения.
/// Текстовые поля — списки элементов (буллеты карточки);
/// пустой список = не заполнено.
public struct JobDetails: Codable, Equatable, Sendable {
    /// «Когда я в контексте: …»
    public var context: [String]
    /// «…испытываю негативные эмоции: …»
    public var negativeEmotions: [String]
    /// «…случился триггер: …»
    public var trigger: [String]
    /// «Хочу … с такими критериями успеха: …»
    public var successCriteria: [String]
    /// «Чтобы: …» — ради какой работы уровнем выше выполняется эта.
    public var inOrderTo: [String]
    /// «…и чувствовать себя: …»
    public var positiveEmotions: [String]
    /// «Частота выполнения работы: …» — например, «5 раз/год».
    public var frequency: String

    public init(
        context: [String] = [],
        negativeEmotions: [String] = [],
        trigger: [String] = [],
        successCriteria: [String] = [],
        inOrderTo: [String] = [],
        positiveEmotions: [String] = [],
        frequency: String = ""
    ) {
        self.context = context
        self.negativeEmotions = negativeEmotions
        self.trigger = trigger
        self.successCriteria = successCriteria
        self.inOrderTo = inOrderTo
        self.positiveEmotions = positiveEmotions
        self.frequency = frequency
    }

    public var isEmpty: Bool {
        context.isEmpty && negativeEmotions.isEmpty && trigger.isEmpty
            && successCriteria.isEmpty && inOrderTo.isEmpty
            && positiveEmotions.isEmpty && frequency.isEmpty
    }

    /// Копия без мусора редактора: элементы с trim, пустые отброшены.
    public func normalized() -> JobDetails {
        func clean(_ items: [String]) -> [String] {
            items
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return JobDetails(
            context: clean(context),
            negativeEmotions: clean(negativeEmotions),
            trigger: clean(trigger),
            successCriteria: clean(successCriteria),
            inOrderTo: clean(inOrderTo),
            positiveEmotions: clean(positiveEmotions),
            frequency: frequency.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    enum CodingKeys: String, CodingKey {
        case context, negativeEmotions, trigger, successCriteria
        case inOrderTo, positiveEmotions, frequency
    }

    /// Каждое поле опционально в JSON — файлы, где карточка появлялась
    /// постепенно (или собрана внешним инструментом), читаются без ошибок.
    /// Поле-строка (ранний формат карточки) мигрирует в список по переводам строк.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        context = Self.decodeList(container, .context)
        negativeEmotions = Self.decodeList(container, .negativeEmotions)
        trigger = Self.decodeList(container, .trigger)
        successCriteria = Self.decodeList(container, .successCriteria)
        inOrderTo = Self.decodeList(container, .inOrderTo)
        positiveEmotions = Self.decodeList(container, .positiveEmotions)
        frequency = (try? container.decodeIfPresent(String.self, forKey: .frequency)) ?? ""
    }

    private static func decodeList(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> [String] {
        if let list = try? container.decode([String].self, forKey: key) { return list }
        if let string = try? container.decode(String.self, forKey: key) {
            return string
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return []
    }
}

/// Узел графа работ: «role: хочу + глагол». Позиция узла задаётся
/// принадлежностью уровню (GraphLevel) и порядком в массиве jobs.
public struct JobNode: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var verb: String
    public var role: String?
    /// Карточка работы; у старых файлов и новых узлов — пустая.
    public var details: JobDetails

    public init(id: UUID = UUID(), verb: String, role: String? = nil, details: JobDetails = JobDetails()) {
        self.id = id
        self.verb = verb
        self.role = role
        self.details = details
    }

    /// Комбинированная строка для инлайн-редактора: `role: verb` или `verb`.
    public var displayText: String {
        if let role { return "\(role): \(verb)" }
        return verb
    }

    enum CodingKeys: String, CodingKey { case id, verb, role, details }

    /// Файлы до появления карточки не имеют ключа `details`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        verb = try container.decode(String.self, forKey: .verb)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        details = try container.decodeIfPresent(JobDetails.self, forKey: .details) ?? JobDetails()
    }

    /// Пустая карточка в JSON не пишется — файлы без описаний не растут.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(verb, forKey: .verb)
        try container.encodeIfPresent(role, forKey: .role)
        if !details.isEmpty {
            try container.encode(details, forKey: .details)
        }
    }
}

/// Уровень графа — горизонтальная полоса. Порядок `jobs` = слева направо.
/// `name` — пользовательское имя; nil — отображается дефолт «УРОВЕНЬ N»
/// (nil, а не пустая строка, чтобы имя пересчитывалось при перестановке уровней).
public struct GraphLevel: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var jobs: [JobNode]
    public var name: String?

    public init(id: UUID = UUID(), jobs: [JobNode] = [], name: String? = nil) {
        self.id = id
        self.jobs = jobs
        self.name = name
    }
}

/// Направленная связь между работами: `from` → `to`.
/// Связь либо внутри уровня (следующая работа справа), либо на уровень
/// ниже (декомпозиция). Тип не хранится — выводится из уровней узлов.
public struct JobEdge: Codable, Equatable, Hashable, Sendable {
    public var from: UUID
    public var to: UUID

    public init(from: UUID, to: UUID) {
        self.from = from
        self.to = to
    }
}

/// Граф работ: упорядоченные уровни (сверху вниз, 0 = самый верхний)
/// плюс рёбра. Не дерево: работа может быть автономной (без рёбер)
/// или иметь несколько связей.
public struct WorkGraph: Codable, Equatable, Sendable {
    public var levels: [GraphLevel]
    public var edges: [JobEdge]

    public init(levels: [GraphLevel] = [], edges: [JobEdge] = []) {
        self.levels = levels
        self.edges = edges
    }
}

// MARK: - Запросы

public extension WorkGraph {
    var allJobs: [JobNode] { levels.flatMap(\.jobs) }

    var jobCount: Int { levels.reduce(0) { $0 + $1.jobs.count } }

    func job(_ id: UUID) -> JobNode? {
        for level in levels {
            if let job = level.jobs.first(where: { $0.id == id }) { return job }
        }
        return nil
    }

    /// Индекс уровня, на котором лежит работа. nil, если работы нет.
    func levelIndex(of jobID: UUID) -> Int? {
        levels.firstIndex { $0.jobs.contains { $0.id == jobID } }
    }

    func levelIndex(id levelID: UUID) -> Int? {
        levels.firstIndex { $0.id == levelID }
    }

    /// Входящие связи работы (родители/предшественники).
    func sources(of jobID: UUID) -> [UUID] {
        edges.filter { $0.to == jobID }.map(\.from)
    }

    /// Исходящие связи работы.
    func targets(of jobID: UUID) -> [UUID] {
        edges.filter { $0.from == jobID }.map(\.to)
    }

    /// Работа и всё «ниже» неё: обход по исходящим связям без подъёма
    /// вверх. Горизонтальные связи учитываются только ниже стартового
    /// уровня — соседи самой работы по уровню в результат не попадают.
    func jobsBelow(_ jobID: UUID) -> Set<UUID> {
        guard let startLevel = levelIndex(of: jobID) else { return [] }
        var result: Set<UUID> = [jobID]
        var queue: [UUID] = [jobID]
        while let current = queue.popLast() {
            guard let currentLevel = levelIndex(of: current) else { continue }
            for target in targets(of: current) where !result.contains(target) {
                guard let targetLevel = levelIndex(of: target) else { continue }
                let descends = targetLevel > currentLevel
                    || (targetLevel == currentLevel && currentLevel > startLevel)
                if descends {
                    result.insert(target)
                    queue.append(target)
                }
            }
        }
        return result
    }

    /// Подграф из указанных работ: рёбра сохраняются только между
    /// оставшимися работами, опустевшие уровни отбрасываются.
    func subgraph(keeping ids: Set<UUID>) -> WorkGraph {
        let levels = self.levels
            .map { GraphLevel(id: $0.id, jobs: $0.jobs.filter { ids.contains($0.id) }, name: $0.name) }
            .filter { !$0.jobs.isEmpty }
        let edges = self.edges.filter { ids.contains($0.from) && ids.contains($0.to) }
        return WorkGraph(levels: levels, edges: edges)
    }
}

// MARK: - Миграция из формата v1 (дерево Job)

public extension WorkGraph {
    /// Разворачивает дерево v1 в уровни: глубина узла → индекс уровня,
    /// pre-order обход задаёт порядок слева направо, связи parent → child.
    init(tree: Job) {
        var levels: [[JobNode]] = []
        var edges: [JobEdge] = []

        func walk(_ node: Job, depth: Int) {
            if levels.count <= depth { levels.append([]) }
            levels[depth].append(JobNode(id: node.id, verb: node.verb, role: node.role))
            for child in node.children {
                edges.append(JobEdge(from: node.id, to: child.id))
                walk(child, depth: depth + 1)
            }
        }
        walk(tree, depth: 0)

        self.init(levels: levels.map { GraphLevel(jobs: $0) }, edges: edges)
    }
}
