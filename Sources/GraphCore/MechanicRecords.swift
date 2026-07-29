import Foundation

/// Стикер механики (v11): аннотация механики без структурной формы,
/// повешенная на якорь графа. У 14 из 25 механик канона нет выражения
/// ни в топологии, ни в карточке — стикер держит их живыми: запись
/// в документе плюс бейдж на якоре, без превью.
public struct MechanicSticker: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Слаг механики из словаря MechanicCatalog.
    public var slug: String
    /// Якорь — плоский Codable (см. MechanicAnchor): битый якорь из
    /// правленного руками файла деградирует в .unanchored, не валит документ.
    public var anchor: MechanicAnchor
    /// Заметка «почему я это повесил».
    public var note: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        slug: String,
        anchor: MechanicAnchor,
        note: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.slug = slug
        self.anchor = anchor
        self.note = note
        self.createdAt = createdAt
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
