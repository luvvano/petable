import Foundation
import Testing
@testable import GraphCore

@Suite("Производительность")
struct PerfTests {
    @Test("Layout 150 узлов < 16ms (бюджет кадра)")
    func layoutBudget() {
        let graph = Fixtures.synthetic(count: 150)
        _ = GraphLayout.layout(graph) // прогрев

        let clock = ContinuousClock()
        var best = Duration.seconds(1)
        for _ in 0..<5 {
            let elapsed = clock.measure { _ = GraphLayout.layout(graph) }
            best = min(best, elapsed)
        }
        #expect(best < .milliseconds(16), "layout 150 узлов занял \(best)")
    }

    @Test("Призрак на каждое ↑/↓: preview + union + layout 150 узлов < 16ms")
    func ghostBudget() {
        // Скрабинг по палитре пересчитывает призрак на каждое нажатие:
        // трансформация, union и раскладка обязаны влезать в кадр.
        // Оговорка из плана: тест меряет ядро; пересборку тела
        // CanvasRootView он не покрывает.
        let graph = Fixtures.synthetic(count: 150)
        let anchor = graph.levels.first { !$0.jobs.isEmpty }!.jobs[0].id

        func ghostPass() {
            guard case let .success(preview) = MechanicTransform.preview(
                "kill-a-job", in: graph, anchor: .node(anchor)
            ) else { return }
            let overlay = MechanicGhost.overlay(current: graph, preview: preview)
            _ = GraphLayout.layout(overlay.union)
            _ = graph.delta(to: preview)
        }
        ghostPass() // прогрев

        let clock = ContinuousClock()
        var best = Duration.seconds(1)
        for _ in 0..<5 {
            let elapsed = clock.measure { ghostPass() }
            best = min(best, elapsed)
        }
        #expect(best < .milliseconds(16), "призрак на 150 узлах занял \(best)")
    }
}
