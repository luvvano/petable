import Foundation
import Testing
@testable import GraphCore

@Suite("Группировка графов")
struct GraphGroupingTests {
    /// Стадия-граф с понятным именем: содержимое для группировки неважно.
    private func stage(_ name: String, parent: UUID? = nil, origin: ArtifactOrigin? = nil) -> Envelope.Stage {
        Envelope.Stage(
            name: name,
            origin: origin,
            parentID: parent,
            graph: WorkGraph(levels: [GraphLevel(jobs: [JobNode(verb: name)], isCore: true)])
        )
    }

    @Test("1. Дерево: потомки идут сразу за родителем, с глубиной")
    func outlineNestsChildren() {
        let root = stage("Корень")
        let child = stage("Ребёнок", parent: root.id)
        let grandchild = stage("Внук", parent: child.id)
        let sibling = stage("Сосед")
        // Порядок в файле — вперемешку: дерево собирается по parentID.
        let stages = [root, sibling, grandchild, child]

        let rows = stages.graphOutline()
        #expect(rows.map(\.stage.name) == ["Корень", "Ребёнок", "Внук", "Сосед"])
        #expect(rows.map(\.depth) == [0, 1, 2, 0])
        #expect(rows.map(\.hasChildren) == [true, true, false, false])
    }

    @Test("2. Свёрнутая группа прячет всё поддерево, сам родитель остаётся")
    func collapsedGroupHidesSubtree() {
        let root = stage("Корень")
        let child = stage("Ребёнок", parent: root.id)
        let grandchild = stage("Внук", parent: child.id)
        let stages = [root, child, grandchild]

        let rows = stages.graphOutline(collapsed: [root.id])
        #expect(rows.map(\.stage.name) == ["Корень"])
        #expect(rows[0].hasChildren) // треугольник остаётся — есть что раскрыть
    }

    @Test("3. Фильтр не рвёт группу: родитель виден ради подходящего потомка")
    func filterKeepsParentOfMatchingChild() {
        let root = stage("Человеческий корень")
        let child = stage("Граф агента", parent: root.id, origin: .agent)
        let lonely = stage("Человеческий сосед")
        let stages = [root, child, lonely]

        let rows = stages.graphOutline { $0.resolvedOrigin == .agent }
        #expect(rows.map(\.stage.name) == ["Человеческий корень", "Граф агента"])
        #expect(rows.map(\.depth) == [0, 1])
    }

    @Test("4. Потомки на любую глубину — для удаления группы целиком")
    func descendantsGoDeep() {
        let root = stage("Корень")
        let a = stage("A", parent: root.id)
        let b = stage("B", parent: root.id)
        let deep = stage("A.1", parent: a.id)
        let outside = stage("Снаружи")
        let stages = [root, a, b, deep, outside]

        #expect(Set(stages.graphDescendants(of: root.id)) == Set([a.id, b.id, deep.id]))
        #expect(stages.graphDescendants(of: deep.id).isEmpty)
        #expect(stages.graphChildren(of: nil).map(\.name) == ["Корень", "Снаружи"])
    }

    @Test("5. Циклы запрещены: в себя и в собственного потомка вложить нельзя")
    func nestingRejectsCycles() {
        let root = stage("Корень")
        let child = stage("Ребёнок", parent: root.id)
        let grandchild = stage("Внук", parent: child.id)
        let other = stage("Другой")
        let stages = [root, child, grandchild, other]

        #expect(!stages.canNestGraph(root.id, under: root.id))
        #expect(!stages.canNestGraph(root.id, under: child.id))
        #expect(!stages.canNestGraph(root.id, under: grandchild.id))
        #expect(stages.canNestGraph(root.id, under: other.id))
        #expect(stages.canNestGraph(root.id, under: nil)) // на верхний уровень — всегда
        #expect(!stages.canNestGraph(root.id, under: UUID())) // несуществующий родитель
    }

    @Test("6. Битые ссылки на родителя чинятся: граф не пропадает из дерева")
    func normalizationRescuesOrphans() {
        var stages = [stage("Сирота", parent: UUID()), stage("Обычный")]
        stages.normalizeGraphParents()
        #expect(stages[0].parentID == nil)
        #expect(stages.graphOutline().map(\.stage.name) == ["Сирота", "Обычный"])
    }

    @Test("7. Цикл в файле разрывается: петля становится обычной группой")
    func normalizationBreaksCycles() {
        var first = stage("Первый")
        var second = stage("Второй")
        first.parentID = second.id
        second.parentID = first.id
        var stages = [first, second]

        stages.normalizeGraphParents()
        // Рвётся одна ссылка — ни один граф не пропадает из дерева.
        #expect(stages[0].parentID == nil)
        let rows = stages.graphOutline()
        #expect(rows.map(\.stage.name) == ["Первый", "Второй"])
        #expect(rows.map(\.depth) == [0, 1])
    }

    @Test("8. Вложенность переживает round-trip файла (v10)")
    func nestingSurvivesRoundTrip() throws {
        let root = stage("Корень")
        let child = stage("Ребёнок", parent: root.id)
        let envelope = Envelope(stages: [root, child])

        let decoded = try Envelope.decode(try envelope.encoded())
        #expect(decoded.version == Envelope.currentVersion)
        #expect(decoded.stages.map(\.parentID) == [nil, root.id])
        #expect(decoded.stages.graphOutline().map(\.depth) == [0, 1])
    }

    @Test("9. Файл до v10 читается плоским списком")
    func preV10FileIsFlat() throws {
        let graphJSON = String(data: try JSONEncoder().encode(Fixtures.closeMonth()), encoding: .utf8)!
        let json = #"""
        {"version": 9, "stages": [
          {"type": "jobGraph", "name": "Первый", "graph": \#(graphJSON)},
          {"type": "jobGraph", "name": "Второй", "graph": \#(graphJSON)}
        ]}
        """#
        let decoded = try Envelope.decode(json.data(using: .utf8)!)
        #expect(decoded.stages.allSatisfy { $0.parentID == nil })
        #expect(decoded.stages.graphOutline().map(\.depth) == [0, 0])
    }
}
