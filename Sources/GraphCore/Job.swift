import Foundation

/// Узел графа работ: «role: хочу + глагол» с упорядоченными детьми.
/// Дерево, не произвольный граф. Порядок `children` = порядок
/// последовательности слева направо на канвасе.
public struct Job: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var verb: String
    public var role: String?
    public var children: [Job]

    public init(id: UUID = UUID(), verb: String, role: String? = nil, children: [Job] = []) {
        self.id = id
        self.verb = verb
        self.role = role
        self.children = children
    }

    /// Комбинированная строка для инлайн-редактора: `role: verb` или `verb`.
    public var displayText: String {
        if let role { return "\(role): \(verb)" }
        return verb
    }
}

// MARK: - Обход дерева

public extension Job {
    /// Поиск узла по id (pre-order).
    func find(_ id: UUID) -> Job? {
        if self.id == id { return self }
        for child in children {
            if let found = child.find(id) { return found }
        }
        return nil
    }

    /// id родителя узла `id`, nil для корня и отсутствующих.
    func parent(of id: UUID) -> Job? {
        if children.contains(where: { $0.id == id }) { return self }
        for child in children {
            if let found = child.parent(of: id) { return found }
        }
        return nil
    }

    /// Уровень узла: корень = 0. nil, если узла нет.
    func level(of id: UUID, current: Int = 0) -> Int? {
        if self.id == id { return current }
        for child in children {
            if let found = child.level(of: id, current: current + 1) { return found }
        }
        return nil
    }

    /// Все узлы pre-order.
    var allNodes: [Job] {
        [self] + children.flatMap(\.allNodes)
    }

    var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
}
