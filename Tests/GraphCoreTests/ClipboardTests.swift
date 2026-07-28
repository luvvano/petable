import Foundation
import Testing
@testable import GraphCore

/// Копирование и вставка работ: выделенное поддерево уезжает в буфер
/// вместе с местом (уровень, область) и связями, а вставка кладёт копию
/// со свежими id на те же уровни.
@Suite("Буфер обмена работ")
struct ClipboardTests {
    /// Два уровня: кóровая работа A с декомпозицией B → C и соседняя
    /// кóровая работа X со своей декомпозицией Y.
    private func graph() -> WorkGraph {
        let a = JobNode(verb: "A")
        let x = JobNode(verb: "X")
        let b = JobNode(verb: "B")
        let c = JobNode(verb: "C")
        let y = JobNode(verb: "Y")
        return WorkGraph(
            levels: [
                GraphLevel(jobs: [a, x], isCore: true),
                GraphLevel(jobs: [b, c, y]),
            ],
            edges: [
                JobEdge(from: a.id, to: b.id),
                JobEdge(from: b.id, to: c.id),
                JobEdge(from: x.id, to: y.id),
            ]
        )
    }

    private func id(_ graph: WorkGraph, _ verb: String) -> UUID {
        graph.allJobs.first { $0.verb == verb }!.id
    }

    private func verbs(_ graph: WorkGraph, level: Int) -> [String] {
        graph.levels[level].jobs.map(\.verb)
    }

    // MARK: - Снимок в буфер

    @Test("В буфер уходят только выделенные работы и связи между ними")
    func clipboardKeepsSelectionOnly() {
        let graph = self.graph()
        let clipboard = graph.clipboard(keeping: graph.jobsBelow(id(graph, "A")))

        #expect(clipboard.jobCount == 3)
        #expect(clipboard.levels.count == 2)
        #expect(clipboard.levels[0].jobs.map(\.verb) == ["A"])
        #expect(clipboard.levels[1].jobs.map(\.verb) == ["B", "C"])
        // Связь X → Y осталась за бортом вместе с X и Y.
        #expect(clipboard.edges.count == 2)
    }

    @Test("Уровень запоминается номером и id — вставке есть куда лечь")
    func clipboardRemembersLevels() {
        let graph = self.graph()
        let clipboard = graph.clipboard(keeping: graph.jobsBelow(id(graph, "A")))

        #expect(clipboard.levels[0].index == 0)
        #expect(clipboard.levels[0].id == graph.levels[0].id)
        #expect(clipboard.levels[1].index == 1)
        #expect(clipboard.levels[1].id == graph.levels[1].id)
    }

    @Test("Область работы едет в буфер вместе с ней")
    func clipboardKeepsZone() {
        let zone = LevelZone(name: "SMALL JOBS")
        let small = JobNode(verb: "малая", zoneID: zone.id)
        let graph = WorkGraph(levels: [GraphLevel(jobs: [small], isCore: true, zones: [zone])])
        let clipboard = graph.clipboard(keeping: [small.id])

        #expect(clipboard.levels[0].zones == [zone])
        #expect(clipboard.levels[0].jobs[0].zoneID == zone.id)
    }

    @Test("Свёрнутость снимается, если цепочка не попала в выделение")
    func clipboardDropsDanglingCollapse() {
        let head = JobNode(verb: "голова", isCollapsed: true)
        let tail = JobNode(verb: "хвост")
        let graph = WorkGraph(
            levels: [GraphLevel(jobs: [head, tail], isCore: true)],
            edges: [JobEdge(from: head.id, to: tail.id)]
        )

        #expect(graph.clipboard(keeping: [head.id]).levels[0].jobs[0].isCollapsed == false)
        #expect(graph.clipboard(keeping: [head.id, tail.id]).levels[0].jobs[0].isCollapsed == true)
    }

    @Test("JSON буфера переживает round-trip")
    func clipboardRoundTrips() throws {
        let graph = self.graph()
        let clipboard = graph.clipboard(keeping: graph.jobsBelow(id(graph, "A")))
        let decoded = try JobClipboard.decode(try clipboard.encoded())

        #expect(decoded == clipboard)
    }

    @Test("Чужой JSON буфером работ не притворяется")
    func clipboardRejectsForeignJSON() throws {
        let data = try WorkGraphExportFile(name: "граф", graph: graph()).encoded()
        #expect(throws: ExportFileError.self) { try JobClipboard.decode(data) }
    }

    // MARK: - Вставка

    @Test("Вставка кладёт копию на те же уровни, оригинал не трогает")
    func pasteAddsCopyToSameLevels() throws {
        let graph = self.graph()
        let clipboard = graph.clipboard(keeping: graph.jobsBelow(id(graph, "A")))
        let result = try #require(GraphEngine.apply(.paste(clipboard, atLevel: nil), to: graph))

        #expect(verbs(result.graph, level: 0) == ["A", "X", "A"])
        #expect(verbs(result.graph, level: 1) == ["B", "C", "Y", "B", "C"])
        #expect(result.graph.levels.count == 2)
    }

    @Test("У копии свои id, связи внутри неё повторяют оригинал")
    func pasteRegeneratesIDs() throws {
        let graph = self.graph()
        let clipboard = graph.clipboard(keeping: graph.jobsBelow(id(graph, "A")))
        let result = try #require(GraphEngine.apply(.paste(clipboard, atLevel: nil), to: graph))
        let pasted = Set(result.graph.allJobs.map(\.id))
            .subtracting(graph.allJobs.map(\.id))

        #expect(pasted.count == 3)
        // Копия связана сама с собой: A' → B' → C', три работы, две связи.
        let focus = try #require(result.focus)
        let root = try #require(result.graph.job(focus))
        #expect(root.verb == "A")
        #expect(result.graph.jobsBelow(root.id) == pasted)
        #expect(result.graph.edges.count == graph.edges.count + 2)
    }

    @Test("Карточка и текст работы копируются")
    func pasteKeepsDetails() throws {
        let details = JobDetails(context: ["в конце месяца"], successCriteria: ["без ошибок"])
        let source = JobNode(verb: "закрыть месяц", role: "бухгалтер", details: details)
        let graph = WorkGraph(levels: [GraphLevel(jobs: [source], isCore: true)])
        let result = try #require(
            GraphEngine.apply(.paste(graph.clipboard(keeping: [source.id]), atLevel: nil), to: graph)
        )
        let copy = try #require(result.graph.levels[0].jobs.last)

        #expect(copy.id != source.id)
        #expect(copy.verb == source.verb)
        #expect(copy.role == source.role)
        #expect(copy.details == details)
    }

    @Test("Вставка в свой уровень идёт по id, даже если уровни переставили")
    func pasteFollowsLevelID() throws {
        let graph = self.graph()
        let clipboard = graph.clipboard(keeping: [id(graph, "B"), id(graph, "C")])
        // Сверху появился новый уровень — номера уровней уехали, id остались.
        var moved = graph
        moved.levels.insert(GraphLevel(), at: 0)
        let result = try #require(GraphEngine.apply(.paste(clipboard, atLevel: nil), to: moved))

        #expect(verbs(result.graph, level: 2) == ["B", "C", "Y", "B", "C"])
        #expect(result.graph.levels.count == 3)
    }

    @Test("Вставка в чужой граф ложится по номеру уровня, недостающие дописываются")
    func pasteIntoOtherGraphUsesLevelIndex() throws {
        let graph = self.graph()
        let clipboard = graph.clipboard(keeping: graph.jobsBelow(id(graph, "A")))
        let other = WorkGraph(levels: [GraphLevel(jobs: [JobNode(verb: "чужая")], isCore: true)])
        let result = try #require(GraphEngine.apply(.paste(clipboard, atLevel: nil), to: other))

        #expect(result.graph.levels.count == 2)
        #expect(verbs(result.graph, level: 0) == ["чужая", "A"])
        #expect(verbs(result.graph, level: 1) == ["B", "C"])
    }

    @Test("Область восстанавливается: своя — по id, чужая — новой рамкой")
    func pasteRestoresZone() throws {
        let zone = LevelZone(name: "SMALL JOBS")
        let small = JobNode(verb: "малая", zoneID: zone.id)
        let graph = WorkGraph(levels: [GraphLevel(jobs: [small], isCore: true, zones: [zone])])
        let clipboard = graph.clipboard(keeping: [small.id])

        let inPlace = try #require(GraphEngine.apply(.paste(clipboard, atLevel: nil), to: graph))
        #expect(inPlace.graph.levels[0].zones.count == 1)
        #expect(inPlace.graph.levels[0].jobs.allSatisfy { $0.zoneID == zone.id })

        let other = WorkGraph(levels: [GraphLevel(isCore: true)])
        let pasted = try #require(GraphEngine.apply(.paste(clipboard, atLevel: nil), to: other))
        let newZone = try #require(pasted.graph.levels[0].zones.first)
        #expect(newZone.id != zone.id)
        #expect(newZone.name == zone.name)
        #expect(pasted.graph.levels[0].jobs[0].zoneID == newZone.id)
    }

    // MARK: - Вставка на уровень под курсором

    @Test("Верх копии ложится на указанный уровень, декомпозиция — ниже")
    func pasteAnchorsTopLevelAtCursor() throws {
        let graph = self.graph()
        let clipboard = graph.clipboard(keeping: graph.jobsBelow(id(graph, "A")))
        // Курсор на нижнем уровне: копия уходит на уровень 1 и создаёт 2.
        let result = try #require(GraphEngine.apply(.paste(clipboard, atLevel: 1), to: graph))

        #expect(result.graph.levels.count == 3)
        #expect(verbs(result.graph, level: 0) == ["A", "X"])
        #expect(verbs(result.graph, level: 1) == ["B", "C", "Y", "A"])
        #expect(verbs(result.graph, level: 2) == ["B", "C"])
    }

    @Test("Недостающие уровни создаются под каждую ступень копии")
    func pasteAnchorCreatesMissingLevels() throws {
        // Копия в три уровня: A → B → его декомпозиция D.
        var graph = self.graph()
        let d = JobNode(verb: "D")
        graph.levels.append(GraphLevel(jobs: [d]))
        graph.edges.append(JobEdge(from: id(graph, "B"), to: d.id))
        let clipboard = graph.clipboard(keeping: graph.jobsBelow(id(graph, "A")))
        #expect(clipboard.levels.count == 3)

        let result = try #require(GraphEngine.apply(.paste(clipboard, atLevel: 2), to: graph))
        #expect(result.graph.levels.count == 5)
        #expect(verbs(result.graph, level: 2) == ["D", "A"])
        #expect(verbs(result.graph, level: 3) == ["B", "C"])
        #expect(verbs(result.graph, level: 4) == ["D"])
    }

    @Test("Связи копии переживают переезд на другие уровни")
    func pasteAnchorKeepsEdges() throws {
        let graph = self.graph()
        let clipboard = graph.clipboard(keeping: graph.jobsBelow(id(graph, "A")))
        let result = try #require(GraphEngine.apply(.paste(clipboard, atLevel: 1), to: graph))
        let focus = try #require(result.focus)

        // Копия связана сама с собой и лежит на уровнях 1 и 2.
        let pasted = result.graph.jobsBelow(focus)
        #expect(pasted.count == 3)
        #expect(result.graph.levelIndex(of: focus) == 1)
        #expect(result.graph.edges.count == graph.edges.count + 2)
    }

    @Test("Пустой буфер — no-op")
    func pasteEmptyIsNoOp() {
        let graph = self.graph()
        #expect(GraphEngine.apply(.paste(JobClipboard(levels: [], edges: []), atLevel: nil), to: graph) == nil)
    }
}
