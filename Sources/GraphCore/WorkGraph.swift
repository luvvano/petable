import Foundation

/// Узел графа работ: «role: хочу + глагол». Позиция узла задаётся
/// принадлежностью уровню (GraphLevel) и порядком в массиве jobs.
public struct JobNode: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var verb: String
    public var role: String?

    public init(id: UUID = UUID(), verb: String, role: String? = nil) {
        self.id = id
        self.verb = verb
        self.role = role
    }

    /// Комбинированная строка для инлайн-редактора: `role: verb` или `verb`.
    public var displayText: String {
        if let role { return "\(role): \(verb)" }
        return verb
    }
}

/// Уровень графа — горизонтальная полоса. Порядок `jobs` = слева направо.
public struct GraphLevel: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var jobs: [JobNode]

    public init(id: UUID = UUID(), jobs: [JobNode] = []) {
        self.id = id
        self.jobs = jobs
    }
}

/// Направленная связь между работами: `from` → `to`.
/// Связь либо внутри уровня (следующая работа справа), либо на уровень
/// ниже (декомпозиция). Тип не хранится — выводится из уровней узлов.
public struct JobEdge: Codable, Equatable, Hashable, Sendable {
    public var from: UUID
    public var to: UUID

    public init(from: UUID, to: UUID) {
        self.from = from
        self.to = to
    }
}

/// Граф работ: упорядоченные уровни (сверху вниз, 0 = самый верхний)
/// плюс рёбра. Не дерево: работа может быть автономной (без рёбер)
/// или иметь несколько связей.
public struct WorkGraph: Codable, Equatable, Sendable {
    public var levels: [GraphLevel]
    public var edges: [JobEdge]

    public init(levels: [GraphLevel] = [], edges: [JobEdge] = []) {
        self.levels = levels
        self.edges = edges
    }
}

// MARK: - Запросы

public extension WorkGraph {
    var allJobs: [JobNode] { levels.flatMap(\.jobs) }

    var jobCount: Int { levels.reduce(0) { $0 + $1.jobs.count } }

    func job(_ id: UUID) -> JobNode? {
        for level in levels {
            if let job = level.jobs.first(where: { $0.id == id }) { return job }
        }
        return nil
    }

    /// Индекс уровня, на котором лежит работа. nil, если работы нет.
    func levelIndex(of jobID: UUID) -> Int? {
        levels.firstIndex { $0.jobs.contains { $0.id == jobID } }
    }

    func levelIndex(id levelID: UUID) -> Int? {
        levels.firstIndex { $0.id == levelID }
    }

    /// Входящие связи работы (родители/предшественники).
    func sources(of jobID: UUID) -> [UUID] {
        edges.filter { $0.to == jobID }.map(\.from)
    }

    /// Исходящие связи работы.
    func targets(of jobID: UUID) -> [UUID] {
        edges.filter { $0.from == jobID }.map(\.to)
    }
}

// MARK: - Миграция из формата v1 (дерево Job)

public extension WorkGraph {
    /// Разворачивает дерево v1 в уровни: глубина узла → индекс уровня,
    /// pre-order обход задаёт порядок слева направо, связи parent → child.
    init(tree: Job) {
        var levels: [[JobNode]] = []
        var edges: [JobEdge] = []

        func walk(_ node: Job, depth: Int) {
            if levels.count <= depth { levels.append([]) }
            levels[depth].append(JobNode(id: node.id, verb: node.verb, role: node.role))
            for child in node.children {
                edges.append(JobEdge(from: node.id, to: child.id))
                walk(child, depth: depth + 1)
            }
        }
        walk(tree, depth: 0)

        self.init(levels: levels.map { GraphLevel(jobs: $0) }, edges: edges)
    }
}
