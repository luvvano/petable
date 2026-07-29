import Foundation

/// Пример-граф для превью механики в нижней панели палитры: маленький
/// канонический граф работ и якорь, на котором механика гарантированно
/// применяется. Живёт в ядре, а не во вьюхе: применимость каждого
/// примера проверяется юнит-тестом без запуска UI.
public enum MechanicExample {
    public struct Sample: Sendable {
        public var graph: WorkGraph
        public var anchor: MechanicAnchor

        public init(graph: WorkGraph, anchor: MechanicAnchor) {
            self.graph = graph
            self.anchor = anchor
        }
    }

    /// Пример под механику: якорь выбран так, чтобы топологическая или
    /// карточная трансформация гарантированно применялась.
    public static func sample(for slug: String) -> Sample {
        switch slug {
        case "more-jobs-one-solution", "take-job-off-customer":
            let parts = baseParts()
            return Sample(graph: parts.graph, anchor: .node(parts.zoneJobID))
        case "reduce-hand-offs":
            // Стык «бухгалтер → аудитор»: роли разные — передача есть.
            let parts = baseParts()
            return Sample(
                graph: parts.graph,
                anchor: .chainEdge(from: parts.verifyID, to: parts.approveID)
            )
        case "fix-chain-breaks-between-people", "fix-unperformed-jobs-in-chain":
            let parts = baseParts()
            return Sample(
                graph: parts.graph,
                anchor: .chainEdge(from: parts.collectID, to: parts.verifyID)
            )
        case "kill-cycles":
            // Петля «подтвердить → собрать заново»: обратное ребро цикла.
            var parts = baseParts()
            parts.graph.edges.append(JobEdge(from: parts.approveID, to: parts.collectID))
            return Sample(graph: parts.graph, anchor: .node(parts.collectID))
        default:
            // kill-a-job, карточные и стикерные целятся в среднюю работу.
            let parts = baseParts()
            return Sample(graph: parts.graph, anchor: .node(parts.verifyID))
        }
    }

    private struct Parts {
        var graph: WorkGraph
        var collectID: UUID
        var verifyID: UUID
        var approveID: UUID
        var zoneJobID: UUID
    }

    /// Канонический пример: большая работа «закрыть месяц», цепочка
    /// кóровых работ двух ролей и область «вне продукта» с одной работой.
    private static func baseParts() -> Parts {
        var details = JobDetails()
        details.negativeEmotions = ["боюсь ошибиться в цифрах"]
        details.successCriteria = ["баланс сходится с первого раза"]
        details.inOrderTo = ["сдать отчётность вовремя"]

        let big = JobNode(verb: "закрыть месяц без авралов")
        let collect = JobNode(verb: "хочу собрать транзакции", role: "бухгалтер")
        let verify = JobNode(verb: "хочу сверить остатки", role: "бухгалтер", details: details)
        let approve = JobNode(verb: "хочу подтвердить отчёт", role: "аудитор")
        let zone = LevelZone(name: "вне продукта")
        let pay = JobNode(verb: "хочу оплатить пошлину", zoneID: zone.id)

        let graph = WorkGraph(
            levels: [
                GraphLevel(jobs: [big]),
                GraphLevel(jobs: [collect, verify, approve, pay], isCore: true, zones: [zone]),
            ],
            edges: [
                JobEdge(from: big.id, to: collect.id),
                JobEdge(from: collect.id, to: verify.id),
                JobEdge(from: verify.id, to: approve.id),
                JobEdge(from: approve.id, to: pay.id),
            ]
        )
        return Parts(
            graph: graph,
            collectID: collect.id,
            verifyID: verify.id,
            approveID: approve.id,
            zoneJobID: pay.id
        )
    }
}
