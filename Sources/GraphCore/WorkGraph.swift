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
    /// Цепочка справа свёрнута: работы, связанные с этой внутри уровня,
    /// скрыты с канваса вместе со своей декомпозицией. Флаг живёт
    /// на голове цепочки — сама голова видна всегда.
    /// Подробности — `WorkGraph.hiddenJobs()`.
    public var isCollapsed: Bool

    public init(
        id: UUID = UUID(),
        verb: String,
        role: String? = nil,
        details: JobDetails = JobDetails(),
        zoneID: UUID? = nil,
        isCollapsed: Bool = false
    ) {
        self.id = id
        self.verb = verb
        self.role = role
        self.details = details
        self.zoneID = zoneID
        self.isCollapsed = isCollapsed
    }

    /// Комбинированная строка для инлайн-редактора: `role: verb` или `verb`.
    public var displayText: String {
        if let role { return "\(role): \(verb)" }
        return verb
    }

    enum CodingKeys: String, CodingKey { case id, verb, role, details, zoneID, isCollapsed }

    /// Файлы до появления карточки не имеют ключа `details`,
    /// файлы до v8 — ключа `zoneID`, файлы до сворачивания цепочек —
    /// ключа `isCollapsed`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        verb = try container.decode(String.self, forKey: .verb)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        details = try container.decodeIfPresent(JobDetails.self, forKey: .details) ?? JobDetails()
        zoneID = try container.decodeIfPresent(UUID.self, forKey: .zoneID)
        isCollapsed = try container.decodeIfPresent(Bool.self, forKey: .isCollapsed) ?? false
    }

    /// Пустая карточка в JSON не пишется — файлы без описаний не растут.
    /// Так же и развёрнутая цепочка: `false` не пишется.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(verb, forKey: .verb)
        try container.encodeIfPresent(role, forKey: .role)
        if !details.isEmpty {
            try container.encode(details, forKey: .details)
        }
        try container.encodeIfPresent(zoneID, forKey: .zoneID)
        if isCollapsed {
            try container.encode(isCollapsed, forKey: .isCollapsed)
        }
    }
}

/// Область внутри уровня — отдельная рамка на той же полосе со своим
/// именем. Смысл по AJTBD: работы того же уровня, которые продукт
/// не выполняет (малые работы рядом с кóровыми). Уровень остаётся один —
/// меняется только покрытие продуктом, и это видно на канвасе.
/// Поэтому область бывает только на core-уровне: на остальных уровнях
/// продукт и так не выполняет работы целиком — рамка ничего не различала бы.
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
/// того же уровня, которые продукт не выполняет. Есть только у core-уровня —
/// инвариант держит `WorkGraph.normalizeZones()`.
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
    /// `ensureCoreLevel()` — на границах документа (и после него: правило
    /// «области только у core» опирается на проставленную отметку).
    /// Области живут только на core-уровне — рамка «эти работы продукт
    /// не выполняет» осмысленна лишь рядом с кóровыми. Рамки с других
    /// уровней (старый файл, граф от агента) снимаются, их работы
    /// уходят в основную область — как при `deleteZone`.
    mutating func normalizeZones() {
        for index in levels.indices {
            if !levels[index].isCore {
                levels[index].zones.removeAll()
            }
            levels[index].normalizeZones()
        }
    }

    /// Инвариант направления связей: межуровневая связь идёт сверху
    /// вниз — `from` лежит на уровне выше `to`. Пользователь тянет
    /// связь в любую сторону (⌘-клик, drag от плюса), и связь снизу
    /// вверх оседала в графе ребром, на канвасе неотличимым
    /// от обычного, но невидимым для обходов по исходящим связям —
    /// свёртка цепочек прятала не то, декомпозиция не подсвечивалась.
    /// Связи внутри уровня направление сохраняют: это порядок цепочки.
    mutating func normalizeEdges() {
        var levelOf: [UUID: Int] = [:]
        for (index, level) in levels.enumerated() {
            for job in level.jobs { levelOf[job.id] = index }
        }
        for index in edges.indices {
            guard let from = levelOf[edges[index].from],
                  let to = levelOf[edges[index].to],
                  to < from
            else { continue }
            edges[index] = JobEdge(from: edges[index].to, to: edges[index].from)
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

    /// Работа и всё «ниже» неё: обход вниз по уровням без подъёма вверх.
    /// Межуровневая связь считается декомпозицией независимо от того,
    /// в какую сторону её протянули: пользователь соединяет работу
    /// с родителем и снизу вверх (⌘-клик, drag от нижней), и такая
    /// связь на канвасе ничем не отличается от обычной — подсветка
    /// не имеет права её терять. Горизонтальная связь остаётся
    /// направленной (цепочка идёт слева направо) и учитывается только
    /// ниже стартового уровня — соседи самой работы по уровню
    /// в результат не попадают.
    func jobsBelow(_ jobID: UUID) -> Set<UUID> {
        guard let startLevel = levelIndex(of: jobID) else { return [] }
        var result: Set<UUID> = [jobID]
        var queue: [UUID] = [jobID]
        while let current = queue.popLast() {
            guard let currentLevel = levelIndex(of: current) else { continue }
            for edge in edges {
                let next: UUID
                let isOutgoing: Bool
                if edge.from == current {
                    next = edge.to
                    isOutgoing = true
                } else if edge.to == current {
                    next = edge.from
                    isOutgoing = false
                } else {
                    continue
                }
                guard !result.contains(next),
                      let nextLevel = levelIndex(of: next)
                else { continue }
                let descends = nextLevel > currentLevel
                    || (isOutgoing && nextLevel == currentLevel && currentLevel > startLevel)
                if descends {
                    result.insert(next)
                    queue.append(next)
                }
            }
        }
        return result
    }

    /// Следующие работы цепочки: связи внутри уровня и внутри той же
    /// области. Цепочка — последовательность работ ОДНОГО уровня;
    /// связь на другой уровень (декомпозиция) или в соседнюю область
    /// продолжением цепочки не считается.
    func chainSuccessors(of jobID: UUID) -> [UUID] {
        guard let levelIndex = levelIndex(of: jobID), let job = job(jobID) else { return [] }
        return targets(of: jobID).filter { target in
            self.levelIndex(of: target) == levelIndex && zone(of: target) == job.zoneID
        }
    }

    /// Вся цепочка справа от работы (транзитивно, по связям внутри
    /// уровня). Сама работа в результат не входит; связь назад
    /// (цикл в графе) обход не зацикливает.
    func chain(after jobID: UUID) -> [UUID] {
        var result: [UUID] = []
        var seen: Set<UUID> = [jobID]
        var queue: [UUID] = [jobID]
        while let current = queue.popLast() {
            for next in chainSuccessors(of: current) where seen.insert(next).inserted {
                result.append(next)
                queue.append(next)
            }
        }
        return result
    }

    /// Работы, скрытые свёрнутыми цепочками: сами работы цепочек справа
    /// от свёрнутых голов плюс их декомпозиция — работа уровнем ниже
    /// прячется, если ВСЕ её источники скрыты (иначе она осталась бы
    /// на канвасе висеть без единой видимой связи). Работа, у которой
    /// остался живой источник, видна — теряется только линия к скрытой.
    ///
    /// Это единственное место, где флаг `isCollapsed` превращается
    /// в множество скрытых работ: раскладка и канвас спрашивают его.
    func hiddenJobs() -> Set<UUID> {
        let heads = levels.flatMap(\.jobs).filter(\.isCollapsed)
        guard !heads.isEmpty else { return [] }

        // Индексы вместо повторных линейных поисков: раскладка зовёт
        // эту функцию на каждой перерисовке канваса.
        var slot: [UUID: (level: Int, zone: UUID?)] = [:]
        for (levelIndex, level) in levels.enumerated() {
            for job in level.jobs {
                slot[job.id] = (levelIndex, job.zoneID)
            }
        }
        var outgoing: [UUID: [UUID]] = [:]
        var incoming: [UUID: [UUID]] = [:]
        for edge in edges {
            outgoing[edge.from, default: []].append(edge.to)
            incoming[edge.to, default: []].append(edge.from)
        }

        // Обход от каждой головы отдельно: своя голова в свою цепочку
        // не попадает даже при связи назад (цикл), а голову, лежащую
        // внутри ЧУЖОЙ свёрнутой цепочки, спрячет обход той цепочки.
        var hidden: Set<UUID> = []
        for head in heads {
            var seen: Set<UUID> = [head.id]
            var queue: [UUID] = [head.id]
            while let current = queue.popLast() {
                guard let place = slot[current] else { continue }
                for next in outgoing[current] ?? [] where slot[next].map({
                    $0.level == place.level && $0.zone == place.zone
                }) == true {
                    guard seen.insert(next).inserted else { continue }
                    hidden.insert(next)
                    queue.append(next)
                }
            }
        }
        guard !hidden.isEmpty else { return [] }

        // Декомпозиция уходит вместе со своей работой. Идём до
        // неподвижной точки: скрытая ветка тянет за собой всю глубину.
        var changed = true
        while changed {
            changed = false
            for level in levels {
                for job in level.jobs where !hidden.contains(job.id) {
                    guard let jobLevel = slot[job.id]?.level,
                          let sources = incoming[job.id], !sources.isEmpty,
                          sources.allSatisfy({ source in
                              hidden.contains(source) && (slot[source]?.level ?? jobLevel) < jobLevel
                          })
                    else { continue }
                    hidden.insert(job.id)
                    changed = true
                }
            }
        }
        return hidden
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
