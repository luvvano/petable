import Foundation
import CoreGraphics
import Testing
@testable import GraphCore

@Suite("Автораскладка по уровням")
struct LayoutTests {
    /// Свойства, обязательные для любого графа.
    private func assertProperties(_ graph: WorkGraph, _ positions: [UUID: CGPoint]) throws {
        #expect(positions.count == graph.jobCount)

        for (levelIndex, level) in graph.levels.enumerated() {
            let xs = level.jobs.compactMap { positions[$0.id]?.x }
            // Уровень строго определяет Y.
            for job in level.jobs {
                #expect(positions[job.id]?.y == CGFloat(levelIndex) * LayoutMetrics.rowHeight)
            }
            // Порядок X = порядок массива jobs, дистанция ≥ ширины колонки.
            for pair in zip(xs, xs.dropFirst()) {
                #expect(pair.1 - pair.0 >= LayoutMetrics.columnWidth - 0.001)
            }
        }

        // Нормализация: минимальный x = 0.
        if let minX = positions.values.map(\.x).min() {
            #expect(abs(minX) < 0.001)
        }
    }

    @Test("Пример «Закрыть месяц»: 3 уровня, 9 узлов, все свойства")
    func closeMonthExample() throws {
        let graph = Fixtures.closeMonth()
        let positions = GraphLayout.layout(graph)
        try assertProperties(graph, positions)

        // Первый ребёнок декомпозиции выравнивается под источником.
        let source = graph.levels[1].jobs[1]
        let firstChild = graph.levels[2].jobs[0]
        #expect(positions[firstChild.id]?.x == positions[source.id]?.x)
    }

    @Test("Связь внутри уровня: работа встаёт справа от источника")
    func inLevelConnectionGoesRight() throws {
        var graph = WorkGraph(levels: [GraphLevel(jobs: [JobNode(verb: "a"), JobNode(verb: "b")])])
        let a = graph.levels[0].jobs[0]
        let b = graph.levels[0].jobs[1]
        graph.edges = [JobEdge(from: a.id, to: b.id)]
        let positions = GraphLayout.layout(graph)
        #expect(positions[b.id]!.x - positions[a.id]!.x == LayoutMetrics.columnWidth)
    }

    @Test("Одна работа")
    func singleJob() throws {
        let graph = WorkGraph(levels: [GraphLevel(jobs: [JobNode(verb: "одинокая")])])
        let positions = GraphLayout.layout(graph)
        #expect(positions == [graph.levels[0].jobs[0].id: .zero])
    }

    @Test("Пустой граф — пустые позиции, без крэша")
    func emptyGraph() {
        #expect(GraphLayout.layout(WorkGraph(levels: [GraphLevel()])).isEmpty)
        #expect(GraphLayout.layout(WorkGraph()).isEmpty)
    }

    @Test("Цепь декомпозиций глубиной 10 — вертикальное выравнивание")
    func deepChain() throws {
        var levels: [GraphLevel] = []
        var edges: [JobEdge] = []
        var previous: JobNode?
        for index in 0..<10 {
            let node = JobNode(verb: "уровень \(index)")
            levels.append(GraphLevel(jobs: [node]))
            if let previous { edges.append(JobEdge(from: previous.id, to: node.id)) }
            previous = node
        }
        let graph = WorkGraph(levels: levels, edges: edges)
        let positions = GraphLayout.layout(graph)
        try assertProperties(graph, positions)
        // Все под источником — один столбец.
        #expect(Set(positions.values.map(\.x)).count == 1)
        #expect(positions.values.map(\.y).max() == 9 * LayoutMetrics.rowHeight)
    }

    @Test("Ряд из 50 работ в уровне")
    func wideRow() throws {
        let graph = WorkGraph(levels: [GraphLevel(jobs: (0..<50).map { JobNode(verb: "узел \($0)") })])
        let positions = GraphLayout.layout(graph)
        try assertProperties(graph, positions)
        let xs = graph.levels[0].jobs.map { positions[$0.id]!.x }
        #expect(xs.first == 0)
        #expect(xs.last == 49 * LayoutMetrics.columnWidth)
    }

    @Test("Свойства на синтетическом графе 150 узлов")
    func propertiesSynthetic() throws {
        let graph = Fixtures.synthetic(count: 150)
        #expect(graph.jobCount == 150)
        try assertProperties(graph, GraphLayout.layout(graph))
    }
}
