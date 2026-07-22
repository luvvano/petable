import Foundation

/// Интенты редактирования. Единственный способ менять дерево.
///
///   клавиша/клик → GraphIntent → GraphSession.perform(intent)
///                                    ├─ снапшот до правки → UndoManager
///                                    ├─ GraphEngine.apply (чистая функция)
///                                    └─ новый root → SwiftUI → layout → рендер
public enum GraphIntent: Equatable, Sendable {
    case addChild(of: UUID)
    case addSiblingAfter(UUID)
    case reorder(UUID, direction: ReorderDirection)
    /// На корне — no-op (корень удалить нельзя, пустого документа не бывает).
    case delete(UUID)
    /// Разбирает `raw` грамматикой role:. Пустая строка: на корне —
    /// плейсхолдер, на пустом «только что созданном» узле — удаление.
    case setText(UUID, raw: String)
}

public enum ReorderDirection: Equatable, Sendable {
    case left, right
}

/// Результат применения интента: новое дерево + узел для фокуса (если есть).
public struct GraphResult: Equatable, Sendable {
    public let root: Job
    public let focus: UUID?
}

public enum GraphEngine {
    public static let rootPlaceholder = "Без названия"

    /// Чистая функция: intent + дерево → новое дерево. nil = no-op
    /// (границы reorder, delete корня и т.п.) — вызывающий не должен
    /// регистрировать undo для nil.
    public static func apply(_ intent: GraphIntent, to root: Job) -> GraphResult? {
        switch intent {
        case let .addChild(of: id):
            let child = Job(verb: "")
            guard let newRoot = mutate(root, id: id, { $0.children.append(child) }) else { return nil }
            return GraphResult(root: newRoot, focus: child.id)

        case let .addSiblingAfter(id):
            guard root.id != id, let parent = root.parent(of: id) else { return nil }
            let sibling = Job(verb: "")
            let newRoot = mutate(root, id: parent.id) { node in
                if let index = node.children.firstIndex(where: { $0.id == id }) {
                    node.children.insert(sibling, at: index + 1)
                }
            }
            guard let newRoot else { return nil }
            return GraphResult(root: newRoot, focus: sibling.id)

        case let .reorder(id, direction):
            guard let parent = root.parent(of: id),
                  let index = parent.children.firstIndex(where: { $0.id == id })
            else { return nil }
            let target = direction == .left ? index - 1 : index + 1
            guard target >= 0, target < parent.children.count else { return nil }
            let newRoot = mutate(root, id: parent.id) { node in
                node.children.swapAt(index, target)
            }
            guard let newRoot else { return nil }
            return GraphResult(root: newRoot, focus: id)

        case let .delete(id):
            guard root.id != id, let parent = root.parent(of: id) else { return nil }
            let newRoot = mutate(root, id: parent.id) { node in
                node.children.removeAll { $0.id == id }
            }
            guard let newRoot else { return nil }
            return GraphResult(root: newRoot, focus: parent.id)

        case let .setText(id, raw):
            let (role, verb) = RoleParser.parse(raw)
            if verb.isEmpty {
                if root.id == id {
                    // Корень остаётся с плейсхолдером — пустого документа не бывает.
                    guard root.verb != rootPlaceholder || root.role != nil else { return nil }
                    let newRoot = mutate(root, id: id) { $0.verb = rootPlaceholder; $0.role = nil }
                    return newRoot.map { GraphResult(root: $0, focus: id) }
                }
                // Пустой commit только что созданного (пустого) узла — узел исчезает.
                if let node = root.find(id), node.verb.isEmpty, node.children.isEmpty {
                    return apply(.delete(id), to: root)
                }
                return nil // пустой commit существующего узла — revert, не мутация
            }
            guard let node = root.find(id), node.verb != verb || node.role != role else { return nil }
            let newRoot = mutate(root, id: id) { $0.verb = verb; $0.role = role }
            return newRoot.map { GraphResult(root: $0, focus: id) }
        }
    }

    /// Возвращает копию дерева с применённой к узлу `id` мутацией; nil, если узла нет.
    private static func mutate(_ root: Job, id: UUID, _ change: (inout Job) -> Void) -> Job? {
        var copy = root
        guard mutateInPlace(&copy, id: id, change) else { return nil }
        return copy
    }

    private static func mutateInPlace(_ node: inout Job, id: UUID, _ change: (inout Job) -> Void) -> Bool {
        if node.id == id {
            change(&node)
            return true
        }
        for index in node.children.indices {
            if mutateInPlace(&node.children[index], id: id, change) { return true }
        }
        return false
    }
}
