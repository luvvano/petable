import Foundation

// MARK: - Команды чат-агента

/// Команда, которую чат-агент вкладывает в ответ fenced-блоком
/// ```petable-action { JSON }``` — создание или правка артефактов
/// проекта. Формат зафиксирован промптом (см. AgentPrompt в приложении).
public enum AgentChatAction: Equatable, Sendable {
    /// Новый граф работ (уровни/рёбра по индексам, как AgentArtifactsPayload).
    case createGraph(AgentArtifactsPayload.Graph)
    /// Полная замена структуры существующего графа; имя из graph.name
    /// (пустое — оставить прежнее).
    case updateGraph(id: UUID, graph: AgentArtifactsPayload.Graph)
    /// Новое интервью по шаблону проекта: ответы по fieldID шаблона.
    case createInterview(
        templateID: UUID,
        name: String,
        placeholders: [String: String],
        answers: [AgentArtifactsPayload.Answer]
    )
    /// Правка интервью: перечисленные ответы/плейсхолдеры перезаписываются,
    /// остальные не трогаются.
    case updateInterview(
        id: UUID,
        placeholders: [String: String],
        answers: [AgentArtifactsPayload.Answer]
    )

    public enum ParseError: Error, Equatable {
        case unknownAction(String)
        case invalidJSON
    }

    /// Транспортная форма JSON-объекта команды.
    private struct Raw: Codable {
        var action: String
        var graph: AgentArtifactsPayload.Graph?
        var graphID: UUID?
        var templateID: UUID?
        var interviewID: UUID?
        var interviewName: String?
        var placeholders: [String: String]?
        var answers: [AgentArtifactsPayload.Answer]?
    }

    /// Декодирует одну команду из JSON-текста блока.
    public static func decode(json: String) throws -> AgentChatAction {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data)
        else { throw ParseError.invalidJSON }
        switch raw.action {
        case "create_graph":
            guard let graph = raw.graph else { throw ParseError.invalidJSON }
            return .createGraph(graph)
        case "update_graph":
            guard let id = raw.graphID, let graph = raw.graph else { throw ParseError.invalidJSON }
            return .updateGraph(id: id, graph: graph)
        case "create_interview":
            guard let templateID = raw.templateID else { throw ParseError.invalidJSON }
            return .createInterview(
                templateID: templateID,
                name: raw.interviewName ?? "",
                placeholders: raw.placeholders ?? [:],
                answers: raw.answers ?? []
            )
        case "update_interview":
            guard let id = raw.interviewID else { throw ParseError.invalidJSON }
            return .updateInterview(
                id: id,
                placeholders: raw.placeholders ?? [:],
                answers: raw.answers ?? []
            )
        default:
            throw ParseError.unknownAction(raw.action)
        }
    }
}

// MARK: - Разбор ответа агента

/// Ответ чат-агента: текст для человека + извлечённые команды.
/// Блоки ```petable-action``` вырезаются из отображаемого текста.
public struct AgentChatReply: Equatable, Sendable {
    public var text: String
    public var actions: [AgentChatAction]
    /// Сколько блоков не удалось разобрать (битый JSON/неизвестная команда).
    public var invalidActionCount: Int

    public init(text: String, actions: [AgentChatAction] = [], invalidActionCount: Int = 0) {
        self.text = text
        self.actions = actions
        self.invalidActionCount = invalidActionCount
    }

    private static let fenceMarker = "```petable-action"

    /// Разбирает сырой текст модели: вырезает fenced-блоки команд,
    /// декодирует каждый; невалидные блоки считаются, но не роняют разбор.
    public static func parse(from raw: String) -> AgentChatReply {
        var actions: [AgentChatAction] = []
        var invalid = 0
        var display = ""
        var rest = Substring(raw)

        while let markerRange = rest.range(of: fenceMarker) {
            display += rest[..<markerRange.lowerBound]
            let afterMarker = rest[markerRange.upperBound...]
            guard let closing = afterMarker.range(of: "```") else {
                // Незакрытый блок — пробуем разобрать до конца текста.
                appendAction(String(afterMarker), to: &actions, invalid: &invalid)
                rest = ""
                break
            }
            appendAction(String(afterMarker[..<closing.lowerBound]), to: &actions, invalid: &invalid)
            rest = afterMarker[closing.upperBound...]
        }
        display += rest

        return AgentChatReply(
            text: display.trimmingCharacters(in: .whitespacesAndNewlines),
            actions: actions,
            invalidActionCount: invalid
        )
    }

    private static func appendAction(
        _ blockBody: String,
        to actions: inout [AgentChatAction],
        invalid: inout Int
    ) {
        guard let json = AgentArtifactsPayload.firstJSONObject(in: blockBody),
              let action = try? AgentChatAction.decode(json: json)
        else {
            invalid += 1
            return
        }
        actions.append(action)
    }
}

// MARK: - Контекст проекта для промпта

/// Компактное текстовое описание артефактов проекта — уходит в system-
/// промпт чата, чтобы агент видел текущее состояние и настоящие ID.
public enum AgentChatContext {
    public static func describe(
        graphs: [Envelope.Stage],
        research: Research,
        segments: [Segment]
    ) -> String {
        var lines: [String] = []

        lines.append("Графы работ (уровень 0 — большие работы; узлы по индексам):")
        for stage in graphs {
            lines.append("- graphID \(stage.id.uuidString) «\(stage.name)»")
            for (levelIndex, level) in stage.graph.levels.enumerated() {
                let nodes = level.jobs.enumerated().map { index, job in
                    "[\(index)] «\(job.displayText)»"
                }
                lines.append("  уровень \(levelIndex): \(nodes.joined(separator: " "))")
            }
            let edges = indexEdges(of: stage.graph)
            if !edges.isEmpty {
                lines.append("  рёбра: \(edges.joined(separator: ", "))")
            }
        }

        lines.append("Шаблоны интервью:")
        for template in research.templates {
            lines.append("- templateID \(template.id.uuidString) «\(template.name)»")
            for section in template.sections {
                for field in section.fields {
                    lines.append("  fieldID \(field.id.uuidString): «\(field.title)»")
                }
            }
        }

        lines.append("Интервью:")
        if research.interviews.isEmpty { lines.append("- нет") }
        for interview in research.interviews {
            lines.append("- interviewID \(interview.id.uuidString) «\(interview.name)» (шаблон «\(interview.template.name)»)")
            for section in interview.template.sections {
                for field in section.fields {
                    guard let answer = interview.answers[field.id], !answer.isEmpty else { continue }
                    lines.append("  fieldID \(field.id.uuidString) («\(field.title)»): \(answer)")
                }
            }
        }

        if !segments.isEmpty {
            lines.append("Сегменты:")
            for segment in segments {
                lines.append("- segmentID \(segment.id.uuidString) «\(segment.name)»")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Рёбра графа как пары «уровень.индекс→уровень.индекс».
    private static func indexEdges(of graph: WorkGraph) -> [String] {
        var position: [UUID: (level: Int, index: Int)] = [:]
        for (levelIndex, level) in graph.levels.enumerated() {
            for (index, job) in level.jobs.enumerated() {
                position[job.id] = (levelIndex, index)
            }
        }
        return graph.edges.compactMap { edge in
            guard let from = position[edge.from], let to = position[edge.to] else { return nil }
            return "\(from.level).\(from.index)→\(to.level).\(to.index)"
        }
    }
}
