import Foundation

/// Конверт документа `.petable`: `{ version, stages }`.
/// `version` обязателен с первого дня — версионирование задним числом
/// превращается в гадание по форме JSON. Имя проекта = имя файла,
/// отдельного поля нет. Lossless round-trip неизвестных типов стадий
/// отложен до появления второго писателя файла (см. TODOS.md).
///
/// v1: граф — дерево `Job`. v2: граф — `WorkGraph` (уровни + рёбра),
/// одна стадия без имени. v3: у стадии появились `id` и `name` —
/// проект держит несколько именованных графов работ.
/// v1/v2 читаются и мигрируют на лету; запись всегда в v3.
public struct Envelope: Codable, Equatable, Sendable {
    public static let currentVersion = 3
    public static let jobGraphStageType = "jobGraph"
    public static let defaultGraphName = "Граф работ"

    public var version: Int
    public var stages: [Stage]

    public struct Stage: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var type: String
        public var name: String
        public var graph: WorkGraph

        public init(
            id: UUID = UUID(),
            type: String = Envelope.jobGraphStageType,
            name: String = Envelope.defaultGraphName,
            graph: WorkGraph
        ) {
            self.id = id
            self.type = type
            self.name = name
            self.graph = graph
        }

        enum CodingKeys: String, CodingKey { case id, type, name, graph }

        /// v2-стадии не имели `id` и `name` — при чтении подставляются
        /// значения по умолчанию, сохранение перезапишет файл в v3.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            self.type = try container.decode(String.self, forKey: .type)
            self.name = try container.decodeIfPresent(String.self, forKey: .name)
                ?? Envelope.defaultGraphName
            self.graph = try container.decode(WorkGraph.self, forKey: .graph)
        }
    }

    public init(graph: WorkGraph) {
        self.init(stages: [Stage(graph: graph)])
    }

    public init(stages: [Stage]) {
        self.version = Self.currentVersion
        self.stages = stages
    }

    /// Первая стадия jobGraph — граф по умолчанию (для миграций и тестов).
    public var jobGraph: WorkGraph? {
        stages.first(where: { $0.type == Self.jobGraphStageType })?.graph
    }

    /// Все стадии-графы работ в порядке файла.
    public var jobGraphStages: [Stage] {
        stages.filter { $0.type == Self.jobGraphStageType }
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
            // Миграция: дерево → уровни + рёбра; сохранение перезапишет в v3.
            let legacy = try container.decode([LegacyStage].self, forKey: .stages)
            self.stages = legacy.map { Stage(type: $0.type, graph: WorkGraph(tree: $0.graph)) }
        } else {
            // v2 и v3 различаются только полями стадии — их закрывает
            // decodeIfPresent в Stage.init(from:).
            self.stages = try container.decode([Stage].self, forKey: .stages)
        }
        self.version = Self.currentVersion
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
