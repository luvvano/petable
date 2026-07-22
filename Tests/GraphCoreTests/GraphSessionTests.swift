import Foundation
import Testing
@testable import GraphCore

@Suite("Undo/Redo round-trip")
@MainActor
struct GraphSessionTests {
    private func intents(for graph: WorkGraph) -> [GraphIntent] {
        let source = graph.levels[1].jobs[1]
        return [
            .insertLevel(at: 0),
            .addJob(level: graph.levels[1].id),
            .addConnectedRight(of: source.id),
            .addConnectedBelow(of: source.id),
            .reorder(source.id, direction: .right),
            .delete(source.id),
            .setText(source.id, raw: "аудитор: хочу пересчитать"),
        ]
    }

    @Test("Для каждого интента: ⌘Z возвращает исходное, ⇧⌘Z повторяет")
    func undoRedoRoundTrip() throws {
        let original = Fixtures.closeMonth()
        for intent in intents(for: original) {
            let session = GraphSession(graph: original)
            session.perform(intent)
            let mutated = session.graph
            #expect(mutated != original, "интент \(intent) обязан менять граф")

            #expect(session.undoManager.canUndo)
            session.undoManager.undo()
            #expect(session.graph == original)

            #expect(session.undoManager.canRedo)
            session.undoManager.redo()
            #expect(session.graph == mutated)
        }
    }

    @Test("No-op интенты не регистрируют undo")
    func noOpDoesNotRegisterUndo() {
        let graph = Fixtures.closeMonth()
        let session = GraphSession(graph: graph)
        session.perform(.reorder(graph.levels[1].jobs[0].id, direction: .left))
        session.perform(.deleteLevel(graph.levels[1].id))
        session.perform(.insertLevel(at: 99))
        #expect(!session.undoManager.canUndo)
        #expect(session.graph == graph)
    }

    @Test("Лимит undo = 100 снапшотов")
    func undoLimit() {
        let session = GraphSession(graph: Fixtures.closeMonth())
        #expect(session.undoManager.levelsOfUndo == 100)
    }

    @Test("Цепочка правок: undo x3 → исходный граф")
    func multiStepUndo() {
        let original = Fixtures.closeMonth()
        let session = GraphSession(graph: original)
        let source = original.levels[1].jobs[0]
        let newId = session.perform(.addConnectedBelow(of: source.id))!
        session.perform(.setText(newId, raw: "новый: хочу жить"))
        session.perform(.reorder(newId, direction: .left))
        session.undoManager.undo()
        session.undoManager.undo()
        session.undoManager.undo()
        #expect(session.graph == original)
    }
}
