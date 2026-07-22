import Foundation

/// Единый канал мутаций с undo-снапшотами. Вьюхи зовут только `perform` —
/// UndoManager напрямую не трогает никто (environment-undoManager в SwiftUI
/// меняется при смене фокуса и бывает nil; регистрация из вьюх теряет
/// undo-события). Документ приложения владеет сессией.
@MainActor
public final class GraphSession {
    public private(set) var graph: WorkGraph
    public let undoManager: UndoManager

    public var onChange: ((WorkGraph) -> Void)?

    public init(graph: WorkGraph, undoManager: UndoManager = UndoManager()) {
        self.graph = graph
        self.undoManager = undoManager
        // Снапшот копирует весь граф — безлимитный стек растёт весь сеанс.
        undoManager.levelsOfUndo = 100
        // Детеминированная группировка: одна правка = одна undo-группа,
        // одинаково в приложении и в тестах (без зависимости от runloop).
        undoManager.groupsByEvent = false
    }

    /// Применяет интент. Возвращает id узла для фокуса; nil = no-op (undo не регистрируется).
    @discardableResult
    public func perform(_ intent: GraphIntent) -> UUID? {
        guard let result = GraphEngine.apply(intent, to: graph) else { return nil }
        let snapshot = graph
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.restore(snapshot) }
        }
        undoManager.endUndoGrouping()
        setGraph(result.graph)
        return result.focus
    }

    private func restore(_ snapshot: WorkGraph) {
        let current = graph
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { session in
            MainActor.assumeIsolated { session.restore(current) }
        }
        undoManager.endUndoGrouping()
        setGraph(snapshot)
    }

    private func setGraph(_ newGraph: WorkGraph) {
        graph = newGraph
        onChange?(newGraph)
    }
}
