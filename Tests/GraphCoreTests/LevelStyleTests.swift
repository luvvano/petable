import Foundation
import Testing
@testable import GraphCore

/// Стиль полосы: обычные уровни идут по шкале «выше — крупнее»,
/// core-уровень стоит вне шкалы — размер и цвет у него постоянные,
/// куда бы вставка новых уровней его ни сдвинула.
@Suite("Стиль уровней")
struct LevelStyleTests {
    private func graph(coreAt index: Int, levels count: Int) -> WorkGraph {
        var graph = WorkGraph(levels: (0..<count).map { _ in GraphLevel(jobs: [JobNode(verb: "работа")]) })
        graph.levels[index].isCore = true
        return graph
    }

    @Test("Обычные уровни: чем ниже полоса, тем мельче кружок")
    func scaleShrinksDownwards() {
        let graph = graph(coreAt: 3, levels: 4)
        #expect(graph.style(atLevel: 0).diameter == 56)
        #expect(graph.style(atLevel: 1).diameter == 34)
        #expect(graph.style(atLevel: 2).diameter == 22)
    }

    @Test("Core-уровень: размер как у второй полосы шкалы, цвет свой")
    func coreStyleIsFixed() {
        let graph = graph(coreAt: 0, levels: 3)
        #expect(graph.style(atLevel: 0).diameter == LevelStyle.style(for: 1).diameter)
        #expect(graph.style(atLevel: 0).colorToken == "core")
        #expect(graph.style(atLevel: 0).isTopScale == false)
    }

    @Test("Вставка уровня сверху не меняет стиль кóровых работ")
    func insertingLevelKeepsCoreStyle() throws {
        var graph = graph(coreAt: 0, levels: 2)
        let before = graph.style(atLevel: 0)

        graph = try #require(GraphEngine.apply(.insertLevel(at: 0), to: graph)).graph
        let coreIndex = try #require(graph.coreLevelIndex)
        #expect(coreIndex == 1)
        #expect(graph.style(atLevel: coreIndex) == before)

        graph = try #require(GraphEngine.apply(.insertLevel(at: 0), to: graph)).graph
        #expect(graph.style(atLevel: try #require(graph.coreLevelIndex)) == before)
    }

    @Test("Стиль core одинаков на любой полосе")
    func coreStyleSameOnEveryBand() {
        let styles = (0..<5).map { graph(coreAt: $0, levels: 5).style(atLevel: $0) }
        #expect(Set(styles.map(\.colorToken)) == ["core"])
        #expect(Set(styles.map(\.diameter)).count == 1)
    }

    @Test("Полоса ниже кóровой сохраняет свой размер по шкале")
    func neighboursKeepScale() {
        let graph = graph(coreAt: 1, levels: 4)
        #expect(graph.style(atLevel: 0).diameter == 56)
        #expect(graph.style(atLevel: 2).diameter == 22)
        #expect(graph.style(atLevel: 3).diameter == 16)
    }

    @Test("Номер за пределами графа — обычная шкала, не core")
    func indexOutOfRange() {
        let graph = graph(coreAt: 0, levels: 1)
        #expect(graph.style(atLevel: 7).colorToken == "level4plus")
    }
}
