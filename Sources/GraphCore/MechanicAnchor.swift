import Foundation

/// Якорь механики: к чему на графе она привязана.
///
/// В памяти — enum, в файле — плоская структура `{kind, ids}` (см. Codable
/// ниже). Enum с ассоциированными значениями Swift кодирует объектом с
/// ключом-именем кейса, и незнакомый ключ БРОСАЕТ при декодировании; якорь
/// лежит внутри Stage, так что вместо «поле не прочиталось» получился бы
/// «документ не открылся». Все персистентные enum'ы GraphCore — String-raw
/// ровно по этой причине.
public enum MechanicAnchor: Equatable, Sendable {
    case node(UUID)
    /// Связь внутри уровня. Направленная — копирует форму JobEdge:
    /// normalizeEdges() внутриуровневые связи не трогает, поэтому
    /// нормализовать порядок пары не нужно.
    case chainEdge(from: UUID, to: UUID)
    case zone(UUID)
    /// Намеренно НЕ `.none` — рядом с Optional<MechanicAnchor> кейс
    /// `.none` читается как nil и стреляет в ногу.
    case unanchored
}

extension MechanicAnchor: Codable {
    /// Плоская форма в JSON: `{"kind": "node", "ids": ["…"]}`.
    ///
    /// Деградация вместо падения: незнакомый `kind` (файл из будущей
    /// сборки) и неверное число `ids` (файл правили руками) дают
    /// `.unanchored` — документ открывается, теряется только привязка.
    /// Тот же принцип, что у normalizeGraphParents(): битая ссылка
    /// чинится при чтении, а не валит документ.
    private enum CodingKeys: String, CodingKey { case kind, ids }

    private var kindName: String {
        switch self {
        case .node: return "node"
        case .chainEdge: return "chainEdge"
        case .zone: return "zone"
        case .unanchored: return "unanchored"
        }
    }

    private var ids: [UUID] {
        switch self {
        case let .node(id): return [id]
        case let .chainEdge(from, to): return [from, to]
        case let .zone(id): return [id]
        case .unanchored: return []
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kindName, forKey: .kind)
        try container.encode(ids, forKey: .ids)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        let ids = try container.decodeIfPresent([UUID].self, forKey: .ids) ?? []
        switch (kind, ids.count) {
        case ("node", 1): self = .node(ids[0])
        case ("chainEdge", 2): self = .chainEdge(from: ids[0], to: ids[1])
        case ("zone", 1): self = .zone(ids[0])
        default: self = .unanchored
        }
    }
}
