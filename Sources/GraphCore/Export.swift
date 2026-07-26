import Foundation

/// Экспортные файлы petable: интервью (JSON) и граф работ (JSON).
/// Отдельный формат от конверта документа: файл несёт один артефакт,
/// имеет собственные `type` и `version` — чтобы импорт мог отличить
/// граф от интервью и от чужого JSON. Markdown-экспорт интервью тоже
/// здесь; PDF собирается в приложении (AppKit) из тех же данных.

/// Ошибки чтения экспортных файлов.
public enum ExportFileError: Error, Equatable, LocalizedError {
    case wrongType(found: String, expected: String)
    case unsupportedVersion(found: Int, supported: Int)

    public var errorDescription: String? {
        switch self {
        case let .wrongType(found, expected):
            return "Файл имеет тип «\(found)», ожидался «\(expected)»."
        case let .unsupportedVersion(found, supported):
            return "Файл создан более новой версией petable (формат v\(found), поддерживается v\(supported)). Обновите приложение."
        }
    }
}

/// Общие кодеки экспортных файлов: ISO8601-даты (файл читают люди
/// и внешние инструменты), стабильный порядок ключей.
enum ExportCoding {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Заголовок любого экспортного файла. Проверяется до разбора
    /// полезной нагрузки: иначе чужой тип падает на отсутствующем
    /// ключе нагрузки с невнятной ошибкой декодера вместо понятной
    /// «файл имеет тип X, ожидался Y».
    private struct Header: Codable {
        var version: Int
        var type: String
    }

    /// Валидирует `type` и `version` файла до полного декодирования.
    static func validateHeader(_ data: Data, expectedType: String, supportedVersion: Int) throws {
        let header = try makeDecoder().decode(Header.self, from: data)
        guard header.type == expectedType else {
            throw ExportFileError.wrongType(found: header.type, expected: expectedType)
        }
        guard header.version <= supportedVersion else {
            throw ExportFileError.unsupportedVersion(found: header.version, supported: supportedVersion)
        }
    }
}

// MARK: - Интервью

/// Файл экспорта интервью: `{ version, type, interview }`.
public struct InterviewExportFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileType = "petable.interview"

    public var version: Int
    public var type: String
    public var interview: Interview

    public init(interview: Interview) {
        self.version = Self.currentVersion
        self.type = Self.fileType
        self.interview = interview
    }

    public func encoded() throws -> Data {
        try ExportCoding.makeEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> InterviewExportFile {
        try ExportCoding.validateHeader(data, expectedType: fileType, supportedVersion: currentVersion)
        return try ExportCoding.makeDecoder().decode(InterviewExportFile.self, from: data)
    }
}

/// Текстовые представления интервью для экспорта.
public enum InterviewExport {
    public static func json(_ interview: Interview) throws -> Data {
        try InterviewExportFile(interview: interview).encoded()
    }

    /// Markdown: шапка с метаданными, плейсхолдеры, секции шаблона.
    /// Вопросы — с подставленными плейсхолдерами, ответы — цитатами;
    /// подсказки интервьюеру в экспорт не идут (это результат, не гайд).
    public static func markdown(_ interview: Interview) -> String {
        var lines: [String] = []
        lines.append("# \(interview.name)")
        lines.append("")
        lines.append("- Шаблон: \(interview.template.name)")
        lines.append("- Создано: \(dateString(interview.createdAt))")
        if let modified = interview.modifiedAt {
            lines.append("- Изменено: \(dateString(modified))")
        }
        if interview.resolvedOrigin == .agent {
            lines.append("- Создано ИИ-агентом")
        }

        let keys = interview.template.placeholderKeys
        if !keys.isEmpty {
            lines.append("")
            lines.append("## Плейсхолдеры")
            lines.append("")
            for key in keys {
                let value = interview.placeholderValues[key] ?? ""
                lines.append("- `{\(key)}` — \(value.isEmpty ? "—" : value)")
            }
        }

        for section in interview.template.sections {
            lines.append("")
            lines.append("## \(section.title)")
            for field in section.fields {
                lines.append("")
                lines.append("### \(field.title)")
                lines.append("")
                lines.append(interview.resolvedQuestion(for: field))
                lines.append("")
                let answer = (interview.answers[field.id] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if answer.isEmpty {
                    lines.append("_Нет ответа._")
                } else {
                    for answerLine in answer.split(separator: "\n", omittingEmptySubsequences: false) {
                        lines.append("> \(answerLine)")
                    }
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// «23 июля 2026, 10:30» — единый формат дат в Markdown и PDF.
    public static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy, HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Шаблон интервью

/// Файл экспорта шаблона интервью: `{ version, type, template }`.
/// Для обмена шаблонами между людьми: отправил файл — собеседник
/// импортировал и пользуется.
public struct InterviewTemplateExportFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileType = "petable.interviewTemplate"

    public var version: Int
    public var type: String
    public var template: InterviewTemplate

    public init(template: InterviewTemplate) {
        self.version = Self.currentVersion
        self.type = Self.fileType
        self.template = template
    }

    public func encoded() throws -> Data {
        try ExportCoding.makeEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> InterviewTemplateExportFile {
        try ExportCoding.validateHeader(data, expectedType: fileType, supportedVersion: currentVersion)
        return try ExportCoding.makeDecoder().decode(InterviewTemplateExportFile.self, from: data)
    }
}

public extension InterviewTemplate {
    /// Копия шаблона со свежими id шаблона, секций и полей — для
    /// импорта: один файл можно импортировать несколько раз, и чужие
    /// id не пересекутся с местными. Плейсхолдеры (`fillsPlaceholder`
    /// и `{ключи}` в вопросах) — строковые, переживают как есть.
    func withRegeneratedIDs() -> InterviewTemplate {
        InterviewTemplate(
            name: name,
            sections: sections.map { section in
                Section(title: section.title, fields: section.fields.map { field in
                    Field(
                        title: field.title,
                        question: field.question,
                        hint: field.hint,
                        fillsPlaceholder: field.fillsPlaceholder
                    )
                })
            }
        )
    }
}

// MARK: - Граф работ

/// Файл экспорта графа работ: `{ version, type, name, graph }`.
public struct WorkGraphExportFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileType = "petable.workGraph"

    public var version: Int
    public var type: String
    public var name: String
    public var graph: WorkGraph

    public init(name: String, graph: WorkGraph) {
        self.version = Self.currentVersion
        self.type = Self.fileType
        self.name = name
        self.graph = graph
    }

    public func encoded() throws -> Data {
        try ExportCoding.makeEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> WorkGraphExportFile {
        try ExportCoding.validateHeader(data, expectedType: fileType, supportedVersion: currentVersion)
        return try ExportCoding.makeDecoder().decode(WorkGraphExportFile.self, from: data)
    }
}

public extension WorkGraph {
    /// Копия графа со свежими id уровней и узлов — для импорта: один
    /// файл можно импортировать несколько раз без коллизий id внутри
    /// проекта. Рёбра переписываются на новые id; рёбра, ссылающиеся
    /// на несуществующие узлы (битый файл), отбрасываются.
    func withRegeneratedIDs() -> WorkGraph {
        var idMap: [UUID: UUID] = [:]
        let newLevels = levels.map { level in
            GraphLevel(
                jobs: level.jobs.map { job in
                    let newID = UUID()
                    idMap[job.id] = newID
                    return JobNode(id: newID, verb: job.verb, role: job.role, details: job.details)
                },
                name: level.name,
                isCore: level.isCore
            )
        }
        let newEdges = edges.compactMap { edge -> JobEdge? in
            guard let from = idMap[edge.from], let to = idMap[edge.to] else { return nil }
            return JobEdge(from: from, to: to)
        }
        return WorkGraph(levels: newLevels, edges: newEdges)
    }
}
