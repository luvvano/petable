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
    /// Удалить уровень. Только пустой и не единственный — иначе no-op.
    case deleteLevel(UUID)
    /// Автономная работа: добавляется в конец уровня, ни с чем не связана.
    case addJob(level: UUID)
    /// Связанная работа справа на том же уровне + ребро от исходной.
    case addConnectedRight(of: UUID)
    /// Связанная работа на уровне ниже + ребро от исходной.
    /// Если исходная на нижнем уровне — уровень создаётся.
    case addConnectedBelow(of: UUID)
    /// Сдвиг работы влево/вправо внутри уровня.
    case reorder(UUID, direction: ReorderDirection)
    /// Удаляет работу и все её связи. Уровень остаётся, даже пустой.
    case delete(UUID)
    /// Связь между существующими работами: есть (в любом направлении) —
    /// удалить, нет — создать from → to. Петля from == to — no-op.
    case toggleEdge(from: UUID, to: UUID)
    /// Разбирает `raw` грамматикой role:. Пустая строка на только что
    /// созданном (пустом) узле — удаление, на существующем — no-op.
    case setText(UUID, raw: String)
    /// Имя уровня. Пустая строка (после trim) — сброс к дефолту «УРОВЕНЬ N».
    case renameLevel(UUID, name: String)
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
                  graph.levels[index].jobs.isEmpty
            else { return nil }
            var copy = graph
            copy.levels.remove(at: index)
            return GraphResult(graph: copy, focus: nil)

        case let .addJob(level: levelID):
            guard let index = graph.levelIndex(id: levelID) else { return nil }
            let job = JobNode(verb: "")
            var copy = graph
            copy.levels[index].jobs.append(job)
            return GraphResult(graph: copy, focus: job.id)

        case let .addConnectedRight(of: sourceID):
            guard let levelIndex = graph.levelIndex(of: sourceID) else { return nil }
            let job = JobNode(verb: "")
            var copy = graph
            let jobs = copy.levels[levelIndex].jobs
            let insertAt = (jobs.firstIndex { $0.id == sourceID }.map { $0 + 1 }) ?? jobs.count
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
            let job = JobNode(verb: "")
            copy.levels[below].jobs.append(job)
            copy.edges.append(JobEdge(from: sourceID, to: job.id))
            return GraphResult(graph: copy, focus: job.id)

        case let .reorder(id, direction):
            guard let levelIndex = graph.levelIndex(of: id),
                  let index = graph.levels[levelIndex].jobs.firstIndex(where: { $0.id == id })
            else { return nil }
            let target = direction == .left ? index - 1 : index + 1
            guard target >= 0, target < graph.levels[levelIndex].jobs.count else { return nil }
            var copy = graph
            copy.levels[levelIndex].jobs.swapAt(index, target)
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

        case let .renameLevel(id, name):
            guard let index = graph.levelIndex(id: id) else { return nil }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let newName = trimmed.isEmpty ? nil : trimmed
            guard graph.levels[index].name != newName else { return nil }
            var copy = graph
            copy.levels[index].name = newName
            return GraphResult(graph: copy, focus: nil)
        }
    }
}
