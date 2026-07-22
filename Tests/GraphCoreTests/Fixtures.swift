import Foundation
@testable import GraphCore

enum Fixtures {
    /// Референс-пример из дизайн-дока: 3 уровня, 9 узлов.
    static func closeMonth() -> Job {
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

    /// Синтетическое дерево заданного размера для стресс-тестов:
    /// ветвление 5, детерминированное.
    static func synthetic(count: Int) -> Job {
        var remaining = count - 1
        func build(level: Int) -> [Job] {
            var children: [Job] = []
            while remaining > 0 && children.count < 5 {
                remaining -= 1
                var node = Job(verb: "узел \(remaining)", role: level % 2 == 0 ? "роль" : nil)
                if level < 4 {
                    node.children = build(level: level + 1)
                }
                children.append(node)
            }
            return children
        }
        return Job(verb: "корень", children: build(level: 1))
    }
}
