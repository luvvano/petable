import Foundation
import Testing
@testable import GraphCore

@Suite("Трансформации механик")
struct MechanicTransformTests {
    // MARK: - Фикстуры

    /// Уровень-цепочка A→B→C с ролями и core-уровнем сверху.
    /// Возвращает граф и id узлов.
    private func chainGraph() -> (graph: WorkGraph, a: UUID, b: UUID, c: UUID) {
        let a = JobNode(verb: "выгрузить выписку", role: "бухгалтер")
        let b = JobNode(verb: "сверить отчёты", role: "контролёр")
        let c = JobNode(verb: "утвердить закрытие", role: "финдиректор")
        var graph = WorkGraph(
            levels: [
                GraphLevel(jobs: [JobNode(verb: "закрыть месяц")], isCore: true),
                GraphLevel(jobs: [a, b, c]),
            ],
            edges: [
                JobEdge(from: a.id, to: b.id),
                JobEdge(from: b.id, to: c.id),
            ]
        )
        graph.ensureCoreLevel()
        return (graph, a.id, b.id, c.id)
    }

    /// Core-уровень с областью: в зоне две связанные работы.
    private func zonedGraph() -> (graph: WorkGraph, zone: UUID, first: UUID, second: UUID) {
        let zone = LevelZone()
        let first = JobNode(verb: "распутать наушники", zoneID: zone.id)
        let second = JobNode(verb: "подобрать длину провода", zoneID: zone.id)
        let core = JobNode(verb: "слушать музыку")
        var graph = WorkGraph(
            levels: [
                GraphLevel(jobs: [core, first, second], isCore: true, zones: [zone])
            ],
            edges: [JobEdge(from: first.id, to: second.id)]
        )
        graph.normalizeZones()
        return (graph, zone.id, first.id, second.id)
    }

    // MARK: - kill-a-job

    @Test("1. Убить работу: узел остаётся перечёркнутым, источники сшиты с целями")
    func killAJobStitches() throws {
        let (graph, a, b, c) = chainGraph()
        let result = try MechanicTransform.preview("kill-a-job", in: graph, anchor: .node(b)).get()
        // v13: узел не исчезает — виден на графе с крестиком.
        #expect(result.job(b)?.killed == true)
        // A и C сшиты в обход: живая цепочка не разорвана.
        #expect(result.edges.contains { $0.from == a && $0.to == c })
        // Рёбра убитой остаются — рисуются приглушённо.
        #expect(result.edges.contains { $0.from == a && $0.to == b })
    }

    @Test("2. Убить работу без источников: пометка без новых рёбер")
    func killAJobNoSources() throws {
        let (graph, a, b, _) = chainGraph()
        let result = try MechanicTransform.preview("kill-a-job", in: graph, anchor: .node(a)).get()
        #expect(result.job(a)?.killed == true)
        // B жива, сшивать нечего — набор рёбер не изменился.
        #expect(result.job(b)?.killed == false)
        #expect(Set(result.edges) == Set(graph.edges))
    }

    @Test("2a. Уже убитую работу убить нельзя — честный отказ")
    func killAJobAlreadyKilled() throws {
        let (graph, _, b, _) = chainGraph()
        let once = try MechanicTransform.preview("kill-a-job", in: graph, anchor: .node(b)).get()
        let again = MechanicTransform.preview("kill-a-job", in: once, anchor: .node(b))
        #expect(again == .failure(.alreadyKilled))
    }

    @Test("3. P6a: сшивка не создаёт дубликат ребра")
    func killAJobNoDuplicateEdge() throws {
        // A→N→B плюс уже существующее A→B: сшивка не должна дать второе A→B.
        var (graph, a, n, b) = chainGraph()
        graph.edges.append(JobEdge(from: a, to: b))
        _ = n
        let result = try MechanicTransform.preview("kill-a-job", in: graph, anchor: .node(n)).get()
        let abEdges = result.edges.filter { $0.from == a && $0.to == b }
        #expect(abEdges.count == 1)
    }

    @Test("4. P6a: сшивка не создаёт петлю A→A")
    func killAJobNoSelfLoop() throws {
        // Цикл A→N, N→A: у N источник A и цель A — декартово дало бы A→A.
        let a = JobNode(verb: "а")
        let n = JobNode(verb: "н")
        var graph = WorkGraph(
            levels: [GraphLevel(jobs: [a, n], isCore: true)],
            edges: [JobEdge(from: a.id, to: n.id), JobEdge(from: n.id, to: a.id)]
        )
        graph.ensureCoreLevel()
        let result = try MechanicTransform.preview("kill-a-job", in: graph, anchor: .node(n.id)).get()
        #expect(!result.edges.contains { $0.from == $0.to })
        #expect(!result.edges.contains { $0.from == a.id && $0.to == a.id })
    }

    @Test("5. Последняя работа уровня: пометка не трогает уровни")
    func killAJobLastOnLevel() throws {
        let only = JobNode(verb: "единственная")
        var graph = WorkGraph(levels: [
            GraphLevel(jobs: [JobNode(verb: "кор")], isCore: true),
            GraphLevel(jobs: [only]),
        ])
        graph.ensureCoreLevel()
        let result = try MechanicTransform.preview("kill-a-job", in: graph, anchor: .node(only.id)).get()
        #expect(result.job(only.id)?.killed == true)
        #expect(result.levels.count == 2)
    }

    @Test("6. Свёрнутая цепочка разворачивается перед превью")
    func killAJobExpandsCollapsed() throws {
        var (graph, a, b, _) = chainGraph()
        for levelIndex in graph.levels.indices {
            for jobIndex in graph.levels[levelIndex].jobs.indices
            where graph.levels[levelIndex].jobs[jobIndex].id == a {
                graph.levels[levelIndex].jobs[jobIndex].isCollapsed = true
            }
        }
        let result = try MechanicTransform.preview("kill-a-job", in: graph, anchor: .node(a)).get()
        // Голову убили, но остальная цепочка видима: у скрытых работ не
        // было бы позиций в geometry и призрак вышел бы дырявым.
        #expect(result.hiddenJobs().isEmpty)
        _ = b
    }

    // MARK: - absorb (взять работу на себя / больше работ одним решением)

    @Test("7. Взять работу на себя: zoneID снят у всех работ области, рамка удалена")
    func absorbClearsZone() throws {
        let (graph, zone, first, second) = zonedGraph()
        let result = try MechanicTransform.preview(
            "take-job-off-customer", in: graph, anchor: .node(first)
        ).get()
        #expect(result.job(first)?.zoneID == nil)
        #expect(result.job(second)?.zoneID == nil)
        #expect(!result.levels.flatMap(\.zones).contains { $0.id == zone })
    }

    @Test("8. Обе зонные механики дают идентичный граф")
    func absorbSlugsAgree() throws {
        let (graph, zone, first, _) = zonedGraph()
        let byNode = try MechanicTransform.preview(
            "take-job-off-customer", in: graph, anchor: .node(first)
        ).get()
        let byZone = try MechanicTransform.preview(
            "more-jobs-one-solution", in: graph, anchor: .zone(zone)
        ).get()
        #expect(byNode == byZone)
    }

    @Test("9. Работа в основной области → .needsJobInZone")
    func absorbRequiresZone() {
        let (graph, a, _, _) = chainGraph()
        let result = MechanicTransform.preview("take-job-off-customer", in: graph, anchor: .node(a))
        #expect(result == .failure(.needsJobInZone))
    }

    // MARK: - reduce-hand-offs

    @Test("10. Схлопывание ролей: один узел, рёбра переехали, роль первого")
    func reduceHandOffsMerges() throws {
        let (graph, a, b, c) = chainGraph()
        let result = try MechanicTransform.preview(
            "reduce-hand-offs", in: graph, anchor: .chainEdge(from: a, to: b)
        ).get()
        #expect(result.job(b) == nil)
        let merged = try #require(result.job(a))
        #expect(merged.role == "бухгалтер")
        #expect(merged.verb.contains("сверить отчёты"))
        // Ребро B→C переехало в A→C.
        #expect(result.edges.contains { $0.from == a && $0.to == c })
    }

    @Test("11. Одинаковые роли → .needsDistinctRoles")
    func reduceHandOffsSameRole() {
        let a = JobNode(verb: "раз", role: "бухгалтер")
        let b = JobNode(verb: "два", role: "Бухгалтер ")
        var graph = WorkGraph(
            levels: [GraphLevel(jobs: [a, b], isCore: true)],
            edges: [JobEdge(from: a.id, to: b.id)]
        )
        graph.ensureCoreLevel()
        // Роли сравниваются без регистра и пробелов.
        let result = MechanicTransform.preview(
            "reduce-hand-offs", in: graph, anchor: .chainEdge(from: a.id, to: b.id)
        )
        #expect(result == .failure(.needsDistinctRoles))
    }

    @Test("12. P1b: перенос узла на другой уровень — якорь деградирует")
    func chainEdgeDegrades() {
        let (graph, a, b, _) = chainGraph()
        var moved = graph
        // Переносим B на core-уровень: пара перестаёт быть цепочечной.
        if let index = moved.levels[1].jobs.firstIndex(where: { $0.id == b }) {
            let job = moved.levels[1].jobs.remove(at: index)
            moved.levels[0].jobs.append(job)
        }
        moved.normalizeEdges()
        let result = MechanicTransform.preview(
            "reduce-hand-offs", in: moved, anchor: .chainEdge(from: a, to: b)
        )
        #expect(result == .failure(.needsChainEdge))
    }

    // MARK: - insert-missing-job

    @Test("13. Вставка в разрыв: новый узел и два ребра вместо одного")
    func insertMissingJob() throws {
        let (graph, a, b, _) = chainGraph()
        let result = try MechanicTransform.preview(
            "fix-chain-breaks-between-people", in: graph, anchor: .chainEdge(from: a, to: b)
        ).get()
        #expect(!result.edges.contains { $0.from == a && $0.to == b })
        // Новый узел: A→новый→B.
        let inserted = result.edges.first { $0.from == a }?.to
        let insertedID = try #require(inserted)
        #expect(result.edges.contains { $0.from == insertedID && $0.to == b })
        #expect(result.job(insertedID)?.verb == "")
    }

    @Test("14. Обе цепочечные механики разрыва дают идентичный результат по форме")
    func insertSlugsShareForm() throws {
        let (graph, a, b, _) = chainGraph()
        // id нового узла разный (UUID), сравниваем форму: число работ и рёбер.
        let first = try MechanicTransform.preview(
            "fix-chain-breaks-between-people", in: graph, anchor: .chainEdge(from: a, to: b)
        ).get()
        let second = try MechanicTransform.preview(
            "fix-unperformed-jobs-in-chain", in: graph, anchor: .chainEdge(from: a, to: b)
        ).get()
        #expect(first.levels.map(\.jobs.count) == second.levels.map(\.jobs.count))
        #expect(first.edges.count == second.edges.count)
    }

    // MARK: - kill-cycles

    @Test("15. Цикл A→B, B→A: обратная связь удалена")
    func killCyclesRemovesBackEdge() throws {
        let a = JobNode(verb: "а")
        let b = JobNode(verb: "б")
        var graph = WorkGraph(
            levels: [GraphLevel(jobs: [a, b], isCore: true)],
            edges: [JobEdge(from: a.id, to: b.id), JobEdge(from: b.id, to: a.id)]
        )
        graph.ensureCoreLevel()
        let result = try MechanicTransform.preview("kill-cycles", in: graph, anchor: .node(a.id)).get()
        // Прямая связь осталась, обратная ушла.
        #expect(result.edges.contains { $0.from == a.id && $0.to == b.id })
        #expect(!result.edges.contains { $0.from == b.id && $0.to == a.id })
    }

    @Test("16. Нет цикла → .noCycleHere")
    func killCyclesNoCycle() {
        let (graph, a, _, _) = chainGraph()
        let result = MechanicTransform.preview("kill-cycles", in: graph, anchor: .node(a))
        #expect(result == .failure(.noCycleHere))
    }

    // MARK: - Классы и деградация

    @Test("17. Все 14 стикеров → .noStructuralForm")
    func stickersHaveNoForm() throws {
        let catalog = try MechanicCatalog.load().get()
        let (graph, a, _, _) = chainGraph()
        for mechanic in catalog.mechanics(of: .sticker) {
            let result = MechanicTransform.preview(mechanic.slug, in: graph, anchor: .node(a))
            #expect(
                result == .failure(.noStructuralForm),
                "стикер \(mechanic.slug) внезапно имеет форму"
            )
        }
    }

    @Test("18. Неизвестный слаг → .noStructuralForm, не крэш")
    func unknownSlugDegrades() {
        let (graph, a, _, _) = chainGraph()
        let result = MechanicTransform.preview("no-such-mechanic", in: graph, anchor: .node(a))
        #expect(result == .failure(.noStructuralForm))
    }

    @Test("19. P6: превью идемпотентно под нормализациями — Enter и ⌥Enter совпадают")
    func previewIsNormalized() throws {
        let cases: [(String, MechanicAnchor, WorkGraph)] = {
            let (chain, a, b, _) = chainGraph()
            let (zoned, _, first, _) = zonedGraph()
            return [
                ("kill-a-job", .node(b), chain),
                ("take-job-off-customer", .node(first), zoned),
                ("reduce-hand-offs", .chainEdge(from: a, to: b), chain),
                ("fix-chain-breaks-between-people", .chainEdge(from: a, to: b), chain),
            ]
        }()
        for (slug, anchor, graph) in cases {
            let preview = try MechanicTransform.preview(slug, in: graph, anchor: anchor).get()
            // Envelope.Stage.init применяет те же нормализации: если превью
            // уже нормализовано, форк не изменит граф.
            var renormalized = preview
            renormalized.ensureCoreLevel()
            renormalized.normalizeZones()
            renormalized.normalizeEdges()
            #expect(renormalized == preview, "превью \(slug) не идемпотентно")
        }
    }

    @Test("20. Все 7 текстов причин непустые")
    func unavailableTitlesNonEmpty() {
        let all: [MechanicUnavailable] = [
            .noStructuralForm, .needsSelection, .needsJobInZone,
            .needsChainEdge, .needsDistinctRoles, .noCycleHere, .emptyField,
        ]
        for reason in all {
            #expect(!reason.title.isEmpty)
        }
    }

    // MARK: - Карточные механики

    @Test("21. Убрать негативные эмоции: перенос в позитивные")
    func removeNegativeEmotions() throws {
        let job = JobNode(
            verb: "заполнить отчёт",
            details: JobDetails(negativeEmotions: ["страх ошибиться"], positiveEmotions: ["спокойствие"])
        )
        var graph = WorkGraph(levels: [GraphLevel(jobs: [job], isCore: true)])
        graph.ensureCoreLevel()
        let details = try MechanicTransform.cardPreview(
            "remove-negative-emotions", in: graph, anchor: .node(job.id)
        ).get()
        #expect(details.negativeEmotions.isEmpty)
        #expect(details.positiveEmotions == ["спокойствие", "страх ошибиться"])
    }

    @Test("22. Пустой negativeEmotions → .emptyField")
    func removeNegativeEmotionsEmpty() {
        let job = JobNode(verb: "работа")
        var graph = WorkGraph(levels: [GraphLevel(jobs: [job], isCore: true)])
        graph.ensureCoreLevel()
        let result = MechanicTransform.cardPreview(
            "remove-negative-emotions", in: graph, anchor: .node(job.id)
        )
        #expect(result == .failure(.emptyField))
    }

    @Test("23. Критериальные механики требуют заполненных критериев")
    func criteriaMechanicsValidate() {
        let empty = JobNode(verb: "без критериев")
        let filled = JobNode(
            verb: "с критериями",
            details: JobDetails(successCriteria: ["за 3 секунды"])
        )
        var graph = WorkGraph(levels: [GraphLevel(jobs: [empty, filled], isCore: true)])
        graph.ensureCoreLevel()
        #expect(
            MechanicTransform.cardPreview("raise-success-criteria", in: graph, anchor: .node(empty.id))
                == .failure(.emptyField)
        )
        #expect(
            (try? MechanicTransform.cardPreview(
                "raise-success-criteria", in: graph, anchor: .node(filled.id)
            ).get()) != nil
        )
    }
}
