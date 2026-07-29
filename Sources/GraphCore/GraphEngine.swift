import Foundation

/// Интенты редактирования. Единственный способ менять граф.
///
///   клавиша/клик → GraphIntent → GraphSession.perform(intent)
///                                    ├─ снапшот до правки → UndoManager
///                                    ├─ GraphEngine.apply (чистая функция)
///                                    └─ новый граф → SwiftUI → layout → рендер
public enum GraphIntent: Equatable, Sendable {
    /// Вставить пустой уровень по индексу (0 = самый верхний,
    /// levels.count = под нижним).
    case insertLevel(at: Int)
    /// Удалить уровень. Только пустой, не единственный и не core —
    /// иначе no-op.
    case deleteLevel(UUID)
    /// Автономная работа: добавляется на уровень (или в его область
    /// `zone`), ни с чем не связана. `at` — позиция внутри области:
    /// по умолчанию конец, за пределами — clamp. Двойной клик по канвасу
    /// передаёт позицию под курсором — работа появляется там, где кликнули.
    case addJob(level: UUID, zone: UUID? = nil, at: Int = .max)
    /// Связанная работа справа на том же уровне + ребро от исходной.
    case addConnectedRight(of: UUID)
    /// Связанная работа на уровне ниже + ребро от исходной.
    /// Если исходная на нижнем уровне — уровень создаётся.
    case addConnectedBelow(of: UUID)
    /// Сдвиг работы влево/вправо внутри своей области уровня —
    /// через границу области работа не перепрыгивает (для этого
    /// `setJobZone` или перетаскивание).
    case reorder(UUID, direction: ReorderDirection)
    /// Перемещение работы (drag&drop): на уровень `toLevel`, в область
    /// `zone` (nil — основная область уровня), в позицию `at` внутри этой
    /// области. Индекс за пределами — clamp; зона чужого уровня — работа
    /// уходит в основную область; рёбра сохраняются; ничего не изменилось —
    /// no-op.
    case move(UUID, toLevel: Int, zone: UUID? = nil, at: Int)
    /// Удаляет работу и все её связи. Уровень остаётся, даже пустой.
    case delete(UUID)
    /// Связь между существующими работами: есть (в любом направлении) —
    /// удалить, нет — создать from → to. Петля from == to — no-op.
    case toggleEdge(from: UUID, to: UUID)
    /// Разбирает `raw` грамматикой role:. Пустая строка на только что
    /// созданном (пустом) узле — удаление, на существующем — no-op.
    case setText(UUID, raw: String)
    /// Полная замена карточки работы. Карточка нормализуется (trim,
    /// пустые элементы списков отброшены); совпадает с текущей — no-op.
    case setDetails(UUID, details: JobDetails)
    /// Имя уровня. Пустая строка (после trim) — сброс к дефолту «УРОВЕНЬ N».
    case renameLevel(UUID, name: String)
    /// Назначить уровень core-уровнем: отметка снимается с прежнего —
    /// core в графе всегда один. Уже core — no-op.
    case setCoreLevel(UUID)
    /// Новая область на уровне — рамка «тот же уровень, другое покрытие
    /// продуктом» (малые работы рядом с кóровыми). Создаётся сразу
    /// с одной пустой работой: фокус на неё, можно печатать.
    /// Только на core-уровне: рамка «продукт этого не выполняет»
    /// осмысленна лишь рядом с кóровыми работами — на остальных
    /// уровнях no-op.
    case addZone(level: UUID)
    /// Имя области. Пустая строка (после trim) — сброс к «SMALL JOBS».
    case renameZone(UUID, name: String)
    /// Удалить область. Её работы остаются на уровне и переходят
    /// в основную область — рамка снимается, наработки не теряются.
    case deleteZone(UUID)
    /// Перенести работу в область своего уровня (nil — обратно
    /// в основную). Зона чужого уровня или та же область — no-op.
    case setJobZone(UUID, zone: UUID?)
    /// Свернуть (true) или развернуть (false) цепочку работ одного
    /// уровня: работы, связанные с этой внутри уровня, скрываются
    /// с канваса вместе со своей декомпозицией. Работа без цепочки
    /// справа не сворачивается (флаг был бы невидимой пылью в файле),
    /// то же состояние — no-op.
    case setCollapsed(UUID, Bool)
    /// Убить (true) или вернуть (false) работу: kill-a-job перечёркивает
    /// узел на графе, не удаляя его (v13); «Вернуть работу» из
    /// контекстного меню снимает крестик. То же состояние — no-op.
    case setKilled(UUID, Bool)
    /// Вставить работы из буфера обмена: id работ и областей свежие,
    /// связи между скопированными работами сохраняются. `atLevel` —
    /// уровень для верхней скопированной работы (уровень под курсором);
    /// работы ниже ложатся настолько же ниже, недостающие уровни
    /// создаются. nil — копия возвращается на свои уровни (по id
    /// в том же графе, по номеру — в чужом). Пустой буфер — no-op.
    case paste(JobClipboard, atLevel: Int?)
}

public enum ReorderDirection: Equatable, Sendable {
    case left, right
}

/// Результат применения интента: новый граф + узел для фокуса (если есть).
public struct GraphResult: Equatable, Sendable {
    public let graph: WorkGraph
    public let focus: UUID?
}

public enum GraphEngine {
    /// Чистая функция: intent + граф → новый граф. nil = no-op
    /// (границы reorder, удаление непустого уровня и т.п.) — вызывающий
    /// не должен регистрировать undo для nil.
    public static func apply(_ intent: GraphIntent, to graph: WorkGraph) -> GraphResult? {
        switch intent {
        case let .insertLevel(at: index):
            guard index >= 0, index <= graph.levels.count else { return nil }
            var copy = graph
            copy.levels.insert(GraphLevel(), at: index)
            return GraphResult(graph: copy, focus: nil)

        case let .deleteLevel(id):
            guard graph.levels.count > 1,
                  let index = graph.levelIndex(id: id),
                  graph.levels[index].jobs.isEmpty,
                  !graph.levels[index].isCore
            else { return nil }
            var copy = graph
            copy.levels.remove(at: index)
            return GraphResult(graph: copy, focus: nil)

        case let .addJob(level: levelID, zone: zoneID, at: position):
            guard let index = graph.levelIndex(id: levelID) else { return nil }
            // Область чужого уровня игнорируется — работа уходит в основную.
            let zone = zoneID.flatMap { graph.levels[index].zone($0)?.id }
            let job = JobNode(verb: "", zoneID: zone)
            var copy = graph
            let insertAt = copy.levels[index].insertionIndex(zone: zone, at: position)
            copy.levels[index].jobs.insert(job, at: insertAt)
            return GraphResult(graph: copy, focus: job.id)

        case let .addConnectedRight(of: sourceID):
            guard let levelIndex = graph.levelIndex(of: sourceID),
                  let source = graph.job(sourceID)
            else { return nil }
            // Связанная работа — сосед по области: продолжение той же
            // последовательности, а не переход в другую область.
            let job = JobNode(verb: "", zoneID: source.zoneID)
            var copy = graph
            let jobs = copy.levels[levelIndex].jobs
            let sourceIndex = jobs.firstIndex { $0.id == sourceID }
            let insertAt = (sourceIndex.map { $0 + 1 }) ?? jobs.count
            // Свёрнутая цепочка разворачивается: иначе новая работа
            // сразу оказалась бы скрытой — жест выглядел бы как no-op.
            if let sourceIndex {
                copy.levels[levelIndex].jobs[sourceIndex].isCollapsed = false
            }
            copy.levels[levelIndex].jobs.insert(job, at: insertAt)
            copy.edges.append(JobEdge(from: sourceID, to: job.id))
            return GraphResult(graph: copy, focus: job.id)

        case let .addConnectedBelow(of: sourceID):
            guard let levelIndex = graph.levelIndex(of: sourceID) else { return nil }
            var copy = graph
            let below = levelIndex + 1
            if below == copy.levels.count {
                copy.levels.append(GraphLevel())
            }
            // Уровень ниже — другая полоса, области не наследуются.
            let job = JobNode(verb: "")
            let insertAt = copy.levels[below].insertionIndex(zone: nil, at: .max)
            copy.levels[below].jobs.insert(job, at: insertAt)
            copy.edges.append(JobEdge(from: sourceID, to: job.id))
            return GraphResult(graph: copy, focus: job.id)

        case let .reorder(id, direction):
            guard let levelIndex = graph.levelIndex(of: id),
                  let job = graph.job(id)
            else { return nil }
            // Соседи ищутся внутри области: сдвиг не выкидывает работу
            // из своей рамки.
            let group = Array(graph.levels[levelIndex].jobs.indices)
                .filter { graph.levels[levelIndex].jobs[$0].zoneID == job.zoneID }
            guard let position = group.firstIndex(where: {
                graph.levels[levelIndex].jobs[$0].id == id
            }) else { return nil }
            let target = direction == .left ? position - 1 : position + 1
            guard target >= 0, target < group.count else { return nil }
            var copy = graph
            copy.levels[levelIndex].jobs.swapAt(group[position], group[target])
            return GraphResult(graph: copy, focus: id)

        case let .move(id, toLevel, zone: zoneID, at: insertAt):
            guard toLevel >= 0, toLevel < graph.levels.count,
                  let fromLevel = graph.levelIndex(of: id),
                  let jobIndex = graph.levels[fromLevel].jobs.firstIndex(where: { $0.id == id })
            else { return nil }
            var copy = graph
            var job = copy.levels[fromLevel].jobs.remove(at: jobIndex)
            // Область чужого уровня игнорируется — работа уходит в основную.
            job.zoneID = zoneID.flatMap { copy.levels[toLevel].zone($0)?.id }
            let clamped = copy.levels[toLevel].insertionIndex(zone: job.zoneID, at: insertAt)
            copy.levels[toLevel].jobs.insert(job, at: clamped)
            // Перенос на другой уровень переворачивает связи работы
            // относительно уровней — направление приводится обратно.
            copy.normalizeEdges()
            guard copy != graph else { return nil }
            return GraphResult(graph: copy, focus: id)

        case let .delete(id):
            guard let levelIndex = graph.levelIndex(of: id) else { return nil }
            var copy = graph
            let focus = graph.sources(of: id).first
            copy.levels[levelIndex].jobs.removeAll { $0.id == id }
            copy.edges.removeAll { $0.from == id || $0.to == id }
            return GraphResult(graph: copy, focus: focus)

        case let .toggleEdge(from: fromID, to: toID):
            guard fromID != toID,
                  graph.job(fromID) != nil,
                  graph.job(toID) != nil
            else { return nil }
            var copy = graph
            let existing = copy.edges.filter {
                ($0.from == fromID && $0.to == toID) || ($0.from == toID && $0.to == fromID)
            }
            if existing.isEmpty {
                copy.edges.append(JobEdge(from: fromID, to: toID))
                // Связь тянут в любую сторону — межуровневая приводится
                // к «сверху вниз», иначе обходы по исходящим связям
                // (подсветка декомпозиции, свёртка) её не увидят.
                copy.normalizeEdges()
            } else {
                copy.edges.removeAll { edge in existing.contains(edge) }
            }
            return GraphResult(graph: copy, focus: toID)

        case let .setText(id, raw):
            guard let job = graph.job(id) else { return nil }
            let (role, verb) = RoleParser.parse(raw)
            if verb.isEmpty {
                // Пустой commit только что созданного (пустого) узла — узел исчезает.
                if job.verb.isEmpty { return apply(.delete(id), to: graph) }
                return nil // пустой commit существующего узла — revert, не мутация
            }
            guard job.verb != verb || job.role != role else { return nil }
            var copy = graph
            for levelIndex in copy.levels.indices {
                for jobIndex in copy.levels[levelIndex].jobs.indices
                where copy.levels[levelIndex].jobs[jobIndex].id == id {
                    copy.levels[levelIndex].jobs[jobIndex].verb = verb
                    copy.levels[levelIndex].jobs[jobIndex].role = role
                }
            }
            return GraphResult(graph: copy, focus: id)

        case let .setKilled(id, killed):
            guard let job = graph.job(id), job.killed != killed else { return nil }
            var copy = graph
            for levelIndex in copy.levels.indices {
                for jobIndex in copy.levels[levelIndex].jobs.indices
                where copy.levels[levelIndex].jobs[jobIndex].id == id {
                    copy.levels[levelIndex].jobs[jobIndex].killed = killed
                }
            }
            return GraphResult(graph: copy, focus: id)

        case let .setDetails(id, details):
            let normalized = details.normalized()
            guard let job = graph.job(id), job.details != normalized else { return nil }
            var copy = graph
            for levelIndex in copy.levels.indices {
                for jobIndex in copy.levels[levelIndex].jobs.indices
                where copy.levels[levelIndex].jobs[jobIndex].id == id {
                    copy.levels[levelIndex].jobs[jobIndex].details = normalized
                }
            }
            return GraphResult(graph: copy, focus: id)

        case let .renameLevel(id, name):
            guard let index = graph.levelIndex(id: id) else { return nil }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let newName = trimmed.isEmpty ? nil : trimmed
            guard graph.levels[index].name != newName else { return nil }
            var copy = graph
            copy.levels[index].name = newName
            return GraphResult(graph: copy, focus: nil)

        case let .setCoreLevel(id):
            guard let index = graph.levelIndex(id: id),
                  !graph.levels[index].isCore
            else { return nil }
            var copy = graph
            for levelIndex in copy.levels.indices {
                copy.levels[levelIndex].isCore = copy.levels[levelIndex].id == id
            }
            // Прежний core перестал быть кóровым — его области снимаются
            // (работы остаются на уровне, как при deleteZone).
            copy.normalizeZones()
            return GraphResult(graph: copy, focus: nil)

        case let .addZone(level: levelID):
            // Область — разметка «работы того же уровня, которые продукт
            // не выполняет»; она имеет смысл только рядом с кóровыми.
            guard let index = graph.levelIndex(id: levelID),
                  graph.levels[index].isCore
            else { return nil }
            let zone = LevelZone()
            // Пустая рамка бесполезна — область появляется сразу
            // с работой в режиме редактирования.
            let job = JobNode(verb: "", zoneID: zone.id)
            var copy = graph
            copy.levels[index].zones.append(zone)
            copy.levels[index].jobs.append(job)
            return GraphResult(graph: copy, focus: job.id)

        case let .renameZone(id, name):
            guard let levelIndex = graph.levelIndex(zone: id),
                  let zoneIndex = graph.levels[levelIndex].zones.firstIndex(where: { $0.id == id })
            else { return nil }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let newName = trimmed.isEmpty ? nil : trimmed
            guard graph.levels[levelIndex].zones[zoneIndex].name != newName else { return nil }
            var copy = graph
            copy.levels[levelIndex].zones[zoneIndex].name = newName
            return GraphResult(graph: copy, focus: nil)

        case let .deleteZone(id):
            guard let levelIndex = graph.levelIndex(zone: id) else { return nil }
            var copy = graph
            copy.levels[levelIndex].zones.removeAll { $0.id == id }
            // normalizeZones вернёт осиротевшие работы в основную область
            // и восстановит порядок.
            copy.levels[levelIndex].normalizeZones()
            return GraphResult(graph: copy, focus: nil)

        case let .setJobZone(id, zone: zoneID):
            guard let levelIndex = graph.levelIndex(of: id),
                  let jobIndex = graph.levels[levelIndex].jobs.firstIndex(where: { $0.id == id })
            else { return nil }
            // Область только своего уровня; та же область — no-op.
            let target = zoneID.flatMap { graph.levels[levelIndex].zone($0)?.id }
            guard zoneID == nil || target != nil,
                  graph.levels[levelIndex].jobs[jobIndex].zoneID != target
            else { return nil }
            var copy = graph
            copy.levels[levelIndex].jobs[jobIndex].zoneID = target
            copy.levels[levelIndex].normalizeZones()
            return GraphResult(graph: copy, focus: id)

        case let .setCollapsed(id, collapsed):
            guard let levelIndex = graph.levelIndex(of: id),
                  let jobIndex = graph.levels[levelIndex].jobs.firstIndex(where: { $0.id == id }),
                  graph.levels[levelIndex].jobs[jobIndex].isCollapsed != collapsed
            else { return nil }
            // Сворачивать нечего — цепочки справа нет.
            guard !collapsed || !graph.chain(after: id).isEmpty else { return nil }
            var copy = graph
            copy.levels[levelIndex].jobs[jobIndex].isCollapsed = collapsed
            return GraphResult(graph: copy, focus: id)

        case let .paste(clipboard, atLevel: anchor):
            return paste(clipboard, at: anchor, into: graph)
        }
    }

    /// Вставка копии работ. `anchor` — уровень для верхней скопированной
    /// работы (полоса под курсором): вставка ложится туда, куда смотрит
    /// пользователь, сохраняя расстояния между уровнями копии. Без якоря
    /// уровень-приёмник ищется по id (вставка в тот же граф — работы
    /// возвращаются на свои полосы), затем по номеру уровня. Уровней
    /// не хватает — дописываются снизу, иначе копия схлопнулась бы
    /// в один уровень.
    ///
    /// Область восстанавливается по id (та же полоса) или создаётся заново
    /// на core-уровне; на прочих уровнях областей не бывает, и работа
    /// уходит в основную.
    private static func paste(
        _ clipboard: JobClipboard,
        at anchor: Int?,
        into graph: WorkGraph
    ) -> GraphResult? {
        guard !clipboard.isEmpty else { return nil }
        let levels = clipboard.levels.sorted { $0.index < $1.index }
        // Верх копии: от него считаются смещения остальных уровней.
        guard let topIndex = levels.first?.index else { return nil }
        var copy = graph
        var idMap: [UUID: UUID] = [:]
        var focus: UUID?

        for level in levels {
            let targetIndex: Int
            if let anchor {
                targetIndex = max(anchor, 0) + (level.index - topIndex)
            } else if let existing = copy.levelIndex(id: level.id) {
                targetIndex = existing
            } else {
                targetIndex = level.index
            }
            while copy.levels.count <= targetIndex {
                copy.levels.append(GraphLevel())
            }

            var zoneMap: [UUID: UUID] = [:]
            for zone in level.zones {
                if copy.levels[targetIndex].zone(zone.id) != nil {
                    zoneMap[zone.id] = zone.id
                } else if copy.levels[targetIndex].isCore {
                    let newZone = LevelZone(name: zone.name)
                    copy.levels[targetIndex].zones.append(newZone)
                    zoneMap[zone.id] = newZone.id
                }
            }

            for job in level.jobs {
                var pasted = job
                pasted.id = UUID()
                pasted.zoneID = job.zoneID.flatMap { zoneMap[$0] }
                idMap[job.id] = pasted.id
                let insertAt = copy.levels[targetIndex].insertionIndex(zone: pasted.zoneID, at: .max)
                copy.levels[targetIndex].jobs.insert(pasted, at: insertAt)
                // Фокус — на первую работу верхнего скопированного уровня:
                // это голова вставленной цепочки.
                if focus == nil { focus = pasted.id }
            }
        }

        for edge in clipboard.edges {
            guard let from = idMap[edge.from], let to = idMap[edge.to] else { continue }
            copy.edges.append(JobEdge(from: from, to: to))
        }
        // Копия могла лечь на уровни в другом порядке (вставка в чужой
        // граф) — направление межуровневых связей приводится к «сверху вниз».
        copy.normalizeEdges()
        return GraphResult(graph: copy, focus: focus)
    }
}
