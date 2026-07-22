import Foundation
@testable import GraphCore

enum Fixtures {
    /// Референс-пример «Закрыть месяц» в legacy-формате дерева (v1) —
    /// используется и для теста миграции, и как источник WorkGraph.
    static func closeMonthTree() -> Job {
        Job(
            verb: "Закрыть месяц без ошибок",
            children: [
                Job(verb: "хочу иметь актуальные транзакции в системе", role: "бухгалтер"),
                Job(
                    verb: "хочу категоризировать транзакции", role: "бухгалтер",
                    children: [
                        Job(verb: "хочу выгрузить банковскую выписку", role: "бухгалтер"),
                        Job(verb: "хочу применить правила категорий", role: "бухгалтер"),
                        Job(verb: "хочу разобрать неопознанные", role: "бухгалтер"),
                    ]
                ),
                Job(verb: "хочу сверить отчёты", role: "контролёр"),
                Job(verb: "хочу утвердить закрытие месяца", role: "финдиректор"),
                Job(verb: "хочу загрузить данные в ERP", role: "бухгалтер"),
            ]
        )
    }

    /// Тот же пример как WorkGraph: 3 уровня (1 + 5 + 3), рёбра parent→child.
    static func closeMonth() -> WorkGraph {
        WorkGraph(tree: closeMonthTree())
    }

    /// Синтетический граф заданного размера: 5 уровней, цепочки связей,
    /// детерминированный. Для стресс-тестов.
    static func synthetic(count: Int) -> WorkGraph {
        var levels = (0..<5).map { _ in GraphLevel() }
        var edges: [JobEdge] = []
        var previous: JobNode?
        for index in 0..<count {
            let node = JobNode(verb: "узел \(index)", role: index % 2 == 0 ? "роль" : nil)
            levels[index % 5].jobs.append(node)
            if let previous, index % 7 != 0 {
                edges.append(JobEdge(from: previous.id, to: node.id))
            }
            previous = node
        }
        return WorkGraph(levels: levels, edges: edges)
    }
}
