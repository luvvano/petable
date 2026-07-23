import Foundation
import Testing
@testable import GraphCore

@Suite("Сегментация")
struct SegmentationTests {
    private func sampleSegment() -> Segment {
        Segment(
            name: "Молодые профессионалы SF",
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            coreJobs: [
                SegmentCoreJob(
                    statement: "хочу доехать от ресторана до двери дома",
                    successCriteria: [
                        SegmentListItem(text: "безопасно — до двери, не «за квартал»"),
                        SegmentListItem(text: "машина за 5 минут"),
                        SegmentListItem(text: "до $25 с сурджем"),
                    ]
                )
            ],
            priority: .noStressFirst,
            causalCriteria: [SegmentListItem(text: "нет своей машины, живёт один")],
            qualificationQuestions: [SegmentListItem(text: "время или деньги важнее?")],
            economics: SegmentEconomics(
                addedValue: SegmentEconomicsAnswer(rating: .strong, evidence: "готовы платить +30% за Comfort"),
                targetMargin: SegmentEconomicsAnswer(rating: .medium, evidence: "маржа тарифа выше X"),
                demand: SegmentEconomicsAnswer(rating: .strong, evidence: "3 поездки в месяц"),
                scale: SegmentEconomicsAnswer(rating: .medium, evidence: "~800$/год на работу"),
                hardBlocker: ""
            ),
            verdict: .focus,
            notes: "Uber Comfort, пример из канона"
        )
    }

    @Test("1. Encode/decode round-trip сегмента в конверте v6")
    func roundTrip() throws {
        let envelope = Envelope(
            stages: [Envelope.Stage(graph: Fixtures.closeMonth())],
            segmentation: Segmentation(segments: [sampleSegment()])
        )
        let decoded = try Envelope.decode(try envelope.encoded())
        #expect(decoded == envelope)
        #expect(decoded.version == Envelope.currentVersion)
        let segment = try #require(decoded.segmentation?.segments.first)
        #expect(segment.coreJobs.first?.successCriteria.count == 3)
        #expect(segment.priority == .noStressFirst)
        #expect(segment.verdict == .focus)
        #expect(segment.economics.addedValue.rating == .strong)
    }

    @Test("2. Файл v5 без секции сегментов читается: segmentation == nil, запись в v6")
    func v5WithoutSegmentationDecodes() throws {
        let graphJSON = try JSONEncoder().encode(Fixtures.closeMonth())
        let json = #"""
        {"version": 5, "stages": [{"id": "\#(UUID().uuidString)", "type": "jobGraph", "name": "Граф", "graph": \#(String(data: graphJSON, encoding: .utf8)!)}]}
        """#
        let decoded = try Envelope.decode(json.data(using: .utf8)!)
        #expect(decoded.segmentation == nil)
        #expect(decoded.version == Envelope.currentVersion)
        // Round-trip после чтения: секция не появляется из ниоткуда.
        let rewritten = try Envelope.decode(try decoded.encoded())
        #expect(rewritten.segmentation == nil)
    }

    @Test("3. Происхождение: без поля — человек, у агента — агент")
    func originResolution() {
        #expect(Segment(name: "С").resolvedOrigin == .human)
        #expect(Segment(name: "С", origin: .agent).resolvedOrigin == .agent)
    }

    @Test("4. Пустой сегмент кодируется и восстанавливается с дефолтами")
    func emptySegmentRoundTrip() throws {
        let envelope = Envelope(
            stages: [Envelope.Stage(graph: Fixtures.closeMonth())],
            segmentation: Segmentation(segments: [Segment(name: "Пустой")])
        )
        let decoded = try Envelope.decode(try envelope.encoded())
        let segment = try #require(decoded.segmentation?.segments.first)
        #expect(segment.coreJobs.isEmpty)
        #expect(segment.priority == nil)
        #expect(segment.verdict == nil)
        #expect(segment.economics == SegmentEconomics())
        #expect(segment.economics.hardBlocker.isEmpty)
    }
}
