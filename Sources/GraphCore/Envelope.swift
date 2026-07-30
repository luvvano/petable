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
/// v8: `zones` у уровня и `zoneID` у работы — отдельные области внутри
/// полосы уровня (малые работы рядом с кóровыми: уровень тот же, продукт
/// их не выполняет). Старые файлы читаются без областей.
/// v9: `isCollapsed` у работы — свёрнутая цепочка работ уровня (работы
/// справа скрыты с канваса). Старые файлы читаются развёрнутыми.
/// v10: `parentID` у стадии — графы группируются в дерево (граф лежит
/// «под» другим графом). Старые файлы читаются плоским списком.
/// v11: механики ценности — `stickers` у стадии (аннотации механик без
/// структурной формы) и `mechanicOrigin` (какая механика породила этот
/// граф-потомок при форке). Старые файлы читаются без того и другого.
/// v12: стикер стал записью-комментарием — `messages` (тред обсуждения)
/// и `anchorLabels` (тексты якорных работ на момент применения) у
/// MechanicSticker. Старые файлы читаются с пустыми.
/// v13: `killed` у работы — kill-a-job больше не удаляет узел, а
/// перечёркивает его на графе. Старые файлы читаются с живыми работами.
/// v14: опциональная секция `organization` — ИИ-сотрудники и флоу
/// (определение организации; runtime-история живёт у демона, П1′).
/// Старые файлы читаются без организации.
/// v1–v13 читаются и мигрируют на лету; запись всегда в v14.
public struct Envelope: Codable, Equatable, Sendable {
    public static let currentVersion = 14
    public static let jobGraphStageType = "jobGraph"
    public static let defaultGraphName = "Граф работ"

    public var version: Int
    public var stages: [Stage]
    /// Раздел «Исследования»; nil у файлов до v4 —
    /// документ подставит дефолтные шаблоны.
    public var research: Research?
    /// Раздел «Сегменты»; nil у файлов до v6 — пустой список.
    public var segmentation: Segmentation?
    /// Раздел «Организация»; nil у файлов до v14 — организации нет.
    public var organization: Organization?

    public struct Stage: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var type: String
        public var name: String
        /// Момент последней правки графа стадии. Опциональное поле v3 —
        /// старые файлы без него читаются, приложение проставляет при правке.
        public var modifiedAt: Date?
        /// Кто создал стадию (v5); nil = человек.
        public var origin: ArtifactOrigin?
        /// Граф, под которым лежит этот (v10); nil = верхний уровень.
        /// Группировка графов — только структура списка, содержимое
        /// графов друг от друга не зависит.
        public var parentID: UUID?
        /// Стикеры механик (v11): аннотации механик без структурной формы,
        /// повешенные на якорь графа. Старые файлы читаются с пустым списком.
        public var stickers: [MechanicSticker]
        /// Какая механика породила этот граф-потомок при форке (v11);
        /// nil — граф создан обычным способом.
        public var mechanicOrigin: MechanicOrigin?
        public var graph: WorkGraph

        public init(
            id: UUID = UUID(),
            type: String = Envelope.jobGraphStageType,
            name: String = Envelope.defaultGraphName,
            modifiedAt: Date? = nil,
            origin: ArtifactOrigin? = nil,
            parentID: UUID? = nil,
            stickers: [MechanicSticker] = [],
            mechanicOrigin: MechanicOrigin? = nil,
            graph: WorkGraph
        ) {
            self.id = id
            self.type = type
            self.name = name
            self.modifiedAt = modifiedAt
            self.origin = origin
            self.parentID = parentID
            self.stickers = stickers
            self.mechanicOrigin = mechanicOrigin
            var normalized = graph
            normalized.ensureCoreLevel()
            normalized.normalizeZones()
            normalized.normalizeEdges()
            self.graph = normalized
        }

        /// Происхождение с учётом старых файлов без поля.
        public var resolvedOrigin: ArtifactOrigin { origin ?? .human }

        enum CodingKeys: String, CodingKey {
            case id, type, name, modifiedAt, origin, parentID, stickers, mechanicOrigin, graph
        }

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
            self.parentID = try container.decodeIfPresent(UUID.self, forKey: .parentID)
            self.stickers = try container.decodeIfPresent([MechanicSticker].self, forKey: .stickers) ?? []
            self.mechanicOrigin = try container.decodeIfPresent(MechanicOrigin.self, forKey: .mechanicOrigin)
            var graph = try container.decode(WorkGraph.self, forKey: .graph)
            graph.ensureCoreLevel() // файлы до v7 без core-уровня
            graph.normalizeZones() // порядок работ по областям (v8)
            graph.normalizeEdges() // связи снизу вверх из старых файлов
            self.graph = graph
        }

        /// Пустой список стикеров в JSON не пишется — как пустая карточка узла.
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(type, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
            try container.encodeIfPresent(origin, forKey: .origin)
            try container.encodeIfPresent(parentID, forKey: .parentID)
            if !stickers.isEmpty { try container.encode(stickers, forKey: .stickers) }
            try container.encodeIfPresent(mechanicOrigin, forKey: .mechanicOrigin)
            try container.encode(graph, forKey: .graph)
        }
    }

    public init(graph: WorkGraph) {
        self.init(stages: [Stage(graph: graph)])
    }

    public init(
        stages: [Stage],
        research: Research? = nil,
        segmentation: Segmentation? = nil,
        organization: Organization? = nil
    ) {
        self.version = Self.currentVersion
        var stages = stages
        stages.normalizeGraphParents()
        self.stages = stages
        self.research = research
        self.segmentation = segmentation
        self.organization = organization
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

    enum CodingKeys: String, CodingKey { case version, stages, research, segmentation, organization }

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
        // Битые ссылки на родителя (правленый руками файл) не должны
        // прятать графы из сайдбара — уезжают на верхний уровень.
        self.stages.normalizeGraphParents()
        self.research = try container.decodeIfPresent(Research.self, forKey: .research)
        self.segmentation = try container.decodeIfPresent(Segmentation.self, forKey: .segmentation)
        self.organization = try container.decodeIfPresent(Organization.self, forKey: .organization)
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
