import Foundation

/// Конверт документа `.petable`: `{ version, stages }`.
/// `version` обязателен с первого дня — версионирование задним числом
/// превращается в гадание по форме JSON. Имя проекта = имя файла,
/// отдельного поля нет. Lossless round-trip неизвестных типов стадий
/// отложен до появления второго писателя файла (см. TODOS.md).
public struct Envelope: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let jobGraphStageType = "jobGraph"

    public var version: Int
    public var stages: [Stage]

    public struct Stage: Codable, Equatable, Sendable {
        public var type: String
        public var graph: Job

        public init(type: String = Envelope.jobGraphStageType, graph: Job) {
            self.type = type
            self.graph = graph
        }
    }

    public init(graph: Job) {
        self.version = Self.currentVersion
        self.stages = [Stage(graph: graph)]
    }

    /// Первая стадия jobGraph — единственная, которую рендерит v1.
    public var jobGraph: Job? {
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version <= Self.currentVersion else {
            throw EnvelopeError.unsupportedVersion(found: version, supported: Self.currentVersion)
        }
        self.version = version
        self.stages = try container.decode([Stage].self, forKey: .stages)
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
