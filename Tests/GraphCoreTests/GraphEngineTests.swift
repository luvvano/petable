import Foundation
import Testing
@testable import GraphCore

@Suite("Интенты: граф → граф")
struct GraphEngineTests {
    @Test("Уровни: insertLevel по границам, за границами — no-op")
    func insertLevel() throws {
        let graph = Fixtures.closeMonth()
        let top = try #require(GraphEngine.apply(.insertLevel(at: 0), to: graph))
        #expect(top.graph.levels.count == 4)
        #expect(top.graph.levels[0].jobs.isEmpty)

        let bottom = try #require(GraphEngine.apply(.insertLevel(at: 3), to: graph))
        #expect(bottom.graph.levels[3].jobs.isEmpty)

        #expect(GraphEngine.apply(.insertLevel(at: -1), to: graph) == nil)
        #expect(GraphEngine.apply(.insertLevel(at: 5), to: graph) == nil)
    }

    @Test("Уровни: deleteLevel — только пустой и не единственный")
    func deleteLevel() throws {
        let graph = Fixtures.closeMonth()
        // Непустой уровень не удаляется.
        #expect(GraphEngine.apply(.deleteLevel(graph.levels[1].id), to: graph) == nil)

        // Пустой — удаляется.
        let withEmpty = try #require(GraphEngine.apply(.insertLevel(at: 0), to: graph)).graph
        let emptyId = withEmpty.levels[0].id
        let removed = try #require(GraphEngine.apply(.deleteLevel(emptyId), to: withEmpty))
        #expect(removed.graph.levels.count == 3)

        // Единственный уровень не удаляется, даже пустой.
        let single = WorkGraph(levels: [GraphLevel()])
        #expect(GraphEngine.apply(.deleteLevel(single.levels[0].id), to: single) == nil)
    }

    @Test("addJob: автономная работа в конец уровня, без связей")
    func addJob() throws {
        let graph = Fixtures.closeMonth()
        let result = try #require(GraphEngine.apply(.addJob(level: graph.levels[1].id), to: graph))
        #expect(result.graph.levels[1].jobs.count == 6)
        let newId = try #require(result.focus)
        #expect(result.graph.levels[1].jobs.last?.id == newId)
        #expect(result.graph.sources(of: newId).isEmpty)
    }

    @Test("addConnectedRight: вставка сразу справа от источника + ребро")
    func addConnectedRight() throws {
        let graph = Fixtures.closeMonth()
        let source = graph.levels[1].jobs[1]
        let result = try #require(GraphEngine.apply(.addConnectedRight(of: source.id), to: graph))
        let jobs = result.graph.levels[1].jobs
        #expect(jobs.count == 6)
        #expect(jobs[2].id == result.focus)
        #expect(result.graph.sources(of: jobs[2].id) == [source.id])
    }

    @Test("addConnectedBelow: уровень ниже; на нижнем уровне — уровень создаётся")
    func addConnectedBelow() throws {
        let graph = Fixtures.closeMonth()
        let source = graph.levels[1].jobs[0]
        let result = try #require(GraphEngine.apply(.addConnectedBelow(of: source.id), to: graph))
        #expect(result.graph.levels.count == 3)
        #expect(result.graph.levelIndex(of: try #require(result.focus)) == 2)
        #expect(result.graph.sources(of: result.focus!) == [source.id])

        // Источник на самом нижнем уровне — уровень добавляется.
        let bottomSource = graph.levels[2].jobs[0]
        let grown = try #require(GraphEngine.apply(.addConnectedBelow(of: bottomSource.id), to: graph))
        #expect(grown.graph.levels.count == 4)
        #expect(grown.graph.levelIndex(of: grown.focus!) == 3)
    }

    @Test("reorder влево/вправо внутри уровня; границы — no-op")
    func reorder() throws {
        let graph = Fixtures.closeMonth()
        let ids = graph.levels[1].jobs.map(\.id)

        let result = try #require(GraphEngine.apply(.reorder(ids[2], direction: .left), to: graph))
        #expect(result.graph.levels[1].jobs.map(\.id) == [ids[0], ids[2], ids[1], ids[3], ids[4]])

        #expect(GraphEngine.apply(.reorder(ids[0], direction: .left), to: graph) == nil)
        #expect(GraphEngine.apply(.reorder(ids[4], direction: .right), to: graph) == nil)
    }

    @Test("delete: работа и все её связи; уровень остаётся, даже пустой")
    func delete() throws {
        let graph = Fixtures.closeMonth()
        let decomposed = graph.levels[1].jobs[1] // «категоризировать», 3 ребёнка ниже
        let result = try #require(GraphEngine.apply(.delete(decomposed.id), to: graph))
        #expect(result.graph.job(decomposed.id) == nil)
        #expect(result.graph.levels.count == 3) // уровень 2 остался
        #expect(result.graph.edges.allSatisfy { $0.from != decomposed.id && $0.to != decomposed.id })
        // Фокус уходит на источник (верхний узел).
        #expect(result.focus == graph.levels[0].jobs[0].id)

        // Дети остались, но осиротели.
        for orphan in graph.levels[2].jobs {
            #expect(result.graph.job(orphan.id) != nil)
            #expect(result.graph.sources(of: orphan.id).isEmpty)
        }
    }

    @Test("toggleEdge: нет связи — создаёт, есть (в любом направлении) — удаляет")
    func toggleEdge() throws {
        let graph = Fixtures.closeMonth()
        let a = graph.levels[1].jobs[0]
        let b = graph.levels[1].jobs[1]

        // Создание: same-level ребро a → b.
        let created = try #require(GraphEngine.apply(.toggleEdge(from: a.id, to: b.id), to: graph))
        #expect(created.graph.edges.contains(JobEdge(from: a.id, to: b.id)))
        #expect(created.focus == b.id)

        // Повторный toggle с ОБРАТНЫМ направлением — ребро удаляется.
        let removed = try #require(GraphEngine.apply(.toggleEdge(from: b.id, to: a.id), to: created.graph))
        #expect(!removed.graph.edges.contains(JobEdge(from: a.id, to: b.id)))
        #expect(!removed.graph.edges.contains(JobEdge(from: b.id, to: a.id)))
        #expect(removed.graph.edges.count == graph.edges.count)

        // Петля и несуществующие узлы — no-op.
        #expect(GraphEngine.apply(.toggleEdge(from: a.id, to: a.id), to: graph) == nil)
        #expect(GraphEngine.apply(.toggleEdge(from: a.id, to: UUID()), to: graph) == nil)
    }

    @Test("setText: парсинг роли")
    func setTextParsesRole() throws {
        let graph = Fixtures.closeMonth()
        let target = graph.levels[1].jobs[0]
        let result = try #require(GraphEngine.apply(.setText(target.id, raw: "аудитор: хочу проверить остатки"), to: graph))
        let job = try #require(result.graph.job(target.id))
        #expect(job.role == "аудитор")
        #expect(job.verb == "хочу проверить остатки")
    }

    @Test("setText пустой строкой: новый узел исчезает, существующий — no-op")
    func setTextEmpty() throws {
        let graph = Fixtures.closeMonth()

        let added = try #require(GraphEngine.apply(.addConnectedBelow(of: graph.levels[1].jobs[0].id), to: graph))
        let newId = try #require(added.focus)
        let removed = try #require(GraphEngine.apply(.setText(newId, raw: "   "), to: added.graph))
        #expect(removed.graph.job(newId) == nil)
        #expect(removed.graph.edges.allSatisfy { $0.to != newId })

        let existing = graph.levels[1].jobs[0]
        #expect(GraphEngine.apply(.setText(existing.id, raw: ""), to: graph) == nil)
    }

    @Test("setText без изменений — no-op, undo не засоряется")
    func setTextNoChange() {
        let graph = Fixtures.closeMonth()
        let job = graph.levels[1].jobs[2]
        #expect(GraphEngine.apply(.setText(job.id, raw: job.displayText), to: graph) == nil)
    }

    @Test("renameLevel: имя с trim, пустое — сброс к дефолту, без изменений — no-op")
    func renameLevel() throws {
        let graph = Fixtures.closeMonth()
        let level = graph.levels[1]

        let renamed = try #require(GraphEngine.apply(.renameLevel(level.id, name: "  Кóровые  "), to: graph))
        #expect(renamed.graph.levels[1].name == "Кóровые")

        // Повторное то же имя — no-op.
        #expect(GraphEngine.apply(.renameLevel(level.id, name: "Кóровые"), to: renamed.graph) == nil)

        // Пустое имя — сброс к nil (дефолт «УРОВЕНЬ N»).
        let cleared = try #require(GraphEngine.apply(.renameLevel(level.id, name: "   "), to: renamed.graph))
        #expect(cleared.graph.levels[1].name == nil)

        // Сброс на уровне без имени — no-op; неизвестный id — no-op.
        #expect(GraphEngine.apply(.renameLevel(level.id, name: ""), to: graph) == nil)
        #expect(GraphEngine.apply(.renameLevel(UUID(), name: "x"), to: graph) == nil)
    }
}
