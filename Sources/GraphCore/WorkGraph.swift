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
    /// Область уровня, в которой лежит работа; nil — основная область
    /// (её выполняет продукт). Зона всегда принадлежит тому же уровню.
    public var zoneID: UUID?

    public init(
        id: UUID = UUID(),
        verb: String,
        role: String? = nil,
        details: JobDetails = JobDetails(),
        zoneID: UUID? = nil
    ) {
        self.id = id
        self.verb = verb
        self.role = role
        self.details = details
        self.zoneID = zoneID
    }

    /// Комбинированная строка для инлайн-редактора: `role: verb` или `verb`.
    public var displayText: String {
        if let role { return "\(role): \(verb)" }
        return verb
    }

    enum CodingKeys: String, CodingKey { case id, verb, role, details, zoneID }

    /// Файлы до появления карточки не имеют ключа `details`,
    /// файлы до v8 — ключа `zoneID`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        verb = try container.decode(String.self, forKey: .verb)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        details = try container.decodeIfPresent(JobDetails.self, forKey: .details) ?? JobDetails()
        zoneID = try container.decodeIfPresent(UUID.self, forKey: .zoneID)
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
        try container.encodeIfPresent(zoneID, forKey: .zoneID)
    }
}

/// Область внутри уровня — отдельная рамка на той же полосе со своим
/// именем. Смысл по AJTBD: работы того же уровня, которые продукт
/// не выполняет (малые работы рядом с кóровыми). Уровень остаётся один —
/// меняется только покрытие продуктом, и это видно на канвасе.
public struct LevelZone: Codable, Equatable, Identifiable, Sendable {
    public static let defaultName = "SMALL JOBS"

    public var id: UUID
    /// Пользовательское имя; nil — отображается `defaultName`.
    public var name: String?

    public init(id: UUID = UUID(), name: String? = nil) {
        self.id = id
        self.name = name
    }

    public var resolvedName: String { name ?? Self.defaultName }
}

/// Уровень графа — горизонтальная полоса. Порядок `jobs` = слева направо.
/// `name` — пользовательское имя; nil — отображается дефолт «УРОВЕНЬ N»
/// (nil, а не пустая строка, чтобы имя пересчитывалось при перестановке уровней).
/// `isCore` — уровень кóровых работ: продукт выполняет их целиком.
/// Такой уровень в графе ровно один — инвариант держит
/// `WorkGraph.ensureCoreLevel()`, вызываемый на границах документа.
/// `zones` — отдельные области внутри полосы (см. `LevelZone`): работы
/// того же уровня, которые продукт не выполняет.
public struct GraphLevel: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Работы уровня слева направо. Сгруппированы по областям: сначала
    /// основная область (zoneID == nil), затем работы зон в порядке
    /// `zones` — инвариант держит `normalizeZones()`.
    public var jobs: [JobNode]
    public var name: String?
    public var isCore: Bool
    public var zones: [LevelZone]

    public init(
        id: UUID = UUID(),
        jobs: [JobNode] = [],
        name: String? = nil,
        isCore: Bool = false,
        zones: [LevelZone] = []
    ) {
        self.id = id
        self.jobs = jobs
        self.name = name
        self.isCore = isCore
        self.zones = zones
    }

    enum CodingKeys: String, CodingKey { case id, jobs, name, isCore, zones }

    /// Файлы до v7 не имеют ключа `isCore`, до v8 — ключа `zones`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        jobs = try container.decode([JobNode].self, forKey: .jobs)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        isCore = try container.decodeIfPresent(Bool.self, forKey: .isCore) ?? false
        zones = try container.decodeIfPresent([LevelZone].self, forKey: .zones) ?? []
    }

    /// false и пустой список зон в JSON не пишутся — как пустая карточка узла.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(jobs, forKey: .jobs)
        try container.encodeIfPresent(name, forKey: .name)
        if isCore {
            try container.encode(isCore, forKey: .isCore)
        }
        if !zones.isEmpty {
            try container.encode(zones, forKey: .zones)
        }
    }
}

// MARK: - Области уровня

public extension GraphLevel {
    /// Области уровня слева направо: nil — основная (её выполняет
    /// продукт), дальше зоны в порядке `zones`.
    var groupIDs: [UUID?] { [nil] + zones.map { Optional($0.id) } }

    /// Порядковый номер области: 0 — основная, дальше зоны по порядку.
    /// Неизвестная зона считается основной областью (битый файл).
    func groupOrder(_ zoneID: UUID?) -> Int {
        guard let zoneID, let index = zones.firstIndex(where: { $0.id == zoneID }) else { return 0 }
        return index + 1
    }

    func jobs(in zoneID: UUID?) -> [JobNode] {
        jobs.filter { $0.zoneID == zoneID }
    }

    func zone(_ zoneID: UUID) -> LevelZone? {
        zones.first { $0.id == zoneID }
    }

    /// Индекс в массиве `jobs`, куда встаёт работа области `zoneID`,
    /// вставляемая на позицию `index` внутри своей области.
    func insertionIndex(zone zoneID: UUID?, at index: Int) -> Int {
        let order = groupOrder(zoneID)
        let before = jobs.filter { groupOrder($0.zoneID) < order }.count
        let inGroup = jobs.filter { groupOrder($0.zoneID) == order }.count
        return before + min(max(index, 0), inGroup)
    }

    /// Инвариант порядка: ссылки на несуществующие зоны сбрасываются,
    /// работы группируются по областям (порядок внутри области сохраняется).
    mutating func normalizeZones() {
        let known = Set(zones.map(\.id))
        for index in jobs.indices {
            if let zoneID = jobs[index].zoneID, !known.contains(zoneID) {
                jobs[index].zoneID = nil
            }
        }
        guard !zones.isEmpty else { return }
        jobs = groupIDs.flatMap { id in jobs.filter { $0.zoneID == id } }
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

    /// Индекс core-уровня. nil только у графа, не прошедшего
    /// `ensureCoreLevel()` (транзитные значения вроде subgraph).
    var coreLevelIndex: Int? {
        levels.firstIndex(where: \.isCore)
    }

    /// Инвариант «core-уровень есть всегда и он один». Вызывается на
    /// границах документа: чтение файла, создание стадии, граф от агента.
    /// Пустой граф получает один пустой core-уровень. Без отметки core
    /// назначается уровень с именем, содержащим «core» (переименованные
    /// руками старые графы), иначе верхний. Лишние отметки (битый файл)
    /// снимаются — остаётся верхняя.
    mutating func ensureCoreLevel() {
        guard !levels.isEmpty else {
            levels = [GraphLevel(isCore: true)]
            return
        }
        let flagged = levels.indices.filter { levels[$0].isCore }
        if flagged.isEmpty {
            let named = levels.firstIndex {
                $0.name?.range(of: "core", options: .caseInsensitive) != nil
            }
            levels[named ?? 0].isCore = true
        } else {
            for index in flagged.dropFirst() {
                levels[index].isCore = false
            }
        }
    }

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

    /// Инвариант областей на всех уровнях. Вызывается там же, где
    /// `ensureCoreLevel()` — на границах документа.
    mutating func normalizeZones() {
        for index in levels.indices {
            levels[index].normalizeZones()
        }
    }

    /// Область, в которой лежит работа; nil — основная область уровня
    /// (или работы нет).
    func zone(of jobID: UUID) -> UUID? {
        for level in levels {
            if let job = level.jobs.first(where: { $0.id == jobID }) { return job.zoneID }
        }
        return nil
    }

    /// Индекс уровня, которому принадлежит область.
    func levelIndex(zone zoneID: UUID) -> Int? {
        levels.firstIndex { $0.zones.contains { $0.id == zoneID } }
    }

    func zone(id zoneID: UUID) -> LevelZone? {
        for level in levels {
            if let zone = level.zone(zoneID) { return zone }
        }
        return nil
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
    /// оставшимися работами, опустевшие уровни и области отбрасываются.
    func subgraph(keeping ids: Set<UUID>) -> WorkGraph {
        let levels = self.levels
            .map { level -> GraphLevel in
                let jobs = level.jobs.filter { ids.contains($0.id) }
                return GraphLevel(
                    id: level.id,
                    jobs: jobs,
                    name: level.name,
                    isCore: level.isCore,
                    zones: level.zones.filter { zone in jobs.contains { $0.zoneID == zone.id } }
                )
            }
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
