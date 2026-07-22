import Foundation
import CoreGraphics
import Testing
@testable import GraphCore

@Suite("Автораскладка tidy tree")
struct LayoutTests {
    /// Свойства из тест-плана №7 — проверяются на любом дереве.
    private func assertProperties(_ root: Job, _ positions: [UUID: CGPoint]) throws {
        #expect(positions.count == root.count)

        for node in root.allNodes {
            let level = try #require(root.level(of: node.id))
            let point = try #require(positions[node.id])
            // Уровень строго определяет Y.
            #expect(point.y == CGFloat(level) * LayoutMetrics.rowHeight)

            // Порядок X сиблингов = порядок массива children, дистанция ≥ колонки.
            let childXs = node.children.compactMap { positions[$0.id]?.x }
            for pair in zip(childXs, childXs.dropFirst()) {
                #expect(pair.1 - pair.0 >= LayoutMetrics.columnWidth - 0.001)
            }

            // Родитель центрирован над своим поддеревом (Бухгейм).
            if let first = childXs.first, let last = childXs.last {
                #expect(abs(point.x - (first + last) / 2) < 0.001)
            }
        }

        // Ни одна пара узлов одного уровня не ближе ширины колонки.
        var byLevel: [Int: [CGFloat]] = [:]
        for node in root.allNodes {
            byLevel[root.level(of: node.id)!, default: []].append(positions[node.id]!.x)
        }
        for xs in byLevel.values {
            let sorted = xs.sorted()
            for pair in zip(sorted, sorted.dropFirst()) {
                #expect(pair.1 - pair.0 >= LayoutMetrics.columnWidth - 0.001)
            }
        }
    }

    @Test("5. Эталон: простое дерево — дети в колонках, родитель по центру")
    func referenceSimple() throws {
        let root = Job(verb: "r", children: [Job(verb: "a"), Job(verb: "b"), Job(verb: "c")])
        let positions = GraphLayout.layout(root)
        let xs = root.children.map { positions[$0.id]!.x }
        #expect(xs == [0, 130, 260])
        #expect(positions[root.id]!.x == 130)
        #expect(positions[root.id]!.y == 0)
        #expect(positions[root.children[0].id]!.y == LayoutMetrics.rowHeight)
    }

    @Test("5. Пример «Закрыть месяц»: 3 уровня, 9 узлов, все свойства")
    func closeMonthExample() throws {
        let root = Fixtures.closeMonth()
        let positions = GraphLayout.layout(root)
        try assertProperties(root, positions)
        // Декомпозированный узел №2 центрирован над своими тремя детьми.
        let second = root.children[1]
        let kidXs = second.children.map { positions[$0.id]!.x }
        #expect(abs(positions[second.id]!.x - (kidXs.first! + kidXs.last!) / 2) < 0.001)
    }

    @Test("6. Один узел")
    func singleNode() throws {
        let root = Job(verb: "одинокий")
        let positions = GraphLayout.layout(root)
        #expect(positions == [root.id: .zero])
    }

    @Test("6. Цепь глубиной 10")
    func deepChain() throws {
        var node = Job(verb: "лист")
        for i in (0..<9).reversed() {
            node = Job(verb: "уровень \(i)", children: [node])
        }
        let positions = GraphLayout.layout(node)
        try assertProperties(node, positions)
        #expect(positions.values.map(\.y).max() == 9 * LayoutMetrics.rowHeight)
        // Цепь без ветвлений — все x совпадают.
        #expect(Set(positions.values.map(\.x)).count == 1)
    }

    @Test("6. Ряд из 50 сиблингов")
    func wideRow() throws {
        let root = Job(verb: "корень", children: (0..<50).map { Job(verb: "узел \($0)") })
        let positions = GraphLayout.layout(root)
        try assertProperties(root, positions)
        let xs = root.children.map { positions[$0.id]!.x }
        #expect(xs.first == 0)
        #expect(xs.last == 49 * LayoutMetrics.columnWidth)
    }

    @Test("7. Свойства на синтетическом дереве 150 узлов")
    func propertiesSynthetic() throws {
        let root = Fixtures.synthetic(count: 150)
        #expect(root.count == 150)
        try assertProperties(root, GraphLayout.layout(root))
    }
}
