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

    @Test("Уровни: core-уровень не удаляется, даже пустой")
    func deleteCoreLevelNoOp() throws {
        let graph = WorkGraph(levels: [
            GraphLevel(isCore: true),
            GraphLevel(jobs: [JobNode(verb: "оплатить счета")]),
        ])
        #expect(GraphEngine.apply(.deleteLevel(graph.levels[0].id), to: graph) == nil)
    }

    @Test("setCoreLevel: отметка переезжает и остаётся единственной; уже core и чужой id — no-op")
    func setCoreLevel() throws {
        var graph = Fixtures.closeMonth()
        graph.ensureCoreLevel()
        #expect(graph.coreLevelIndex == 0)

        let moved = try #require(GraphEngine.apply(.setCoreLevel(graph.levels[2].id), to: graph))
        #expect(moved.graph.levels.map(\.isCore) == [false, false, true])

        #expect(GraphEngine.apply(.setCoreLevel(moved.graph.levels[2].id), to: moved.graph) == nil)
        #expect(GraphEngine.apply(.setCoreLevel(UUID()), to: graph) == nil)
    }

    @Test("ensureCoreLevel: пустой граф, дефолт — верхний, приоритет имени «core», лишние отметки снимаются")
    func ensureCoreLevel() throws {
        var empty = WorkGraph()
        empty.ensureCoreLevel()
        #expect(empty.levels.count == 1)
        #expect(empty.levels[0].isCore)

        var plain = Fixtures.closeMonth()
        plain.ensureCoreLevel()
        #expect(plain.coreLevelIndex == 0)

        var named = Fixtures.closeMonth()
        named.levels[1].name = "Core jobs"
        named.ensureCoreLevel()
        #expect(named.coreLevelIndex == 1)

        var doubled = Fixtures.closeMonth()
        doubled.levels[0].isCore = true
        doubled.levels[2].isCore = true
        doubled.ensureCoreLevel()
        #expect(doubled.levels.map(\.isCore) == [true, false, false])
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

@Suite("Перемещение работы (drag&drop)")
struct MoveJobTests {
    @Test("move: на другой уровень в заданную позицию, рёбра сохраняются")
    func moveAcrossLevels() throws {
        let graph = Fixtures.closeMonth()
        let job = graph.levels[1].jobs[1] // «категоризировать», 3 ребра вниз
        let edgeCount = graph.edges.count

        let result = try #require(GraphEngine.apply(.move(job.id, toLevel: 2, at: 1), to: graph))
        #expect(result.focus == job.id)
        #expect(result.graph.levelIndex(of: job.id) == 2)
        #expect(result.graph.levels[2].jobs[1].id == job.id)
        #expect(result.graph.levels[1].jobs.count == 4)
        #expect(result.graph.edges.count == edgeCount)
    }

    @Test("move: внутри уровня — смена порядка")
    func moveWithinLevel() throws {
        let graph = Fixtures.closeMonth()
        let first = graph.levels[1].jobs[0]

        let result = try #require(GraphEngine.apply(.move(first.id, toLevel: 1, at: 3), to: graph))
        #expect(result.graph.levels[1].jobs[3].id == first.id)
        #expect(result.graph.levels[1].jobs.count == 5)
    }

    @Test("move: та же позиция — no-op, чужой уровень/работа — no-op, индекс clamp")
    func moveEdgeCases() throws {
        let graph = Fixtures.closeMonth()
        let job = graph.levels[1].jobs[2]

        // Та же позиция — no-op.
        #expect(GraphEngine.apply(.move(job.id, toLevel: 1, at: 2), to: graph) == nil)
        // Уровень за пределами / неизвестная работа — no-op.
        #expect(GraphEngine.apply(.move(job.id, toLevel: 5, at: 0), to: graph) == nil)
        #expect(GraphEngine.apply(.move(job.id, toLevel: -1, at: 0), to: graph) == nil)
        #expect(GraphEngine.apply(.move(UUID(), toLevel: 0, at: 0), to: graph) == nil)

        // Индекс больше числа работ — clamp в конец.
        let moved = try #require(GraphEngine.apply(.move(job.id, toLevel: 2, at: 99), to: graph))
        #expect(moved.graph.levels[2].jobs.last?.id == job.id)
    }

    @Test("move: пустой уровень принимает работу")
    func moveToEmptyLevel() throws {
        var graph = Fixtures.closeMonth()
        graph.levels.append(GraphLevel())
        let job = graph.levels[0].jobs[0]

        let result = try #require(GraphEngine.apply(.move(job.id, toLevel: 3, at: 0), to: graph))
        #expect(result.graph.levels[3].jobs.map(\.id) == [job.id])
        #expect(result.graph.levels[0].jobs.isEmpty)
    }
}

@Suite("Работы ниже и подграф")
struct JobsBelowTests {
    @Test("jobsBelow: корень — весь граф, средний узел — только своё поддерево")
    func jobsBelowSubtree() throws {
        let graph = Fixtures.closeMonth()
        let root = graph.levels[0].jobs[0]
        #expect(graph.jobsBelow(root.id).count == graph.jobCount)

        let categorize = graph.levels[1].jobs[1]
        let below = graph.jobsBelow(categorize.id)
        #expect(below.count == 4) // сама работа + 3 дочерние
        #expect(below.contains(categorize.id))
        for child in graph.levels[2].jobs {
            #expect(below.contains(child.id))
        }
        // Соседи по уровню не попадают.
        #expect(!below.contains(graph.levels[1].jobs[0].id))
    }

    @Test("jobsBelow: горизонтальная связь на стартовом уровне не тянет соседа, вверх не поднимается")
    func jobsBelowEdgeCases() throws {
        var graph = Fixtures.closeMonth()
        let categorize = graph.levels[1].jobs[1]
        let sibling = graph.levels[1].jobs[2]
        graph.edges.append(JobEdge(from: categorize.id, to: sibling.id))
        // Связь «вправо» от стартовой работы — сосед не выделяется.
        #expect(!graph.jobsBelow(categorize.id).contains(sibling.id))
        // Та же связь ниже стартового уровня — учитывается.
        let root = graph.levels[0].jobs[0]
        #expect(graph.jobsBelow(root.id).contains(sibling.id))

        // Связь вверх (ребёнок → корень) не поднимает выделение.
        let child = graph.levels[2].jobs[0]
        graph.edges.append(JobEdge(from: child.id, to: root.id))
        #expect(!graph.jobsBelow(categorize.id).contains(root.id))
    }

    @Test("jobsBelow: связь, протянутая снизу вверх, всё равно считается декомпозицией")
    func jobsBelowReversedEdge() throws {
        var graph = Fixtures.closeMonth()
        let root = graph.levels[0].jobs[0]
        let orphan = JobNode(verb: "не получать судебные иски")
        graph.levels[1].jobs.append(orphan)
        let deep = JobNode(verb: "не иметь конфликтов с гостями")
        graph.levels[2].jobs.append(deep)
        // Пользователь связал работы снизу вверх: from — нижняя работа.
        graph.edges.append(JobEdge(from: orphan.id, to: root.id))
        graph.edges.append(JobEdge(from: deep.id, to: orphan.id))

        let below = graph.jobsBelow(orphan.id)
        #expect(below.contains(orphan.id))
        #expect(below.contains(deep.id))
        // Вверх выделение всё так же не поднимается.
        #expect(!below.contains(root.id))
        // И сверху перевёрнутая связь видна: корень тянет всё поддерево.
        #expect(graph.jobsBelow(root.id).isSuperset(of: [orphan.id, deep.id]))
    }

    @Test("normalizeEdges: межуровневые связи разворачиваются сверху вниз, связи уровня не трогаются")
    func normalizeEdgesDirection() throws {
        var graph = Fixtures.closeMonth()
        let root = graph.levels[0].jobs[0]
        let middle = graph.levels[1].jobs[1]
        let sibling = graph.levels[1].jobs[2]
        graph.edges = [
            JobEdge(from: middle.id, to: root.id), // снизу вверх
            JobEdge(from: sibling.id, to: middle.id), // внутри уровня — порядок цепочки
        ]
        graph.normalizeEdges()
        #expect(graph.edges[0] == JobEdge(from: root.id, to: middle.id))
        #expect(graph.edges[1] == JobEdge(from: sibling.id, to: middle.id))
    }

    @Test("toggleEdge: связь снизу вверх сохраняется как связь сверху вниз")
    func toggleEdgeNormalizesDirection() throws {
        let graph = Fixtures.closeMonth()
        let root = graph.levels[0].jobs[0]
        let child = graph.levels[2].jobs[0]
        let linked = try #require(GraphEngine.apply(.toggleEdge(from: child.id, to: root.id), to: graph))
        #expect(linked.graph.edges.contains(JobEdge(from: root.id, to: child.id)))
        #expect(!linked.graph.edges.contains(JobEdge(from: child.id, to: root.id)))
        // Повторный жест в ту же сторону — связь снимается.
        let removed = try #require(
            GraphEngine.apply(.toggleEdge(from: child.id, to: root.id), to: linked.graph)
        )
        #expect(removed.graph.edges == graph.edges)
    }

    @Test("subgraph: остаются только выбранные работы и рёбра между ними, пустые уровни отброшены")
    func subgraphKeeping() throws {
        let graph = Fixtures.closeMonth()
        let categorize = graph.levels[1].jobs[1]
        let sub = graph.subgraph(keeping: graph.jobsBelow(categorize.id))

        #expect(sub.levels.count == 2) // верхний уровень опустел и отброшен
        #expect(sub.levels[0].jobs.map(\.id) == [categorize.id])
        #expect(sub.levels[1].jobs.count == 3)
        #expect(sub.edges.count == 3)
        #expect(sub.edges.allSatisfy { $0.from == categorize.id })
    }
}

@Suite("Карточка работы")
struct JobDetailsTests {
    private var sampleDetails: JobDetails {
        JobDetails(
            context: ["затишье, загрузка проседает"],
            negativeEmotions: ["страх овербукинга"],
            trigger: ["просела выдача на одной площадке"],
            successCriteria: ["все объекты на новой площадке", "брони синхронизируются"],
            inOrderTo: ["не зависеть от одного-двух каналов"],
            positiveEmotions: ["предпринимательский аппетит", "спокойствие"],
            frequency: "5 раз/год"
        )
    }

    @Test("setDetails: заполняет карточку, фокус на работе")
    func setDetails() throws {
        let graph = Fixtures.closeMonth()
        let job = graph.levels[1].jobs[0]

        let result = try #require(GraphEngine.apply(.setDetails(job.id, details: sampleDetails), to: graph))
        #expect(result.focus == job.id)
        #expect(result.graph.job(job.id)?.details == sampleDetails)
        // Остальные работы не тронуты.
        #expect(result.graph.job(graph.levels[1].jobs[1].id)?.details.isEmpty == true)
    }

    @Test("setDetails: нормализация — trim элементов, пустые отброшены")
    func setDetailsNormalizes() throws {
        let graph = Fixtures.closeMonth()
        let job = graph.levels[1].jobs[0]
        let dirty = JobDetails(
            context: ["  затишье  ", "", "   "],
            successCriteria: ["критерий"],
            frequency: "  5 раз/год  "
        )

        let result = try #require(GraphEngine.apply(.setDetails(job.id, details: dirty), to: graph))
        let saved = try #require(result.graph.job(job.id)?.details)
        #expect(saved.context == ["затишье"])
        #expect(saved.frequency == "5 раз/год")

        // Только мусор (пустые элементы) на пустой карточке — no-op.
        let junk = JobDetails(context: ["", "  "])
        #expect(GraphEngine.apply(.setDetails(job.id, details: junk), to: graph) == nil)
    }

    @Test("setDetails: та же карточка — no-op, неизвестная работа — no-op")
    func setDetailsNoOp() throws {
        let graph = Fixtures.closeMonth()
        let job = graph.levels[1].jobs[0]

        #expect(GraphEngine.apply(.setDetails(job.id, details: JobDetails()), to: graph) == nil)
        let filled = try #require(GraphEngine.apply(.setDetails(job.id, details: sampleDetails), to: graph))
        #expect(GraphEngine.apply(.setDetails(job.id, details: sampleDetails), to: filled.graph) == nil)
        #expect(GraphEngine.apply(.setDetails(UUID(), details: sampleDetails), to: graph) == nil)
    }

    @Test("Codable: карточка переживает round-trip конверта, пустая — не пишется в JSON")
    func codableRoundTrip() throws {
        var graph = Fixtures.closeMonth()
        let job = graph.levels[0].jobs[0]
        graph = try #require(GraphEngine.apply(.setDetails(job.id, details: sampleDetails), to: graph)).graph

        let data = try Envelope(graph: graph).encoded()
        let decoded = try Envelope.decode(data)
        #expect(decoded.jobGraph?.job(job.id)?.details == sampleDetails)

        // Пустые карточки не сериализуются — ключа details нет в JSON.
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.components(separatedBy: "\"details\"").count == 2)
    }

    @Test("Codable: узел без ключа details читается пустой карточкой")
    func decodesLegacyNode() throws {
        let json = #"{"id":"6F1F9C3B-2C9A-4B49-9B57-3A54A63C2B10","verb":"хочу сверить отчёты"}"#
        let node = try JSONDecoder().decode(JobNode.self, from: Data(json.utf8))
        #expect(node.details.isEmpty)
    }

    @Test("Codable: строковые поля раннего формата карточки мигрируют в списки по переводам строк")
    func decodesLegacyStringDetails() throws {
        let json = #"""
        {"id":"6F1F9C3B-2C9A-4B49-9B57-3A54A63C2B10","verb":"хочу выйти на новую площадку",
         "details":{"context":"затишье\nзагрузка проседает","frequency":"5 раз/год"}}
        """#
        let node = try JSONDecoder().decode(JobNode.self, from: Data(json.utf8))
        #expect(node.details.context == ["затишье", "загрузка проседает"])
        #expect(node.details.frequency == "5 раз/год")
        #expect(node.details.trigger.isEmpty)
    }

    @Test("withRegeneratedIDs: карточка переезжает вместе с работой")
    func regeneratedIDsKeepDetails() throws {
        var graph = Fixtures.closeMonth()
        let job = graph.levels[0].jobs[0]
        graph = try #require(GraphEngine.apply(.setDetails(job.id, details: sampleDetails), to: graph)).graph

        let copy = graph.withRegeneratedIDs()
        #expect(copy.levels[0].jobs[0].details == sampleDetails)
        #expect(copy.levels[0].jobs[0].id != job.id)
    }
}
