import Foundation

/// Почему механика неприменима к текущему выделению.
///
/// Русские тексты живут здесь, а не во вьюхе — прецедент
/// `SegmentVerdict.title`: компилятор не даст забыть кейс, а формулировки
/// тестируются без запуска UI. Серая плитка — проверка типов, не совет.
public enum MechanicUnavailable: Error, Equatable, Sendable {
    /// Класс `.sticker`: у механики нет формы над графом или карточкой.
    case noStructuralForm
    case needsSelection
    /// У выделенной работы `zoneID == nil`. Один кейс на обе зонные
    /// механики: условие у них физически одно, различается только объём.
    case needsJobInZone
    /// Нужна связь двух работ внутри уровня.
    case needsChainEdge
    /// `reduce-hand-offs`: роли двух работ совпадают — схлопывать нечего.
    case needsDistinctRoles
    /// `kill-cycles`: от выделенной работы не достижима обратная связь.
    case noCycleHere
    /// Карточная механика: исходный список карточки пуст.
    case emptyField
    /// `kill-a-job`: работа уже перечёркнута — убивать нечего.
    case alreadyKilled

    public var title: String {
        switch self {
        case .noStructuralForm:
            return "Не выражается на графе — вешается заметкой"
        case .needsSelection:
            return "Выдели работу на канвасе"
        case .needsJobInZone:
            return "Работа не в области — продукт её и так выполняет"
        case .needsChainEdge:
            return "Нужна связь двух работ внутри уровня"
        case .needsDistinctRoles:
            return "Роли работ совпадают — передачи между ролями нет"
        case .noCycleHere:
            return "От этой работы не видно цикла в цепочке"
        case .emptyField:
            return "Соответствующее поле карточки пусто"
        case .alreadyKilled:
            return "Работа уже убита — вернуть можно из её меню"
        }
    }
}

/// Трансформации механик: чистые функции «граф → граф после механики».
///
/// Инвариант (P6): успешный результат ВСЕГДА прошёл `ensureCoreLevel()`,
/// `normalizeZones()`, `normalizeEdges()` — тот же набор, что применяет
/// `Envelope.Stage.init`. Иначе Enter (`session.replace`, инвариантов не
/// применяет) и ⌥Enter (новая Stage, применяет) дали бы из одного превью
/// два разных графа, и превью бы врало.
public enum MechanicTransform {
    /// Превью механики над графом. Один вызов переиспользуется призраком,
    /// Enter и ⌥Enter — разойтись они не могут по построению.
    public static func preview(
        _ slug: String,
        in graph: WorkGraph,
        anchor: MechanicAnchor
    ) -> Result<WorkGraph, MechanicUnavailable> {
        switch slug {
        case "kill-a-job":
            return killAJob(graph, anchor: anchor)
        case "take-job-off-customer", "more-jobs-one-solution":
            // Две механики канона, одна трансформация: область естественно
            // содержит одну цепочку (addZone создаёт зону с одной работой,
            // addConnectedRight наследует zoneID, chainSuccessors ограничен
            // зоной), так что «взять работу с цепочкой» и «взять область
            // целиком» дают один граф. Различие — в словаре, не в коде.
            return absorbZone(graph, anchor: anchor)
        case "reduce-hand-offs":
            return reduceHandOffs(graph, anchor: anchor)
        case "fix-chain-breaks-between-people", "fix-unperformed-jobs-in-chain":
            // Тоже одна форма: вставить недостающую работу в разрыв цепочки.
            return insertMissingJob(graph, anchor: anchor)
        case "kill-cycles":
            return killCycles(graph, anchor: anchor)
        default:
            return .failure(.noStructuralForm)
        }
    }

    // MARK: - Топологические трансформации

    /// «Убить работу»: узел НЕ исчезает — остаётся на графе перечёркнутым
    /// (`killed`), чтобы было видно, что именно убила гипотеза. Источники
    /// СШИВАЮТСЯ с целями в обход — родитель выполняет большую работу
    /// через меньшее число живых работ (формулировка канона), цепочка не
    /// рвётся. Рёбра самого узла остаются и рисуются приглушённо.
    static func killAJob(
        _ graph: WorkGraph, anchor: MechanicAnchor
    ) -> Result<WorkGraph, MechanicUnavailable> {
        guard case let .node(id) = anchor else { return .failure(.needsSelection) }
        guard let levelIndex = graph.levelIndex(of: id),
              let job = graph.job(id)
        else { return .failure(.needsSelection) }
        guard !job.killed else { return .failure(.alreadyKilled) }

        var copy = expandingCollapsedChain(graph, at: id)
        let sources = copy.sources(of: id)
        let targets = copy.targets(of: id)

        for jobIndex in copy.levels[levelIndex].jobs.indices
        where copy.levels[levelIndex].jobs[jobIndex].id == id {
            copy.levels[levelIndex].jobs[jobIndex].killed = true
        }

        // Сшивка живых соседей в обход убитой. Декартово произведение
        // source × target, но с отсевами (P6a): петля A→A возможна, если
        // у узла были рёбра A→N и N→A (цикл — легальное состояние графа),
        // а дубликат ребра — если A→B уже существовал рядом с A→N→B.
        // edges — массив без дедупа, канвас рисует ForEach(edges,
        // id: \.self): дубль = коллизия ID.
        for source in sources {
            for target in targets where source != target {
                let exists = copy.edges.contains {
                    ($0.from == source && $0.to == target)
                        || ($0.from == target && $0.to == source)
                }
                if !exists {
                    copy.edges.append(JobEdge(from: source, to: target))
                }
            }
        }
        return .success(normalized(copy))
    }

    /// «Взять работу на себя» / «выполнять больше работ одним решением»:
    /// работы области переезжают в основную область (продукт начинает их
    /// выполнять), опустевшая рамка снимается.
    static func absorbZone(
        _ graph: WorkGraph, anchor: MechanicAnchor
    ) -> Result<WorkGraph, MechanicUnavailable> {
        let zoneID: UUID
        switch anchor {
        case let .node(id):
            guard graph.job(id) != nil else { return .failure(.needsSelection) }
            guard let jobZone = graph.zone(of: id) else { return .failure(.needsJobInZone) }
            zoneID = jobZone
        case let .zone(id):
            zoneID = id
        default:
            return .failure(.needsSelection)
        }

        var copy = graph
        var touched = false
        for levelIndex in copy.levels.indices {
            guard copy.levels[levelIndex].zones.contains(where: { $0.id == zoneID }) else { continue }
            touched = true
            for jobIndex in copy.levels[levelIndex].jobs.indices
            where copy.levels[levelIndex].jobs[jobIndex].zoneID == zoneID {
                copy.levels[levelIndex].jobs[jobIndex].zoneID = nil
            }
            // normalizeZones() опустевшую область НЕ удаляет — снимает
            // только висячие zoneID. Убираем рамку сами: пустая рамка
            // после «продукт забрал работы» была бы враньём на канвасе.
            copy.levels[levelIndex].zones.removeAll { $0.id == zoneID }
        }
        guard touched else { return .failure(.needsJobInZone) }
        return .success(normalized(copy))
    }

    /// «Сократить передачи между ролями»: два связанных узла с разными
    /// ролями схлопываются в один — исполнитель первой роли забирает обе.
    static func reduceHandOffs(
        _ graph: WorkGraph, anchor: MechanicAnchor
    ) -> Result<WorkGraph, MechanicUnavailable> {
        guard case let .chainEdge(fromID, toID) = anchor else { return .failure(.needsChainEdge) }
        guard let from = graph.job(fromID), let to = graph.job(toID),
              let levelIndex = graph.levelIndex(of: fromID),
              graph.levelIndex(of: toID) == levelIndex,
              graph.zone(of: fromID) == graph.zone(of: toID),
              graph.edges.contains(where: { $0.from == fromID && $0.to == toID })
        else { return .failure(.needsChainEdge) }
        guard normalizedRole(from.role) != normalizedRole(to.role) else {
            return .failure(.needsDistinctRoles)
        }

        var copy = expandingCollapsedChain(graph, at: fromID)

        // Склейка: остаётся первый узел, глагол объединяется, роль — от
        // первого (он теперь выполняет обе части без передачи).
        for jobIndex in copy.levels[levelIndex].jobs.indices
        where copy.levels[levelIndex].jobs[jobIndex].id == fromID {
            copy.levels[levelIndex].jobs[jobIndex].verb = "\(from.verb) и \(to.verb)"
        }
        copy.levels[levelIndex].jobs.removeAll { $0.id == toID }

        // Рёбра второго узла переезжают на первый, с теми же отсевами P6a.
        let inherited = copy.edges.filter { $0.from == toID || $0.to == toID }
        copy.edges.removeAll { $0.from == toID || $0.to == toID }
        for edge in inherited {
            let source = edge.from == toID ? fromID : edge.from
            let target = edge.to == toID ? fromID : edge.to
            guard source != target else { continue }
            let exists = copy.edges.contains {
                ($0.from == source && $0.to == target)
                    || ($0.from == target && $0.to == source)
            }
            if !exists {
                copy.edges.append(JobEdge(from: source, to: target))
            }
        }
        return .success(normalized(copy))
    }

    /// «Починить разрыв цепочки»: между двумя связанными работами
    /// вставляется недостающая — новый узел и два ребра вместо одного.
    static func insertMissingJob(
        _ graph: WorkGraph, anchor: MechanicAnchor
    ) -> Result<WorkGraph, MechanicUnavailable> {
        guard case let .chainEdge(fromID, toID) = anchor else { return .failure(.needsChainEdge) }
        guard let from = graph.job(fromID),
              let levelIndex = graph.levelIndex(of: fromID),
              graph.levelIndex(of: toID) == levelIndex,
              graph.zone(of: fromID) == graph.zone(of: toID),
              graph.edges.contains(where: { $0.from == fromID && $0.to == toID })
        else { return .failure(.needsChainEdge) }

        var copy = expandingCollapsedChain(graph, at: fromID)

        // Новая работа — сосед по области, как в .addConnectedRight.
        let inserted = JobNode(verb: "", zoneID: from.zoneID)
        let jobs = copy.levels[levelIndex].jobs
        let insertAt = (jobs.firstIndex { $0.id == fromID }.map { $0 + 1 }) ?? jobs.count
        copy.levels[levelIndex].jobs.insert(inserted, at: insertAt)

        copy.edges.removeAll { $0.from == fromID && $0.to == toID }
        copy.edges.append(JobEdge(from: fromID, to: inserted.id))
        copy.edges.append(JobEdge(from: inserted.id, to: toID))
        return .success(normalized(copy))
    }

    /// «Убить циклы»: обратная связь внутри уровня, достижимая от узла
    /// по цепочке, удаляется. Циклы — легальное состояние: toggleEdge
    /// блокирует только петлю from == to.
    static func killCycles(
        _ graph: WorkGraph, anchor: MechanicAnchor
    ) -> Result<WorkGraph, MechanicUnavailable> {
        guard case let .node(id) = anchor else { return .failure(.needsSelection) }
        guard graph.job(id) != nil else { return .failure(.needsSelection) }

        // Расстояние BFS от якоря по цепочке задаёт направление «вперёд».
        // В цикле A→B, B→A из цели каждого ребра снова достижим исток —
        // критерий «замыкает цикл» удалил бы ОБА ребра, включая прямое.
        var distance: [UUID: Int] = [id: 0]
        var queue: [UUID] = [id]
        while let current = queue.first {
            queue.removeFirst()
            for next in graph.chainSuccessors(of: current) where distance[next] == nil {
                distance[next] = distance[current, default: 0] + 1
                queue.append(next)
            }
        }

        // Обратная связь: ребро цепочки, ведущее от дальней работы к
        // ближней. Рёбра «вперёд» и рёбра между работами одного
        // расстояния (параллельные ветки) не трогаются.
        var copy = graph
        var removed = false
        for edge in graph.edges {
            guard let fromDistance = distance[edge.from],
                  let toDistance = distance[edge.to],
                  fromDistance > toDistance,
                  graph.levelIndex(of: edge.from) == graph.levelIndex(of: edge.to),
                  graph.zone(of: edge.from) == graph.zone(of: edge.to)
            else { continue }
            copy.edges.removeAll { $0 == edge }
            removed = true
        }
        guard removed else { return .failure(.noCycleHere) }
        return .success(normalized(copy))
    }

    // MARK: - Карточные трансформации

    /// Превью карточной механики: изменённая (или проверенная) карточка
    /// якорной работы. Палитра ветвится по классу: топология идёт в
    /// `preview`, карточка — сюда, стикер превью не имеет.
    ///
    /// Детерминированная правка есть только у «убрать негативные эмоции».
    /// Две критериальные механики валидируют применимость (пустое поле —
    /// честный отказ) и возвращают карточку как есть: новые пороги пишет
    /// человек, Enter открывает редактор карточки на нужном поле.
    public static func cardPreview(
        _ slug: String,
        in graph: WorkGraph,
        anchor: MechanicAnchor
    ) -> Result<JobDetails, MechanicUnavailable> {
        guard case let .node(id) = anchor else { return .failure(.needsSelection) }
        guard let job = graph.job(id) else { return .failure(.needsSelection) }
        let details = job.details

        switch slug {
        case "remove-negative-emotions":
            // Канон: убрать негатив и привести к позитиву. Перенос
            // элементов — негатив исчезает, позитив пополняется.
            guard !details.normalized().negativeEmotions.isEmpty else {
                return .failure(.emptyField)
            }
            var changed = details
            changed.positiveEmotions.append(contentsOf: changed.negativeEmotions)
            changed.negativeEmotions = []
            return .success(changed.normalized())
        case "raise-success-criteria", "core-job-at-expectations":
            // «Лучше попадать в критерии» требует, чтобы критерии были.
            guard !details.normalized().successCriteria.isEmpty else {
                return .failure(.emptyField)
            }
            return .success(details.normalized())
        case "calibrate-expectations":
            // Настройка ожиданий живёт в критериях и «чтобы»: хотя бы
            // одно из полей должно быть заполнено.
            let normalized = details.normalized()
            guard !normalized.successCriteria.isEmpty || !normalized.inOrderTo.isEmpty else {
                return .failure(.emptyField)
            }
            return .success(normalized)
        default:
            return .failure(.noStructuralForm)
        }
    }

    // MARK: - Общее

    /// P6: тот же набор нормализаций, что у Envelope.Stage.init —
    /// Enter и ⌥Enter обязаны дать идентичный граф.
    static func normalized(_ graph: WorkGraph) -> WorkGraph {
        var copy = graph
        copy.ensureCoreLevel()
        copy.normalizeZones()
        copy.normalizeEdges()
        return copy
    }

    /// Якорь на голове свёрнутой цепочки: у скрытых работ нет позиций в
    /// geometry — призрак вышел бы дырявым. Разворачиваем перед превью,
    /// как это уже делает .addConnectedRight.
    static func expandingCollapsedChain(_ graph: WorkGraph, at id: UUID) -> WorkGraph {
        var copy = graph
        for levelIndex in copy.levels.indices {
            for jobIndex in copy.levels[levelIndex].jobs.indices
            where copy.levels[levelIndex].jobs[jobIndex].id == id {
                copy.levels[levelIndex].jobs[jobIndex].isCollapsed = false
            }
        }
        return copy
    }

    /// Роль для сравнения: без регистра и краевых пробелов; nil == "".
    static func normalizedRole(_ role: String?) -> String {
        (role ?? "").trimmingCharacters(in: .whitespaces).lowercased()
    }
}
