import CoreGraphics
import Foundation
import Testing
@testable import GraphCore

@Suite("Призрак механики")
struct MechanicGhostTests {
    /// Уровень-цепочка A→B→C ниже core-уровня.
    private func chainGraph() -> (graph: WorkGraph, a: UUID, b: UUID, c: UUID) {
        let a = JobNode(verb: "а")
        let b = JobNode(verb: "б")
        let c = JobNode(verb: "в")
        var graph = WorkGraph(
            levels: [
                GraphLevel(jobs: [JobNode(verb: "кор")], isCore: true),
                GraphLevel(jobs: [a, b, c]),
            ],
            edges: [JobEdge(from: a.id, to: b.id), JobEdge(from: b.id, to: c.id)]
        )
        graph.ensureCoreLevel()
        return (graph, a.id, b.id, c.id)
    }

    // MARK: - Overlay

    @Test("1. Фантом удалённого узла присутствует в union со судьбой .removed")
    func phantomKeepsPlace() throws {
        let (graph, a, b, c) = chainGraph()
        let preview = try MechanicTransform.preview("kill-a-job", in: graph, anchor: .node(b)).get()
        let overlay = MechanicGhost.overlay(current: graph, preview: preview)

        #expect(overlay.fates[b] == .removed)
        #expect(overlay.fates[a] == .unchanged)
        #expect(overlay.fates[c] == .unchanged)
        // Фантом лежит в union между A и C — на своём месте.
        let level = overlay.union.levels[1]
        let ids = level.jobs.map(\.id)
        #expect(ids == [a, b, c])
    }

    @Test("2. P2a: фантом самого левого узла не сдвигает выживших")
    func leftmostPhantomOneCoordinateSystem() throws {
        // Главный тест координат. Удаляем самый левый узел уровня:
        // raw-раскладка превью сдвинулась бы влево целиком, и фантом по
        // «своей» геометрии встал бы поверх выжившего. В union-геометрии
        // позиции выживших совпадают с исходными, потому что фантом
        // занимает своё место и глобальный сдвиг общий.
        let (graph, a, _, _) = chainGraph()
        let preview = try MechanicTransform.preview("kill-a-job", in: graph, anchor: .node(a)).get()
        let overlay = MechanicGhost.overlay(current: graph, preview: preview)

        let before = GraphLayout.layout(graph)
        let after = GraphLayout.layout(overlay.union)
        for (id, point) in before {
            #expect(after[id] == point, "узел \(id) уехал: \(point) → \(String(describing: after[id]))")
        }
    }

    @Test("3. Удалённые и добавленные рёбра размечены")
    func edgeFates() throws {
        let (graph, a, b, _) = chainGraph()
        let preview = try MechanicTransform.preview(
            "fix-chain-breaks-between-people", in: graph, anchor: .chainEdge(from: a, to: b)
        ).get()
        let overlay = MechanicGhost.overlay(current: graph, preview: preview)

        #expect(overlay.removedEdges.contains(JobEdge(from: a, to: b)))
        #expect(overlay.addedEdges.count == 2)
        // Новый узел размечен как added.
        let addedJobs = overlay.fates.filter { $0.value == .added }
        #expect(addedJobs.count == 1)
    }

    @Test("4. Рёбра фантома возвращаются в union — фантом не висит без линий")
    func phantomKeepsEdges() throws {
        let (graph, _, b, _) = chainGraph()
        let preview = try MechanicTransform.preview("kill-a-job", in: graph, anchor: .node(b)).get()
        let overlay = MechanicGhost.overlay(current: graph, preview: preview)
        #expect(overlay.union.edges.contains { $0.from == b || $0.to == b })
    }

    @Test("5. Фантом снятой области уезжает в основную область")
    func phantomOfRemovedZone() throws {
        // Синтетический случай: превью без области и без одной работы
        // области. Фантом не может рисоваться «в рамке», которой нет.
        let zone = LevelZone()
        let inZone = JobNode(verb: "в зоне", zoneID: zone.id)
        var graph = WorkGraph(levels: [
            GraphLevel(jobs: [JobNode(verb: "кор"), inZone], isCore: true, zones: [zone])
        ])
        graph.ensureCoreLevel()
        graph.normalizeZones()

        var preview = graph
        preview.levels[0].jobs.removeAll { $0.id == inZone.id }
        preview.levels[0].zones = []
        preview.normalizeZones()

        let overlay = MechanicGhost.overlay(current: graph, preview: preview)
        let phantom = overlay.union.levels[0].jobs.first { $0.id == inZone.id }
        #expect(phantom?.zoneID == nil)
    }

    // MARK: - Delta

    @Test("6. Дельта kill-a-job: −1 работа, связи сшиты")
    func deltaKillAJob() throws {
        let (graph, _, b, _) = chainGraph()
        let preview = try MechanicTransform.preview("kill-a-job", in: graph, anchor: .node(b)).get()
        let delta = graph.delta(to: preview)
        #expect(delta.jobsRemoved == 1)
        #expect(delta.jobsAdded == 0)
        // A→B и B→C ушли, A→C появилось.
        #expect(delta.edgesRemoved == 2)
        #expect(delta.edgesAdded == 1)
        #expect(delta.summary == "−1 работа · −2 связи · +1 связь")
    }

    @Test("7. Дельта absorb: область снята, работы в кóровых")
    func deltaAbsorb() throws {
        let zone = LevelZone()
        let first = JobNode(verb: "раз", zoneID: zone.id)
        let second = JobNode(verb: "два", zoneID: zone.id)
        var graph = WorkGraph(levels: [
            GraphLevel(jobs: [JobNode(verb: "кор"), first, second], isCore: true, zones: [zone])
        ])
        graph.ensureCoreLevel()
        graph.normalizeZones()

        let preview = try MechanicTransform.preview(
            "more-jobs-one-solution", in: graph, anchor: .zone(zone.id)
        ).get()
        let delta = graph.delta(to: preview)
        #expect(delta.jobsRemoved == 0)
        #expect(delta.zonesRemoved == 1)
        #expect(delta.jobsMovedToCore == 2)
        #expect(delta.summary == "область снята · 2 работы в кóровых")
    }

    @Test("8. Нулевая дельта — пустая сводка")
    func deltaEmpty() {
        let (graph, _, _, _) = chainGraph()
        let delta = graph.delta(to: graph)
        #expect(delta.isEmpty)
        #expect(delta.summary.isEmpty)
    }
}
