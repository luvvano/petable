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

        public init(verb: String, role: String? = nil) {
            self.verb = verb
            self.role = role
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
    func makeWorkGraph() -> WorkGraph {
        var levels: [GraphLevel] = self.levels.map { nodes in
            GraphLevel(jobs: nodes.compactMap { node in
                let verb = node.verb.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !verb.isEmpty else { return nil }
                let role = node.role?.trimmingCharacters(in: .whitespacesAndNewlines)
                return JobNode(verb: verb, role: (role?.isEmpty ?? true) ? nil : role)
            })
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
        return graph
    }
}
