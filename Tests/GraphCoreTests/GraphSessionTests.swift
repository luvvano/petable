import Foundation
import Testing
@testable import GraphCore

@Suite("Undo/Redo round-trip")
@MainActor
struct GraphSessionTests {
    private func intents(for root: Job) -> [GraphIntent] {
        let second = root.children[1]
        return [
            .addChild(of: root.id),
            .addSiblingAfter(second.id),
            .reorder(second.id, direction: .right),
            .delete(second.id),
            .setText(second.id, raw: "аудитор: хочу пересчитать"),
        ]
    }

    @Test("13. Для каждого интента: ⌘Z возвращает исходное, ⇧⌘Z повторяет")
    func undoRedoRoundTrip() throws {
        let original = Fixtures.closeMonth()
        for intent in intents(for: original) {
            let session = GraphSession(root: original)
            session.perform(intent)
            let mutated = session.root
            #expect(mutated != original, "интент \(intent) обязан менять дерево")

            #expect(session.undoManager.canUndo)
            session.undoManager.undo()
            #expect(session.root == original)

            #expect(session.undoManager.canRedo)
            session.undoManager.redo()
            #expect(session.root == mutated)
        }
    }

    @Test("No-op интенты не регистрируют undo")
    func noOpDoesNotRegisterUndo() {
        let root = Fixtures.closeMonth()
        let session = GraphSession(root: root)
        session.perform(.delete(root.id))
        session.perform(.reorder(root.children[0].id, direction: .left))
        #expect(!session.undoManager.canUndo)
        #expect(session.root == root)
    }

    @Test("Лимит undo = 100 снапшотов")
    func undoLimit() {
        let session = GraphSession(root: Fixtures.closeMonth())
        #expect(session.undoManager.levelsOfUndo == 100)
    }

    @Test("Цепочка правок: undo x3 → исходное дерево")
    func multiStepUndo() {
        let original = Fixtures.closeMonth()
        let session = GraphSession(root: original)
        let child = session.perform(.addChild(of: original.id))!
        session.perform(.setText(child, raw: "новый: хочу жить"))
        session.perform(.reorder(child, direction: .left))
        session.undoManager.undo()
        session.undoManager.undo()
        session.undoManager.undo()
        #expect(session.root == original)
    }
}
