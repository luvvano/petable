import Foundation
import CoreGraphics
import Testing
@testable import GraphCore

/// Сворачивание цепочек работ одного уровня: работа с флагом
/// `isCollapsed` прячет всё, что стоит справа от неё по связям внутри
/// уровня, вместе с декомпозицией этих работ. Голова цепочки видна всегда.
@Suite("Свёрнутые цепочки")
struct CollapseTests {
    /// Один уровень, цепочка A → B → C, плюс автономная работа D.
    private func chainGraph() -> WorkGraph {
        let a = JobNode(verb: "A")
        let b = JobNode(verb: "B")
        let c = JobNode(verb: "C")
        let d = JobNode(verb: "D")
        return WorkGraph(
            levels: [GraphLevel(jobs: [a, b, c, d], isCore: true)],
            edges: [JobEdge(from: a.id, to: b.id), JobEdge(from: b.id, to: c.id)]
        )
    }

    private func id(_ graph: WorkGraph, _ verb: String, level: Int = 0) -> UUID {
        graph.levels[level].jobs.first { $0.verb == verb }!.id
    }

    // MARK: - Модель

    @Test("Цепочка — связи внутри уровня, транзитивно")
    func chainFollowsLevelEdges() {
        let graph = chainGraph()
        #expect(graph.chain(after: id(graph, "A")).count == 2)
        #expect(graph.chain(after: id(graph, "B")) == [id(graph, "C")])
        #expect(graph.chain(after: id(graph, "C")).isEmpty)
        #expect(graph.chain(after: id(graph, "D")).isEmpty)
    }

    @Test("Декомпозиция ниже цепочкой не считается")
    func chainIgnoresLowerLevel() {
        let top = JobNode(verb: "верх")
        let below = JobNode(verb: "низ")
        let graph = WorkGraph(
            levels: [GraphLevel(jobs: [top], isCore: true), GraphLevel(jobs: [below])],
            edges: [JobEdge(from: top.id, to: below.id)]
        )
        #expect(graph.chain(after: top.id).isEmpty)
    }

    @Test("Работа соседней области — не продолжение цепочки")
    func chainStopsAtZoneBorder() {
        let zone = LevelZone()
        let core = JobNode(verb: "кóровая")
        let small = JobNode(verb: "малая", zoneID: zone.id)
        let graph = WorkGraph(
            levels: [GraphLevel(jobs: [core, small], isCore: true, zones: [zone])],
            edges: [JobEdge(from: core.id, to: small.id)]
        )
        #expect(graph.chain(after: core.id).isEmpty)
    }

    @Test("Свёрнутая голова прячет цепочку, сама остаётся видимой")
    func hiddenJobsCoversChain() {
        var graph = chainGraph()
        graph.levels[0].jobs[0].isCollapsed = true
        let hidden = graph.hiddenJobs()
        #expect(hidden == [id(graph, "B"), id(graph, "C")])
        #expect(!hidden.contains(id(graph, "A")))
        #expect(!hidden.contains(id(graph, "D")))
    }

    @Test("Декомпозиция скрытой работы уходит вместе с ней на всю глубину")
    func hiddenJobsCascadesDown() {
        var graph = chainGraph()
        let child = JobNode(verb: "под B")
        let grandChild = JobNode(verb: "под ребёнком")
        graph.levels.append(GraphLevel(jobs: [child]))
        graph.levels.append(GraphLevel(jobs: [grandChild]))
        graph.edges.append(JobEdge(from: id(graph, "B"), to: child.id))
        graph.edges.append(JobEdge(from: child.id, to: grandChild.id))
        graph.levels[0].jobs[0].isCollapsed = true

        let hidden = graph.hiddenJobs()
        #expect(hidden.contains(child.id))
        #expect(hidden.contains(grandChild.id))
    }

    @Test("Работа с живым источником остаётся видимой")
    func hiddenJobsKeepsSharedChild() {
        var graph = chainGraph()
        let child = JobNode(verb: "под A и B")
        graph.levels.append(GraphLevel(jobs: [child]))
        graph.edges.append(JobEdge(from: id(graph, "A"), to: child.id))
        graph.edges.append(JobEdge(from: id(graph, "B"), to: child.id))
        graph.levels[0].jobs[0].isCollapsed = true

        #expect(!graph.hiddenJobs().contains(child.id))
    }

    @Test("Связь назад не прячет саму голову цепочки")
    func hiddenJobsSurvivesCycle() {
        var graph = chainGraph()
        graph.edges.append(JobEdge(from: id(graph, "C"), to: id(graph, "A")))
        graph.levels[0].jobs[0].isCollapsed = true

        #expect(!graph.hiddenJobs().contains(id(graph, "A")))
    }

    @Test("Флаг без цепочки (связь удалили) ничего не прячет")
    func hiddenJobsIgnoresStaleFlag() {
        var graph = chainGraph()
        graph.levels[0].jobs[0].isCollapsed = true
        graph.edges.removeAll()
        #expect(graph.hiddenJobs().isEmpty)
    }

    // MARK: - Интент

    @Test("setCollapsed сворачивает и разворачивает цепочку")
    func intentTogglesFlag() throws {
        let graph = chainGraph()
        let a = id(graph, "A")
        let collapsed = try #require(GraphEngine.apply(.setCollapsed(a, true), to: graph))
        #expect(collapsed.graph.job(a)?.isCollapsed == true)
        #expect(collapsed.focus == a)

        let expanded = try #require(GraphEngine.apply(.setCollapsed(a, false), to: collapsed.graph))
        #expect(expanded.graph.job(a)?.isCollapsed == false)
    }

    @Test("Сворачивать нечего — no-op")
    func intentNoOpWithoutChain() {
        let graph = chainGraph()
        #expect(GraphEngine.apply(.setCollapsed(id(graph, "D"), true), to: graph) == nil)
        #expect(GraphEngine.apply(.setCollapsed(id(graph, "C"), true), to: graph) == nil)
    }

    @Test("То же состояние — no-op")
    func intentNoOpOnSameState() {
        let graph = chainGraph()
        #expect(GraphEngine.apply(.setCollapsed(id(graph, "A"), false), to: graph) == nil)
    }

    @Test("Работа справа разворачивает свёрнутую цепочку")
    func addConnectedRightExpands() throws {
        var graph = chainGraph()
        graph.levels[0].jobs[0].isCollapsed = true
        let a = id(graph, "A")

        let result = try #require(GraphEngine.apply(.addConnectedRight(of: a), to: graph))
        #expect(result.graph.job(a)?.isCollapsed == false)
        let newID = try #require(result.focus)
        #expect(!result.graph.hiddenJobs().contains(newID))
    }

    // MARK: - Раскладка

    @Test("Скрытые работы не занимают места на полосе")
    func layoutSkipsHiddenJobs() {
        var graph = chainGraph()
        let geometry = GraphLayout.geometry(graph)
        let dBefore = geometry.positions[id(graph, "D")]?.x

        graph.levels[0].jobs[0].isCollapsed = true
        let collapsed = GraphLayout.geometry(graph)
        #expect(collapsed.positions[id(graph, "B")] == nil)
        #expect(collapsed.positions[id(graph, "C")] == nil)
        // D переезжает на освободившееся место сразу за головой цепочки.
        #expect(collapsed.positions[id(graph, "D")]?.x == LayoutMetrics.columnWidth)
        #expect(dBefore == LayoutMetrics.columnWidth * 3)
    }

    @Test("Точка вставки перешагивает скрытый хвост цепочки")
    func dropTargetSkipsHiddenTail() throws {
        var graph = chainGraph()
        graph.levels[0].jobs[0].isCollapsed = true
        let geometry = GraphLayout.geometry(graph)
        // Точка между свёрнутой головой A (x = 0) и автономной D.
        let target = try #require(GraphLayout.dropTarget(
            graph: graph,
            geometry: geometry,
            at: CGPoint(x: LayoutMetrics.columnWidth / 2, y: 0),
            bandOffset: 0
        ))
        // A, B, C — три работы модели левее точки: вставка перед D.
        #expect(target.index == 3)
        #expect(target.levelIndex == 0)
    }

    // MARK: - Файл

    @Test("Флаг переживает сохранение; развёрнутая цепочка в JSON не пишется")
    func codableRoundTrip() throws {
        var graph = chainGraph()
        graph.levels[0].jobs[0].isCollapsed = true

        let data = try JSONEncoder().encode(graph)
        let restored = try JSONDecoder().decode(WorkGraph.self, from: data)
        #expect(restored.job(id(graph, "A"))?.isCollapsed == true)
        #expect(restored.job(id(graph, "D"))?.isCollapsed == false)

        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.components(separatedBy: "isCollapsed").count - 1 == 1)
    }

    @Test("Конверт: свёрнутая цепочка переживает сохранение документа")
    func envelopeRoundTrip() throws {
        var graph = chainGraph()
        graph.levels[0].jobs[0].isCollapsed = true
        let envelope = Envelope(graph: graph)
        let decoded = try Envelope.decode(try envelope.encoded())

        #expect(decoded.version == Envelope.currentVersion)
        #expect(decoded.jobGraph?.job(id(graph, "A"))?.isCollapsed == true)
        #expect(decoded.jobGraph?.hiddenJobs().count == 2)
    }

    @Test("Файл v8 читается: цепочки развёрнуты")
    func decodesV8Envelope() throws {
        let graph = chainGraph()
        let graphJSON = try #require(String(data: try JSONEncoder().encode(graph), encoding: .utf8))
        let json = #"{"version": 8, "stages": [{"type": "jobGraph", "graph": \#(graphJSON)}]}"#
        let decoded = try Envelope.decode(Data(json.utf8))
        #expect(decoded.jobGraph?.hiddenJobs().isEmpty == true)
    }

    @Test("Старый файл без ключа читается")
    func decodesLegacyNode() throws {
        let json = """
        {"id":"\(UUID().uuidString)","verb":"A"}
        """
        let node = try JSONDecoder().decode(JobNode.self, from: Data(json.utf8))
        #expect(node.isCollapsed == false)
    }
}
