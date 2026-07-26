import Foundation

/// Конверт документа `.petable`: `{ version, stages }`.
/// `version` обязателен с первого дня — версионирование задним числом
/// превращается в гадание по форме JSON. Имя проекта = имя файла,
/// отдельного поля нет. Lossless round-trip неизвестных типов стадий
/// отложен до появления второго писателя файла (см. TODOS.md).
///
/// v1: граф — дерево `Job`. v2: граф — `WorkGraph` (уровни + рёбра),
/// одна стадия без имени. v3: у стадии появились `id` и `name` —
/// проект держит несколько именованных графов работ. v4: опциональная
/// секция `research` — шаблоны и интервью раздела «Исследования».
/// v5: `origin` у стадий и интервью — артефакты, созданные ИИ-агентом,
/// помечены. v6: опциональная секция `segmentation` — сегменты AJTBD.
/// v7: `isCore` у уровня графа — core-уровень (работы, которые продукт
/// выполняет целиком) есть в каждом графе; старые файлы получают его
/// при чтении (уровень с именем «core …» или верхний).
/// v1–v6 читаются и мигрируют на лету; запись всегда в v7.
public struct Envelope: Codable, Equatable, Sendable {
    public static let currentVersion = 7
    public static let jobGraphStageType = "jobGraph"
    public static let defaultGraphName = "Граф работ"

    public var version: Int
    public var stages: [Stage]
    /// Раздел «Исследования»; nil у файлов до v4 —
    /// документ подставит дефолтные шаблоны.
    public var research: Research?
    /// Раздел «Сегменты»; nil у файлов до v6 — пустой список.
    public var segmentation: Segmentation?

    public struct Stage: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var type: String
        public var name: String
        /// Момент последней правки графа стадии. Опциональное поле v3 —
        /// старые файлы без него читаются, приложение проставляет при правке.
        public var modifiedAt: Date?
        /// Кто создал стадию (v5); nil = человек.
        public var origin: ArtifactOrigin?
        public var graph: WorkGraph

        public init(
            id: UUID = UUID(),
            type: String = Envelope.jobGraphStageType,
            name: String = Envelope.defaultGraphName,
            modifiedAt: Date? = nil,
            origin: ArtifactOrigin? = nil,
            graph: WorkGraph
        ) {
            self.id = id
            self.type = type
            self.name = name
            self.modifiedAt = modifiedAt
            self.origin = origin
            var normalized = graph
            normalized.ensureCoreLevel()
            self.graph = normalized
        }

        /// Происхождение с учётом старых файлов без поля.
        public var resolvedOrigin: ArtifactOrigin { origin ?? .human }

        enum CodingKeys: String, CodingKey { case id, type, name, modifiedAt, origin, graph }

        /// v2-стадии не имели `id` и `name` — при чтении подставляются
        /// значения по умолчанию, сохранение перезапишет файл в v3.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            self.type = try container.decode(String.self, forKey: .type)
            self.name = try container.decodeIfPresent(String.self, forKey: .name)
                ?? Envelope.defaultGraphName
            self.modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt)
            self.origin = try container.decodeIfPresent(ArtifactOrigin.self, forKey: .origin)
            var graph = try container.decode(WorkGraph.self, forKey: .graph)
            graph.ensureCoreLevel() // файлы до v7 без core-уровня
            self.graph = graph
        }
    }

    public init(graph: WorkGraph) {
        self.init(stages: [Stage(graph: graph)])
    }

    public init(stages: [Stage], research: Research? = nil, segmentation: Segmentation? = nil) {
        self.version = Self.currentVersion
        self.stages = stages
        self.research = research
        self.segmentation = segmentation
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

    enum CodingKeys: String, CodingKey { case version, stages, research, segmentation }

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
            // Миграция: дерево → уровни + рёбра; сохранение перезапишет файл.
            let legacy = try container.decode([LegacyStage].self, forKey: .stages)
            self.stages = legacy.map { Stage(type: $0.type, graph: WorkGraph(tree: $0.graph)) }
        } else {
            // v2 и v3 различаются только полями стадии — их закрывает
            // decodeIfPresent в Stage.init(from:).
            self.stages = try container.decode([Stage].self, forKey: .stages)
        }
        self.research = try container.decodeIfPresent(Research.self, forKey: .research)
        self.segmentation = try container.decodeIfPresent(Segmentation.self, forKey: .segmentation)
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
