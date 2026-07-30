import Foundation
import Testing
@testable import GraphCore

@Suite("Редактор флоу: вставка/удаление этапов с перешивкой рёбер")
struct FlowEditingTests {
    private func linearFlow() -> OrgFlow {
        let merge = OrgStage(name: "Merge", kind: .merge, gate: .human)
        let review = OrgStage(name: "Ревью", kind: .review, next: [merge.id])
        let work = OrgStage(name: "Разработка", kind: .work, next: [review.id])
        return OrgFlow(name: "f", stages: [work, review, merge])
    }

    @Test("Вставка после этапа: новый наследует исходящие рёбра")
    func insertAfter() {
        var flow = linearFlow()
        let work = flow.stages[0]
        let review = flow.stages[1]
        let tests = OrgStage(name: "Тесты", kind: .test)

        flow.insertStage(tests, after: work.id)

        #expect(flow.stages.map(\.name) == ["Разработка", "Тесты", "Ревью", "Merge"])
        #expect(flow.stage(work.id)?.next == [tests.id])
        #expect(flow.stage(tests.id)?.next == [review.id])
        #expect(flow.startStage?.id == work.id)
    }

    @Test("Вставка в начало (after: nil): новый этап становится стартовым")
    func insertAtStart() {
        var flow = linearFlow()
        let oldStart = flow.stages[0]
        let decompose = OrgStage(name: "Декомпозиция", kind: .decompose)

        flow.insertStage(decompose, after: nil)

        #expect(flow.startStage?.id == decompose.id)
        #expect(flow.stage(decompose.id)?.next == [oldStart.id])
    }

    @Test("Удаление серединного этапа: предшественник наследует его рёбра")
    func removeMiddle() {
        var flow = linearFlow()
        let work = flow.stages[0]
        let review = flow.stages[1]
        let merge = flow.stages[2]

        flow.removeStage(review.id)

        #expect(flow.stages.map(\.name) == ["Разработка", "Merge"])
        #expect(flow.stage(work.id)?.next == [merge.id])
        #expect(flow.validate().contains(.missingEmployee(stage: work.id)))
    }

    @Test("Удаление стартового этапа: следующий становится стартом")
    func removeStart() {
        var flow = linearFlow()
        let work = flow.stages[0]
        let review = flow.stages[1]

        flow.removeStage(work.id)

        #expect(flow.startStage?.id == review.id)
    }

    @Test("Удаление несуществующего id — no-op")
    func removeMissing() {
        var flow = linearFlow()
        let before = flow
        flow.removeStage(UUID())
        #expect(flow == before)
    }
}
