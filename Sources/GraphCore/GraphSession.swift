import Foundation

/// Единый канал мутаций с undo-снапшотами. Вьюхи зовут только `perform` —
/// UndoManager напрямую не трогает никто (environment-undoManager в SwiftUI
/// меняется при смене фокуса и бывает nil; регистрация из вьюх теряет
/// undo-события). Документ приложения владеет сессией.
@MainActor
public final class GraphSession {
    public private(set) var root: Job
    public let undoManager: UndoManager

    public var onChange: ((Job) -> Void)?

    public init(root: Job, undoManager: UndoManager = UndoManager()) {
        self.root = root
        self.undoManager = undoManager
        // Снапшот копирует всё дерево — безлимитный стек растёт весь сеанс.
        undoManager.levelsOfUndo = 100
        // Детеминированная группировка: одна правка = одна undo-группа,
        // одинаково в приложении и в тестах (без зависимости от runloop).
        undoManager.groupsByEvent = false
    }

    /// Применяет интент. Возвращает id узла для фокуса; nil = no-op (undo не регистрируется).
    @discardableResult
    public func perform(_ intent: GraphIntent) -> UUID? {
        guard let result = GraphEngine.apply(intent, to: root) else { return nil }
        assert(true) // undoManager собственный, nil невозможен by construction
        let snapshot = root
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.restore(snapshot) }
        }
        undoManager.endUndoGrouping()
        setRoot(result.root)
        return result.focus
    }

    private func restore(_ snapshot: Job) {
        let current = root
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.restore(current) }
        }
        undoManager.endUndoGrouping()
        setRoot(snapshot)
    }

    private func setRoot(_ newRoot: Job) {
        root = newRoot
        onChange?(newRoot)
    }
}
