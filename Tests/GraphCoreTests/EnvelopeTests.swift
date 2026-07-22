import Foundation
import Testing
@testable import GraphCore

@Suite("Конверт документа")
struct EnvelopeTests {
    @Test("1. Encode/decode round-trip: уровни, рёбра, роли, UUID стабильны")
    func roundTrip() throws {
        let envelope = Envelope(graph: Fixtures.closeMonth())
        let data = try envelope.encoded()
        let decoded = try Envelope.decode(data)
        #expect(decoded == envelope)
        #expect(decoded.jobGraph?.levels.map(\.id) == envelope.jobGraph?.levels.map(\.id))
        #expect(decoded.jobGraph?.edges == envelope.jobGraph?.edges)
        #expect(decoded.version == Envelope.currentVersion)
    }

    @Test("2. Версия больше текущей → понятная ошибка, не порча")
    func futureVersionFails() throws {
        let json = #"{"version": 99, "stages": []}"#.data(using: .utf8)!
        #expect(throws: Envelope.EnvelopeError.unsupportedVersion(found: 99, supported: Envelope.currentVersion)) {
            try Envelope.decode(json)
        }
    }

    @Test("2а. Legacy v1 (дерево Job) читается и мигрирует в WorkGraph")
    func legacyV1Migrates() throws {
        let tree = Fixtures.closeMonthTree()
        let legacyJSON = try JSONEncoder().encode(LegacyEnvelope(
            version: 1,
            stages: [.init(type: "jobGraph", graph: tree)]
        ))
        let decoded = try Envelope.decode(legacyJSON)
        let graph = try #require(decoded.jobGraph)
        #expect(decoded.version == Envelope.currentVersion)
        #expect(graph.levels.count == 3)
        #expect(graph.levels[0].jobs.map(\.id) == [tree.id])
        #expect(graph.levels[1].jobs.count == 5)
        #expect(graph.levels[2].jobs.count == 3)
        // Рёбра parent → child сохранены.
        #expect(graph.sources(of: tree.children[0].id) == [tree.id])
        #expect(graph.sources(of: tree.children[1].children[2].id) == [tree.children[1].id])
    }

    @Test("3. v2 (стадия без id/name) читается: имя по умолчанию, запись в v3")
    func v2StageGetsDefaults() throws {
        let graph = Fixtures.closeMonth()
        let graphJSON = try JSONEncoder().encode(graph)
        let json = #"{"version": 2, "stages": [{"type": "jobGraph", "graph": \#(String(data: graphJSON, encoding: .utf8)!)}]}"#
        let decoded = try Envelope.decode(json.data(using: .utf8)!)
        #expect(decoded.version == Envelope.currentVersion)
        #expect(decoded.stages.count == 1)
        #expect(decoded.stages[0].name == Envelope.defaultGraphName)
        #expect(decoded.jobGraph == graph)
    }

    @Test("4. Несколько графов: id, имена и порядок стадий переживают round-trip")
    func multiGraphRoundTrip() throws {
        let envelope = Envelope(stages: [
            Envelope.Stage(name: "Закрытие месяца", graph: Fixtures.closeMonth()),
            Envelope.Stage(name: "Онбординг", graph: WorkGraph(levels: [GraphLevel(jobs: [JobNode(verb: "нанять")])])),
        ])
        let decoded = try Envelope.decode(try envelope.encoded())
        #expect(decoded == envelope)
        #expect(decoded.stages.map(\.id) == envelope.stages.map(\.id))
        #expect(decoded.stages.map(\.name) == ["Закрытие месяца", "Онбординг"])
        #expect(decoded.jobGraphStages.count == 2)
    }

    private struct LegacyEnvelope: Codable {
        var version: Int
        var stages: [Stage]
        struct Stage: Codable {
            var type: String
            var graph: Job
        }
    }
}
