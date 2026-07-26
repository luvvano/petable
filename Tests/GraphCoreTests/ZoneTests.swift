import Foundation
import CoreGraphics
import Testing
@testable import GraphCore

/// Области уровня: работы того же уровня, которые продукт не выполняет
/// (малые работы рядом с кóровыми). Уровень один — областей на нём
/// несколько, каждая со своей рамкой и именем.
@Suite("Области уровня")
struct ZoneTests {
    /// Core-уровень: две кóровые работы + область с двумя малыми.
    private func coreWithZone() -> WorkGraph {
        let zone = LevelZone(name: "SMALL JOBS")
        return WorkGraph(levels: [
            GraphLevel(
                jobs: [
                    JobNode(verb: "закрыть месяц"),
                    JobNode(verb: "сверить отчёты"),
                    JobNode(verb: "подписать акты", zoneID: zone.id),
                    JobNode(verb: "сдать декларацию", zoneID: zone.id),
                ],
                isCore: true,
                zones: [zone]
            )
        ])
    }

    private func zoneID(_ graph: WorkGraph, level: Int = 0) -> UUID {
        graph.levels[level].zones[0].id
    }

    // MARK: - Модель

    @Test("Порядок работ: сначала основная область, потом области по порядку")
    func normalizeGroupsJobs() throws {
        let zoneA = LevelZone(name: "A")
        let zoneB = LevelZone(name: "B")
        var graph = WorkGraph(levels: [
            GraphLevel(
                jobs: [
                    JobNode(verb: "b1", zoneID: zoneB.id),
                    JobNode(verb: "main1"),
                    JobNode(verb: "a1", zoneID: zoneA.id),
                    JobNode(verb: "main2"),
                    JobNode(verb: "b2", zoneID: zoneB.id),
                ],
                zones: [zoneA, zoneB]
            )
        ])
        graph.normalizeZones()
        #expect(graph.levels[0].jobs.map(\.verb) == ["main1", "main2", "a1", "b1", "b2"])
    }

    @Test("Ссылка на несуществующую область сбрасывается в основную")
    func normalizeDropsUnknownZone() throws {
        var graph = WorkGraph(levels: [
            GraphLevel(jobs: [JobNode(verb: "сирота", zoneID: UUID())])
        ])
        graph.normalizeZones()
        #expect(graph.levels[0].jobs[0].zoneID == nil)
    }

    @Test("Запросы: зона работы, уровень области, работы области")
    func queries() throws {
        let graph = coreWithZone()
        let zone = zoneID(graph)
        #expect(graph.zone(of: graph.levels[0].jobs[0].id) == nil)
        #expect(graph.zone(of: graph.levels[0].jobs[2].id) == zone)
        #expect(graph.levelIndex(zone: zone) == 0)
        #expect(graph.levelIndex(zone: UUID()) == nil)
        #expect(graph.zone(id: zone)?.resolvedName == "SMALL JOBS")
        #expect(graph.levels[0].jobs(in: nil).count == 2)
        #expect(graph.levels[0].jobs(in: zone).map(\.verb) == ["подписать акты", "сдать декларацию"])
    }

    @Test("Имя по умолчанию — SMALL JOBS")
    func defaultName() {
        #expect(LevelZone().resolvedName == LevelZone.defaultName)
        #expect(LevelZone(name: "Микро").resolvedName == "Микро")
    }

    @Test("subgraph: область остаётся, только если остались её работы")
    func subgraphKeepsUsedZones() throws {
        let graph = coreWithZone()
        let zone = zoneID(graph)
        let onlyCore = graph.subgraph(keeping: [graph.levels[0].jobs[0].id])
        #expect(onlyCore.levels[0].zones.isEmpty)

        let withZone = graph.subgraph(keeping: [
            graph.levels[0].jobs[0].id,
            graph.levels[0].jobs[2].id,
        ])
        #expect(withZone.levels[0].zones.map(\.id) == [zone])
        #expect(withZone.levels[0].jobs(in: zone).count == 1)
    }

    // MARK: - Интенты

    @Test("addZone: область появляется сразу с пустой работой в фокусе")
    func addZone() throws {
        let graph = WorkGraph(levels: [GraphLevel(jobs: [JobNode(verb: "кóровая")], isCore: true)])
        let result = try #require(GraphEngine.apply(.addZone(level: graph.levels[0].id), to: graph))
        let level = result.graph.levels[0]
        #expect(level.zones.count == 1)
        #expect(level.zones[0].name == nil) // дефолтное имя
        #expect(level.jobs.count == 2)
        let focus = try #require(result.focus)
        #expect(level.jobs.last?.id == focus)
        #expect(level.jobs.last?.zoneID == level.zones[0].id)
        #expect(GraphEngine.apply(.addZone(level: UUID()), to: graph) == nil)
    }

    @Test("addJob(zone:): работа встаёт в конец области, порядок остаётся сгруппированным")
    func addJobInZone() throws {
        let graph = coreWithZone()
        let zone = zoneID(graph)
        let result = try #require(GraphEngine.apply(
            .addJob(level: graph.levels[0].id, zone: zone), to: graph
        ))
        #expect(result.graph.levels[0].jobs(in: zone).count == 3)
        #expect(result.graph.levels[0].jobs.last?.id == result.focus)
        // Работы основной области по-прежнему впереди.
        #expect(result.graph.levels[0].jobs.prefix(2).allSatisfy { $0.zoneID == nil })
    }

    @Test("addJob: область чужого уровня игнорируется — работа в основной области")
    func addJobForeignZone() throws {
        var graph = coreWithZone()
        graph.levels.append(GraphLevel())
        let result = try #require(GraphEngine.apply(
            .addJob(level: graph.levels[1].id, zone: zoneID(graph)), to: graph
        ))
        #expect(result.graph.levels[1].jobs[0].zoneID == nil)
    }

    @Test("addConnectedRight наследует область источника, addConnectedBelow — нет")
    func connectedInheritsZone() throws {
        let graph = coreWithZone()
        let zone = zoneID(graph)
        let small = graph.levels[0].jobs[2]

        let right = try #require(GraphEngine.apply(.addConnectedRight(of: small.id), to: graph))
        let focus = try #require(right.focus)
        let added = try #require(right.graph.job(focus))
        #expect(added.zoneID == zone)
        // Встала сразу за источником — цепочка не рвётся.
        #expect(right.graph.levels[0].jobs.map(\.id)[3] == added.id)

        let below = try #require(GraphEngine.apply(.addConnectedBelow(of: small.id), to: graph))
        #expect(below.graph.levels[1].jobs[0].zoneID == nil)
    }

    @Test("addConnectedBelow: работа основной области встаёт перед работами областей")
    func connectedBelowKeepsGrouping() throws {
        var graph = coreWithZone()
        graph.levels.append(graph.levels[0])
        graph.levels[1].id = UUID()
        let source = graph.levels[0].jobs[0]
        let result = try #require(GraphEngine.apply(.addConnectedBelow(of: source.id), to: graph))
        let jobs = result.graph.levels[1].jobs
        let firstZoned = try #require(jobs.firstIndex { $0.zoneID != nil })
        #expect(jobs.prefix(firstZoned).allSatisfy { $0.zoneID == nil })
    }

    @Test("reorder: сдвиг внутри области, через границу — no-op")
    func reorderStaysInZone() throws {
        let graph = coreWithZone()
        let zone = zoneID(graph)
        let first = graph.levels[0].jobs[2]
        let last = graph.levels[0].jobs[3]

        // Первая работа области влево — упирается в свою границу.
        #expect(GraphEngine.apply(.reorder(first.id, direction: .left), to: graph) == nil)
        #expect(GraphEngine.apply(.reorder(last.id, direction: .right), to: graph) == nil)

        let swapped = try #require(GraphEngine.apply(.reorder(first.id, direction: .right), to: graph))
        #expect(swapped.graph.levels[0].jobs(in: zone).map(\.verb)
            == ["сдать декларацию", "подписать акты"])
        // Основная область не тронута.
        #expect(swapped.graph.levels[0].jobs(in: nil).map(\.verb) == ["закрыть месяц", "сверить отчёты"])

        // Последняя работа основной области вправо — тоже граница.
        #expect(GraphEngine.apply(
            .reorder(graph.levels[0].jobs[1].id, direction: .right), to: graph
        ) == nil)
    }

    @Test("move: работа переезжает в область и обратно")
    func moveIntoZone() throws {
        let graph = coreWithZone()
        let zone = zoneID(graph)
        let core = graph.levels[0].jobs[0]

        let intoZone = try #require(GraphEngine.apply(
            .move(core.id, toLevel: 0, zone: zone, at: 0), to: graph
        ))
        #expect(intoZone.graph.zone(of: core.id) == zone)
        #expect(intoZone.graph.levels[0].jobs(in: zone).map(\.verb)
            == ["закрыть месяц", "подписать акты", "сдать декларацию"])

        let back = try #require(GraphEngine.apply(
            .move(core.id, toLevel: 0, zone: nil, at: 99), to: intoZone.graph
        ))
        #expect(back.graph.zone(of: core.id) == nil)
        #expect(back.graph.levels[0].jobs(in: nil).map(\.verb) == ["сверить отчёты", "закрыть месяц"])
    }

    @Test("move: область чужого уровня — работа уходит в основную область")
    func moveForeignZone() throws {
        var graph = coreWithZone()
        graph.levels.append(GraphLevel(jobs: [JobNode(verb: "микро")]))
        // Область живёт на уровне 0 — на уровне 1 она не действует.
        let job = graph.levels[0].jobs[2]
        let result = try #require(GraphEngine.apply(
            .move(job.id, toLevel: 1, zone: zoneID(graph), at: 0), to: graph
        ))
        #expect(result.graph.levels[1].jobs.map(\.verb) == ["подписать акты", "микро"])
        #expect(result.graph.levels[1].jobs[0].zoneID == nil)
        #expect(result.graph.levels[1].zones.isEmpty)
    }

    @Test("setJobZone: туда, обратно; та же область и чужая — no-op")
    func setJobZone() throws {
        let graph = coreWithZone()
        let zone = zoneID(graph)
        let core = graph.levels[0].jobs[0]
        let small = graph.levels[0].jobs[2]

        let moved = try #require(GraphEngine.apply(.setJobZone(core.id, zone: zone), to: graph))
        #expect(moved.graph.zone(of: core.id) == zone)
        // Порядок пересобран: основная область впереди.
        #expect(moved.graph.levels[0].jobs.map(\.verb)
            == ["сверить отчёты", "закрыть месяц", "подписать акты", "сдать декларацию"])

        let returned = try #require(GraphEngine.apply(.setJobZone(small.id, zone: nil), to: graph))
        #expect(returned.graph.zone(of: small.id) == nil)

        #expect(GraphEngine.apply(.setJobZone(small.id, zone: zone), to: graph) == nil)
        #expect(GraphEngine.apply(.setJobZone(core.id, zone: nil), to: graph) == nil)
        #expect(GraphEngine.apply(.setJobZone(core.id, zone: UUID()), to: graph) == nil)
        #expect(GraphEngine.apply(.setJobZone(UUID(), zone: zone), to: graph) == nil)
    }

    @Test("renameZone: имя, сброс пустой строкой, no-op на том же")
    func renameZone() throws {
        let graph = coreWithZone()
        let zone = zoneID(graph)
        let named = try #require(GraphEngine.apply(.renameZone(zone, name: "  Малые работы "), to: graph))
        #expect(named.graph.levels[0].zones[0].name == "Малые работы")

        let reset = try #require(GraphEngine.apply(.renameZone(zone, name: "   "), to: named.graph))
        #expect(reset.graph.levels[0].zones[0].name == nil)
        #expect(reset.graph.levels[0].zones[0].resolvedName == LevelZone.defaultName)

        #expect(GraphEngine.apply(.renameZone(zone, name: "SMALL JOBS"), to: graph) == nil)
        #expect(GraphEngine.apply(.renameZone(UUID(), name: "x"), to: graph) == nil)
    }

    @Test("deleteZone: рамка снимается, работы остаются на уровне")
    func deleteZone() throws {
        let graph = coreWithZone()
        let result = try #require(GraphEngine.apply(.deleteZone(zoneID(graph)), to: graph))
        #expect(result.graph.levels[0].zones.isEmpty)
        #expect(result.graph.levels[0].jobs.count == 4)
        #expect(result.graph.levels[0].jobs.allSatisfy { $0.zoneID == nil })
        #expect(GraphEngine.apply(.deleteZone(UUID()), to: graph) == nil)
    }

    @Test("delete работы области не трогает саму область")
    func deleteJobKeepsZone() throws {
        let graph = coreWithZone()
        let result = try #require(GraphEngine.apply(.delete(graph.levels[0].jobs[2].id), to: graph))
        #expect(result.graph.levels[0].zones.count == 1)
        #expect(result.graph.levels[0].jobs(in: zoneID(graph)).count == 1)
    }

    // MARK: - Раскладка

    @Test("Раскладка: область правее основной, зазор ≥ zoneGap, рамка покрывает работы")
    func layoutSeparatesZone() throws {
        let graph = coreWithZone()
        let zone = zoneID(graph)
        let geometry = GraphLayout.geometry(graph)
        let jobs = graph.levels[0].jobs
        let xs = jobs.map { geometry.positions[$0.id]!.x }

        // Уровень один — все работы на одной высоте.
        #expect(Set(jobs.map { geometry.positions[$0.id]!.y }) == [0])
        // Между областями — обычная дистанция плюс зазор.
        #expect(xs[2] - xs[1] == LayoutMetrics.columnWidth + LayoutMetrics.zoneGap)
        #expect(xs[3] - xs[2] == LayoutMetrics.columnWidth)

        let span = try #require(geometry.zones[zone])
        #expect(span.levelIndex == 0)
        #expect(span.minX < xs[2])
        #expect(span.maxX > xs[3])
        // Рамка не наезжает на подпись работы основной области.
        #expect(span.minX > xs[1] + LayoutMetrics.columnWidth / 2)
    }

    @Test("Раскладка: пустая область резервирует место под свою рамку")
    func layoutReservesEmptyZone() throws {
        let zone = LevelZone()
        let other = LevelZone(name: "вторая")
        let graph = WorkGraph(levels: [
            GraphLevel(
                jobs: [JobNode(verb: "кóровая"), JobNode(verb: "малая", zoneID: other.id)],
                zones: [zone, other]
            )
        ])
        let geometry = GraphLayout.geometry(graph)
        let empty = try #require(geometry.zones[zone.id])
        let filled = try #require(geometry.zones[other.id])
        #expect(empty.width == LayoutMetrics.emptyZoneWidth)
        // Пустая рамка стоит между кóровой работой и второй областью.
        #expect(empty.minX > geometry.positions[graph.levels[0].jobs[0].id]!.x)
        #expect(filled.minX > empty.maxX)
    }

    @Test("Раскладка: нормализация сдвигает рамки вместе с работами")
    func layoutNormalizesZones() throws {
        var graph = coreWithZone()
        // Работа второго уровня тянет первую влево (источник выше).
        graph.levels.insert(GraphLevel(jobs: [JobNode(verb: "большая")]), at: 0)
        let geometry = GraphLayout.geometry(graph)
        #expect(geometry.positions.values.map(\.x).min() == 0)
        let span = try #require(geometry.zones[zoneID(graph, level: 1)])
        #expect(span.levelIndex == 1)
        #expect(span.minX > 0)
    }

    // MARK: - Файл

    @Test("Конверт v8: области переживают round-trip")
    func envelopeRoundTrip() throws {
        let envelope = Envelope(graph: coreWithZone())
        let encoded = try envelope.encoded()
        let decoded = try Envelope.decode(encoded)
        #expect(decoded == envelope)
        #expect(decoded.version == 8)
        let level = try #require(decoded.jobGraph?.levels[0])
        #expect(level.zones.count == 1)
        #expect(level.jobs(in: level.zones[0].id).count == 2)
    }

    @Test("Уровень без областей не пишет ключ zones — старые файлы не растут")
    func emptyZonesNotEncoded() throws {
        let data = try Envelope(graph: Fixtures.closeMonth()).encoded()
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("zones"))
        #expect(!json.contains("zoneID"))
    }

    @Test("Файл до v8 читается: областей нет, работы в основной области")
    func preV8ReadsWithoutZones() throws {
        let graph = Fixtures.closeMonth()
        let encoded = try JSONEncoder().encode(graph)
        let graphJSON = try #require(String(data: encoded, encoding: .utf8))
        let json = #"{"version": 7, "stages": [{"type": "jobGraph", "name": "Граф", "graph": \#(graphJSON)}]}"#
        let data = try #require(json.data(using: .utf8))
        let decoded = try Envelope.decode(data)
        #expect(decoded.version == Envelope.currentVersion)
        let levels = try #require(decoded.jobGraph?.levels)
        #expect(levels.allSatisfy { $0.zones.isEmpty })
        #expect(levels.flatMap(\.jobs).allSatisfy { $0.zoneID == nil })
    }

    @Test("Импорт: id областей перегенерируются, привязка работ сохраняется")
    func regeneratedIDs() throws {
        let graph = coreWithZone()
        let copy = graph.withRegeneratedIDs()
        let oldZone = zoneID(graph)
        let newZone = try #require(copy.levels[0].zones.first)
        #expect(newZone.id != oldZone)
        #expect(newZone.name == "SMALL JOBS")
        #expect(copy.levels[0].jobs(in: newZone.id).map(\.verb)
            == ["подписать акты", "сдать декларацию"])
        #expect(copy.levels[0].jobs(in: nil).count == 2)
    }

    // MARK: - Агент

    @Test("Payload агента: узлы с одинаковым zone попадают в одну область, рёбра не сбиваются")
    func agentPayloadZones() throws {
        let payload = AgentArtifactsPayload.Graph(
            name: "Граф",
            levels: [
                [
                    .init(verb: "малая", zone: "SMALL JOBS"),
                    .init(verb: "кóровая"),
                    .init(verb: "вторая малая", zone: "SMALL JOBS"),
                ],
                [.init(verb: "микро")],
            ],
            // Ребро на «кóровую» (индекс 1 в порядке агента) с уровня ниже.
            edges: [.init(fromLevel: 0, fromIndex: 1, toLevel: 1, toIndex: 0)],
            coreLevel: 0
        )
        let graph = payload.makeWorkGraph()
        let level = graph.levels[0]
        #expect(level.zones.count == 1)
        #expect(level.zones[0].resolvedName == "SMALL JOBS")
        // Порядок пересобран по областям, ребро по-прежнему на «кóровую».
        #expect(level.jobs.map(\.verb) == ["кóровая", "малая", "вторая малая"])
        let core = try #require(level.jobs.first)
        #expect(graph.sources(of: graph.levels[1].jobs[0].id) == [core.id])
    }

    @Test("update_graph: область работы переживает правку, даже если агент её не указал")
    func agentPreservesZones() throws {
        var old = coreWithZone()
        old.levels[0].jobs[2].details = JobDetails(context: ["конец квартала"])
        let payload = AgentArtifactsPayload.Graph(
            name: "Граф",
            levels: [[
                .init(verb: "закрыть месяц"),
                .init(verb: "сверить отчёты"),
                .init(verb: "подписать акты"), // zone не указан
                .init(verb: "сдать декларацию"),
                .init(verb: "новая работа"),
            ]],
            coreLevel: 0
        )
        let updated = payload.makeWorkGraph(preservingFrom: old)
        let level = updated.levels[0]
        #expect(level.zones.map(\.id) == [zoneID(old)])
        #expect(level.jobs(in: zoneID(old)).map(\.verb) == ["подписать акты", "сдать декларацию"])
        #expect(level.jobs(in: nil).map(\.verb) == ["закрыть месяц", "сверить отчёты", "новая работа"])
        // Карточка тоже на месте.
        #expect(level.jobs(in: zoneID(old))[0].details.context == ["конец квартала"])
    }

    @Test("update_graph: область с тем же именем сохраняет прежний id")
    func agentReusesZoneID() throws {
        let old = coreWithZone()
        let payload = AgentArtifactsPayload.Graph(
            name: "Граф",
            levels: [[
                .init(verb: "закрыть месяц"),
                .init(verb: "подписать акты", zone: "SMALL JOBS"),
            ]],
            coreLevel: 0
        )
        let updated = payload.makeWorkGraph(preservingFrom: old)
        #expect(updated.levels[0].zones.map(\.id) == [zoneID(old)])
        #expect(updated.levels[0].jobs(in: zoneID(old)).map(\.verb) == ["подписать акты"])
    }

    @Test("Контекст проекта для агента показывает область узла")
    func agentContextShowsZone() throws {
        let context = AgentChatContext.describe(
            graphs: [Envelope.Stage(name: "Граф", graph: coreWithZone())],
            research: Research(templates: []),
            segments: []
        )
        #expect(context.contains("(область «SMALL JOBS»)"))
    }
}
