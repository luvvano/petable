import Foundation
import Testing
@testable import GraphCore

@Suite("Интенты: дерево → дерево")
struct GraphEngineTests {
    @Test("8. addChild у листа и у узла с детьми (в конец)")
    func addChild() throws {
        let root = Fixtures.closeMonth()
        let leaf = root.children[0]
        let result = try #require(GraphEngine.apply(.addChild(of: leaf.id), to: root))
        #expect(result.root.find(leaf.id)?.children.count == 1)
        #expect(result.focus == result.root.find(leaf.id)?.children.first?.id)

        let withKids = root.children[1]
        let result2 = try #require(GraphEngine.apply(.addChild(of: withKids.id), to: root))
        let newKids = try #require(result2.root.find(withKids.id)?.children)
        #expect(newKids.count == 4)
        #expect(newKids.last?.id == result2.focus)
    }

    @Test("9. addSiblingAfter в середине и в конце; на корне — no-op")
    func addSibling() throws {
        let root = Fixtures.closeMonth()
        let second = root.children[1]
        let result = try #require(GraphEngine.apply(.addSiblingAfter(second.id), to: root))
        #expect(result.root.children.count == 6)
        #expect(result.root.children[2].id == result.focus)

        let last = root.children[4]
        let result2 = try #require(GraphEngine.apply(.addSiblingAfter(last.id), to: root))
        #expect(result2.root.children.last?.id == result2.focus)

        #expect(GraphEngine.apply(.addSiblingAfter(root.id), to: root) == nil)
    }

    @Test("10. reorder влево/вправо; границы — no-op")
    func reorder() throws {
        let root = Fixtures.closeMonth()
        let ids = root.children.map(\.id)

        let result = try #require(GraphEngine.apply(.reorder(ids[2], direction: .left), to: root))
        #expect(result.root.children.map(\.id) == [ids[0], ids[2], ids[1], ids[3], ids[4]])

        let result2 = try #require(GraphEngine.apply(.reorder(ids[2], direction: .right), to: root))
        #expect(result2.root.children.map(\.id) == [ids[0], ids[1], ids[3], ids[2], ids[4]])

        #expect(GraphEngine.apply(.reorder(ids[0], direction: .left), to: root) == nil)
        #expect(GraphEngine.apply(.reorder(ids[4], direction: .right), to: root) == nil)
    }

    @Test("11. delete: лист и поддерево без подтверждения; на корне — no-op")
    func delete() throws {
        let root = Fixtures.closeMonth()
        let leaf = root.children[0]
        let result = try #require(GraphEngine.apply(.delete(leaf.id), to: root))
        #expect(result.root.children.count == 4)
        #expect(result.root.find(leaf.id) == nil)
        #expect(result.focus == root.id)

        let subtree = root.children[1]
        let result2 = try #require(GraphEngine.apply(.delete(subtree.id), to: root))
        #expect(result2.root.count == root.count - 4)

        #expect(GraphEngine.apply(.delete(root.id), to: root) == nil)
    }

    @Test("12. setText: парсинг роли")
    func setTextParsesRole() throws {
        let root = Fixtures.closeMonth()
        let target = root.children[0]
        let result = try #require(GraphEngine.apply(.setText(target.id, raw: "аудитор: хочу проверить остатки"), to: root))
        let node = try #require(result.root.find(target.id))
        #expect(node.role == "аудитор")
        #expect(node.verb == "хочу проверить остатки")
    }

    @Test("12 + 4. setText пустой строкой: новый узел исчезает, корень — плейсхолдер")
    func setTextEmpty() throws {
        let root = Fixtures.closeMonth()

        // Свежесозданный пустой узел удаляется.
        let added = try #require(GraphEngine.apply(.addChild(of: root.id), to: root))
        let newId = try #require(added.focus)
        let removed = try #require(GraphEngine.apply(.setText(newId, raw: "   "), to: added.root))
        #expect(removed.root.find(newId) == nil)

        // Существующий узел с текстом: пустой commit — no-op (revert на стороне UI).
        let existing = root.children[0]
        #expect(GraphEngine.apply(.setText(existing.id, raw: ""), to: root) == nil)

        // Корень: остаётся с плейсхолдером.
        let result = try #require(GraphEngine.apply(.setText(root.id, raw: ""), to: root))
        #expect(result.root.verb == GraphEngine.rootPlaceholder)
        #expect(result.root.children.count == 5)
    }

    @Test("setText без изменений — no-op, undo не засоряется")
    func setTextNoChange() {
        let root = Fixtures.closeMonth()
        let node = root.children[2]
        #expect(GraphEngine.apply(.setText(node.id, raw: node.displayText), to: root) == nil)
    }
}
