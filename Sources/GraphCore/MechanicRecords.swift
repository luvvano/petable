import Foundation

/// Реплика треда стикера (v12): комментарий-обсуждение поверх записи
/// механики — как ответы к комментарию в Confluence.
public struct StickerMessage: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// Стикер механики (v11): запись о применённой механике, повешенная на
/// якорь графа. С v12 стикер оставляет ЛЮБОЕ применение механики (не
/// только классы без структурной формы): применение — событие документа,
/// и его след не должен исчезать после следующего действия. Запись в
/// документе плюс бейдж-конвертик на якоре.
public struct MechanicSticker: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Слаг механики из словаря MechanicCatalog.
    public var slug: String
    /// Якорь — плоский Codable (см. MechanicAnchor): битый якорь из
    /// правленного руками файла деградирует в .unanchored, не валит документ.
    public var anchor: MechanicAnchor
    /// Заметка «почему я это повесил».
    public var note: String
    /// Тред обсуждения (v12); старые файлы читаются с пустым.
    public var messages: [StickerMessage]
    /// Тексты якорных работ на момент применения (v12): kill-a-job
    /// удаляет свой якорь, а «к чему это было» должно остаться читаемым
    /// в списке комментариев. Старые файлы читаются с пустым.
    public var anchorLabels: [String]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        slug: String,
        anchor: MechanicAnchor,
        note: String = "",
        messages: [StickerMessage] = [],
        anchorLabels: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.slug = slug
        self.anchor = anchor
        self.note = note
        self.messages = messages
        self.anchorLabels = anchorLabels
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, slug, anchor, note, messages, anchorLabels, createdAt
    }

    /// Файлы v11 не имели messages и anchorLabels — читаются пустыми.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.slug = try container.decode(String.self, forKey: .slug)
        self.anchor = try container.decode(MechanicAnchor.self, forKey: .anchor)
        self.note = try container.decodeIfPresent(String.self, forKey: .note) ?? ""
        self.messages = try container.decodeIfPresent([StickerMessage].self, forKey: .messages) ?? []
        self.anchorLabels = try container.decodeIfPresent([String].self, forKey: .anchorLabels) ?? []
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    /// Пустые тред и подписи в JSON не пишутся — как пустой список
    /// стикеров у стадии.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(slug, forKey: .slug)
        try container.encode(anchor, forKey: .anchor)
        try container.encode(note, forKey: .note)
        if !messages.isEmpty { try container.encode(messages, forKey: .messages) }
        if !anchorLabels.isEmpty { try container.encode(anchorLabels, forKey: .anchorLabels) }
        try container.encode(createdAt, forKey: .createdAt)
    }

    /// Собирает запись, снимая тексты якорных работ из графа ДО применения
    /// механики — после kill-a-job их уже не будет (паттерн MechanicOrigin).
    public static func capture(
        slug: String,
        anchor: MechanicAnchor,
        note: String = "",
        in graph: WorkGraph,
        createdAt: Date = Date()
    ) -> MechanicSticker {
        MechanicSticker(
            slug: slug,
            anchor: anchor,
            note: note,
            anchorLabels: MechanicOrigin.capture(slug: slug, anchor: anchor, in: graph).anchorLabels,
            createdAt: createdAt
        )
    }
}

/// Происхождение графа-потомка (v11): какая механика его породила при
/// форке (⌥Enter). Держит связь «механика ↔ джоба» надёжнее имени графа —
/// имя переименуют, происхождение останется.
public struct MechanicOrigin: Codable, Equatable, Sendable {
    public var slug: String
    public var anchor: MechanicAnchor
    /// Тексты якорных работ на момент применения. Нужны, потому что
    /// kill-a-job удаляет свой якорь — ссылка дангл по построению,
    /// а «что именно убили» должно остаться читаемым.
    public var anchorLabels: [String]
    public var appliedAt: Date

    public init(
        slug: String,
        anchor: MechanicAnchor,
        anchorLabels: [String] = [],
        appliedAt: Date = Date()
    ) {
        self.slug = slug
        self.anchor = anchor
        self.anchorLabels = anchorLabels
        self.appliedAt = appliedAt
    }

    /// Собирает происхождение, снимая тексты якорных работ из графа ДО
    /// применения — после kill-a-job их уже не будет.
    public static func capture(
        slug: String,
        anchor: MechanicAnchor,
        in graph: WorkGraph,
        appliedAt: Date = Date()
    ) -> MechanicOrigin {
        let labels: [String]
        switch anchor {
        case let .node(id):
            labels = [graph.job(id)?.displayText].compactMap { $0 }
        case let .chainEdge(from, to):
            labels = [graph.job(from)?.displayText, graph.job(to)?.displayText].compactMap { $0 }
        case let .zone(id):
            labels = [graph.levels.flatMap(\.zones).first { $0.id == id }?.resolvedName]
                .compactMap { $0 }
        case .unanchored:
            labels = []
        }
        return MechanicOrigin(slug: slug, anchor: anchor, anchorLabels: labels, appliedAt: appliedAt)
    }
}
