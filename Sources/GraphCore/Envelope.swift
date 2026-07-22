import Foundation

/// Конверт документа `.petable`: `{ version, stages }`.
/// `version` обязателен с первого дня — версионирование задним числом
/// превращается в гадание по форме JSON. Имя проекта = имя файла,
/// отдельного поля нет. Lossless round-trip неизвестных типов стадий
/// отложен до появления второго писателя файла (см. TODOS.md).
///
/// v1: граф — дерево `Job`. v2: граф — `WorkGraph` (уровни + рёбра).
/// v1 читается и мигрирует на лету; запись всегда в v2.
public struct Envelope: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public static let jobGraphStageType = "jobGraph"

    public var version: Int
    public var stages: [Stage]

    public struct Stage: Codable, Equatable, Sendable {
        public var type: String
        public var graph: WorkGraph

        public init(type: String = Envelope.jobGraphStageType, graph: WorkGraph) {
            self.type = type
            self.graph = graph
        }
    }

    public init(graph: WorkGraph) {
        self.version = Self.currentVersion
        self.stages = [Stage(graph: graph)]
    }

    /// Первая стадия jobGraph — единственная, которую рендерит приложение.
    public var jobGraph: WorkGraph? {
        stages.first(where: { $0.type == Self.jobGraphStageType })?.graph
    }

    public enum EnvelopeError: Error, Equatable, LocalizedError {
        case unsupportedVersion(found: Int, supported: Int)

        public var errorDescription: String? {
            switch self {
            case let .unsupportedVersion(found, supported):
                return "Файл создан более новой версией petable (формат v\(found), поддерживается v\(supported)). Обновите приложение."
            }
        }
    }

    enum CodingKeys: String, CodingKey { case version, stages }

    /// Стадия v1: граф — дерево Job. Нужна только для миграции при чтении.
    private struct LegacyStage: Codable {
        var type: String
        var graph: Job
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version <= Self.currentVersion else {
            throw EnvelopeError.unsupportedVersion(found: version, supported: Self.currentVersion)
        }
        if version == 1 {
            // Миграция: дерево → уровни + рёбра; сохранение перезапишет в v2.
            let legacy = try container.decode([LegacyStage].self, forKey: .stages)
            self.stages = legacy.map { Stage(type: $0.type, graph: WorkGraph(tree: $0.graph)) }
            self.version = Self.currentVersion
        } else {
            self.stages = try container.decode([Stage].self, forKey: .stages)
            self.version = version
        }
    }

    public static func decode(_ data: Data) throws -> Envelope {
        try JSONDecoder().decode(Envelope.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
