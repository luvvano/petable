import Foundation

/// Происхождение артефакта (интервью, граф работ):
/// создан человеком или ИИ-агентом. nil в файле = человек.
public enum ArtifactOrigin: String, Codable, Sendable {
    case human
    case agent
}

/// JSON-ответ ИИ-агента на задачу «исследуй решение по AJTBD»:
/// заполненное интервью (по полям переданного шаблона) + граф работ.
/// Формат зафиксирован промптом (см. AgentPrompt в приложении).
public struct AgentArtifactsPayload: Codable, Equatable, Sendable {
    public struct Answer: Codable, Equatable, Sendable {
        public var fieldID: UUID
        public var answer: String

        public init(fieldID: UUID, answer: String) {
            self.fieldID = fieldID
            self.answer = answer
        }
    }

    public struct GraphNode: Codable, Equatable, Sendable {
        public var verb: String
        public var role: String?
        /// Имя области уровня (см. `LevelZone`) — работы того же уровня,
        /// которые продукт не выполняет. nil — основная область уровня.
        /// Узлы одного уровня с одинаковым именем попадают в одну область.
        public var zone: String?

        public init(verb: String, role: String? = nil, zone: String? = nil) {
            self.verb = verb
            self.role = role
            self.zone = zone
        }
    }

    /// Частичная правка карточки работы (команда update_job): nil-поле
    /// не трогается, пустой список/строка — очистка, значение — перезапись.
    public struct JobCard: Codable, Equatable, Sendable {
        public var context: [String]?
        public var negativeEmotions: [String]?
        public var trigger: [String]?
        public var successCriteria: [String]?
        public var inOrderTo: [String]?
        public var positiveEmotions: [String]?
        public var frequency: String?

        public init(
            context: [String]? = nil,
            negativeEmotions: [String]? = nil,
            trigger: [String]? = nil,
            successCriteria: [String]? = nil,
            inOrderTo: [String]? = nil,
            positiveEmotions: [String]? = nil,
            frequency: String? = nil
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
            context == nil && negativeEmotions == nil && trigger == nil
                && successCriteria == nil && inOrderTo == nil
                && positiveEmotions == nil && frequency == nil
        }

        /// Карточка после наложения правки на текущую: перечисленные поля
        /// перезаписываются, nil — остаются. Результат нормализован.
        public func merged(into details: JobDetails) -> JobDetails {
            JobDetails(
                context: context ?? details.context,
                negativeEmotions: negativeEmotions ?? details.negativeEmotions,
                trigger: trigger ?? details.trigger,
                successCriteria: successCriteria ?? details.successCriteria,
                inOrderTo: inOrderTo ?? details.inOrderTo,
                positiveEmotions: positiveEmotions ?? details.positiveEmotions,
                frequency: frequency ?? details.frequency
            ).normalized()
        }
    }

    public struct GraphEdge: Codable, Equatable, Sendable {
        public var fromLevel: Int
        public var fromIndex: Int
        public var toLevel: Int
        public var toIndex: Int

        public init(fromLevel: Int, fromIndex: Int, toLevel: Int, toIndex: Int) {
            self.fromLevel = fromLevel
            self.fromIndex = fromIndex
            self.toLevel = toLevel
            self.toIndex = toIndex
        }
    }

    public struct Graph: Codable, Equatable, Sendable {
        public var name: String
        /// Уровни сверху вниз (0 — большие работы), работы слева направо.
        public var levels: [[GraphNode]]
        public var edges: [GraphEdge]
        /// Индекс уровня кóровых работ (продукт выполняет их целиком).
        /// nil или индекс за пределами — core назначит ensureCoreLevel.
        public var coreLevel: Int?

        public init(name: String, levels: [[GraphNode]], edges: [GraphEdge] = [], coreLevel: Int? = nil) {
            self.name = name
            self.levels = levels
            self.edges = edges
            self.coreLevel = coreLevel
        }
    }

    public var interviewName: String
    public var placeholders: [String: String]
    public var answers: [Answer]
    public var graph: Graph

    public init(
        interviewName: String,
        placeholders: [String: String] = [:],
        answers: [Answer] = [],
        graph: Graph
    ) {
        self.interviewName = interviewName
        self.placeholders = placeholders
        self.answers = answers
        self.graph = graph
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case noJSONFound
        case emptyGraph

        public var errorDescription: String? {
            switch self {
            case .noJSONFound:
                return "В ответе агента не найден JSON-объект."
            case .emptyGraph:
                return "Агент вернул пустой граф работ."
            }
        }
    }

    /// Достаёт первый сбалансированный JSON-объект из текста ответа
    /// модели (модели любят обернуть JSON в прозу или ```-фенсы)
    /// и декодирует его.
    public static func parse(from text: String) throws -> AgentArtifactsPayload {
        guard let json = firstJSONObject(in: text),
              let data = json.data(using: .utf8)
        else { throw ParseError.noJSONFound }
        let payload = try JSONDecoder().decode(AgentArtifactsPayload.self, from: data)
        guard payload.graph.levels.contains(where: { !$0.isEmpty }) else {
            throw ParseError.emptyGraph
        }
        return payload
    }

    /// Первый сбалансированный `{...}` с учётом строк и экранирования.
    static func firstJSONObject(in text: String) -> String? {
        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if escaped {
                escaped = false
            } else if inString {
                if character == "\\" { escaped = true }
                if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(text[start...index])
                    }
                default: break
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    // MARK: - Payload → артефакты документа

    /// Интервью из ответа агента: снапшот шаблона + ответы по валидным
    /// id полей + плейсхолдеры. Ответы на неизвестные поля отбрасываются.
    public func makeInterview(template: InterviewTemplate, createdAt: Date = Date()) -> Interview {
        let knownFieldIDs = Set(template.sections.flatMap(\.fields).map(\.id))
        var interview = Interview(
            name: interviewName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Интервью агента" : interviewName,
            template: template,
            createdAt: createdAt,
            origin: .agent
        )
        for answer in answers where knownFieldIDs.contains(answer.fieldID) {
            interview.setAnswer(answer.answer, for: answer.fieldID)
        }
        // Явные плейсхолдеры агента поверх выведенных из ответов.
        for (key, value) in placeholders {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                interview.placeholderValues[key] = trimmed
            }
        }
        return interview
    }

    /// Граф работ из ответа агента. Пустые узлы и рёбра с индексами
    /// за пределами уровней отбрасываются.
    public func makeWorkGraph() -> WorkGraph {
        graph.makeWorkGraph()
    }
}

public extension AgentArtifactsPayload.Graph {
    /// Граф работ из транспортной формы (уровни/рёбра по индексам).
    /// Пустые узлы и рёбра с индексами за пределами уровней отбрасываются.
    /// Порядок узлов внутри уровня на этом шаге сохраняется как прислал
    /// агент — по нему адресуются рёбра; группировка по областям
    /// (`normalizeZones`) делается после разбора рёбер.
    func makeWorkGraph() -> WorkGraph {
        var levels: [GraphLevel] = self.levels.map { nodes in
            var zones: [LevelZone] = []
            let jobs: [JobNode] = nodes.compactMap { node in
                let verb = node.verb.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !verb.isEmpty else { return nil }
                let role = node.role?.trimmingCharacters(in: .whitespacesAndNewlines)
                let zoneName = node.zone?.trimmingCharacters(in: .whitespacesAndNewlines)
                var zoneID: UUID?
                if let zoneName, !zoneName.isEmpty {
                    if let existing = zones.first(where: { $0.resolvedName == zoneName }) {
                        zoneID = existing.id
                    } else {
                        let zone = LevelZone(name: zoneName)
                        zones.append(zone)
                        zoneID = zone.id
                    }
                }
                return JobNode(
                    verb: verb,
                    role: (role?.isEmpty ?? true) ? nil : role,
                    zoneID: zoneID
                )
            }
            return GraphLevel(jobs: jobs, zones: zones)
        }
        if let coreLevel, levels.indices.contains(coreLevel) {
            levels[coreLevel].isCore = true
        }
        var jobEdges: [JobEdge] = []
        for edge in edges {
            guard levels.indices.contains(edge.fromLevel),
                  levels[edge.fromLevel].jobs.indices.contains(edge.fromIndex),
                  levels.indices.contains(edge.toLevel),
                  levels[edge.toLevel].jobs.indices.contains(edge.toIndex)
            else { continue }
            let jobEdge = JobEdge(
                from: levels[edge.fromLevel].jobs[edge.fromIndex].id,
                to: levels[edge.toLevel].jobs[edge.toIndex].id
            )
            if !jobEdges.contains(jobEdge), jobEdge.from != jobEdge.to {
                jobEdges.append(jobEdge)
            }
        }
        var graph = WorkGraph(levels: levels.filter { !$0.jobs.isEmpty }, edges: jobEdges)
        graph.ensureCoreLevel()
        // Рёбра уже разобраны по id — перестановка работ по областям безопасна.
        graph.normalizeZones()
        return graph
    }

    /// Граф из транспортной формы с переносом данных из прежнего графа
    /// (правка update_graph — структура заменяется, наработки остаются):
    /// узлы сопоставляются по (role, verb), дубликаты — по порядку, —
    /// совпавшие сохраняют id, карточку и область; уровни наследуют id,
    /// имя и области уровня прежнего графа с тем же индексом.
    /// Область работы переживает правку, даже если агент не перечислил
    /// её в payload: иначе структурная правка стирала бы разметку
    /// «эти работы продукт не выполняет».
    func makeWorkGraph(preservingFrom old: WorkGraph) -> WorkGraph {
        var graph = makeWorkGraph()
        var pool: [String: [JobNode]] = [:]
        for job in old.allJobs {
            pool[Self.matchKey(job), default: []].append(job)
        }
        var idMap: [UUID: UUID] = [:]
        for levelIndex in graph.levels.indices {
            let oldLevel = old.levels.indices.contains(levelIndex) ? old.levels[levelIndex] : nil
            if let oldLevel {
                graph.levels[levelIndex].id = oldLevel.id
                graph.levels[levelIndex].name = oldLevel.name
                // Область с тем же именем — та же область: наследует id.
                for zoneIndex in graph.levels[levelIndex].zones.indices {
                    let name = graph.levels[levelIndex].zones[zoneIndex].resolvedName
                    guard let match = oldLevel.zones.first(where: { $0.resolvedName == name })
                    else { continue }
                    let replaced = graph.levels[levelIndex].zones[zoneIndex].id
                    graph.levels[levelIndex].zones[zoneIndex].id = match.id
                    for jobIndex in graph.levels[levelIndex].jobs.indices
                    where graph.levels[levelIndex].jobs[jobIndex].zoneID == replaced {
                        graph.levels[levelIndex].jobs[jobIndex].zoneID = match.id
                    }
                }
            }
            for jobIndex in graph.levels[levelIndex].jobs.indices {
                let key = Self.matchKey(graph.levels[levelIndex].jobs[jobIndex])
                guard var candidates = pool[key], !candidates.isEmpty else { continue }
                let previous = candidates.removeFirst()
                pool[key] = candidates
                idMap[graph.levels[levelIndex].jobs[jobIndex].id] = previous.id
                graph.levels[levelIndex].jobs[jobIndex].id = previous.id
                graph.levels[levelIndex].jobs[jobIndex].details = previous.details
                // Агент не указал область — берём прежнюю (только своего уровня).
                if graph.levels[levelIndex].jobs[jobIndex].zoneID == nil,
                   let zoneID = previous.zoneID,
                   let zone = oldLevel?.zone(zoneID) {
                    if !graph.levels[levelIndex].zones.contains(where: { $0.id == zone.id }) {
                        graph.levels[levelIndex].zones.append(zone)
                    }
                    graph.levels[levelIndex].jobs[jobIndex].zoneID = zone.id
                }
            }
        }
        graph.edges = graph.edges.map {
            JobEdge(from: idMap[$0.from] ?? $0.from, to: idMap[$0.to] ?? $0.to)
        }
        graph.normalizeZones()
        return graph
    }

    private static func matchKey(_ node: JobNode) -> String {
        "\(node.role ?? "")\u{1}\(node.verb)"
    }
}
