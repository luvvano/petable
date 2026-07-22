import Foundation
import Testing
@testable import GraphCore

@Suite("Производительность")
struct PerfTests {
    @Test("14. Layout 150 узлов < 16ms (бюджет кадра)")
    func layoutBudget() {
        let root = Fixtures.synthetic(count: 150)
        _ = GraphLayout.layout(root) // прогрев

        let clock = ContinuousClock()
        var best = Duration.seconds(1)
        for _ in 0..<5 {
            let elapsed = clock.measure { _ = GraphLayout.layout(root) }
            best = min(best, elapsed)
        }
        #expect(best < .milliseconds(16), "layout 150 узлов занял \(best)")
    }
}
