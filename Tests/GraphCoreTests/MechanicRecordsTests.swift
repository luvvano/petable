import Foundation
import Testing
@testable import GraphCore

@Suite("Якорь и записи механик в конверте")
struct MechanicRecordsTests {
    // MARK: - Плоский Codable якоря (P1c)

    private func roundTrip(_ anchor: MechanicAnchor) throws -> MechanicAnchor {
        let data = try JSONEncoder().encode(anchor)
        return try JSONDecoder().decode(MechanicAnchor.self, from: data)
    }

    @Test("1. Round-trip всех четырёх видов якоря")
    func anchorRoundTrip() throws {
        let node = UUID()
        let from = UUID()
        let to = UUID()
        let zone = UUID()
        #expect(try roundTrip(.node(node)) == .node(node))
        #expect(try roundTrip(.chainEdge(from: from, to: to)) == .chainEdge(from: from, to: to))
        #expect(try roundTrip(.zone(zone)) == .zone(zone))
        #expect(try roundTrip(.unanchored) == .unanchored)
    }

    @Test("2. В JSON — плоская форма {kind, ids}, читаемая глазами")
    func anchorFlatShape() throws {
        let id = UUID()
        let data = try JSONEncoder().encode(MechanicAnchor.node(id))
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        #expect(object["kind"] as? String == "node")
        #expect((object["ids"] as? [String])?.count == 1)
    }

    @Test("3. Незнакомый kind из будущей сборки → .unanchored, не бросок")
    func unknownKindDegrades() throws {
        // Главный тест P1c: enum с ассоциированными значениями здесь бы
        // бросил и завалил чтение всего документа.
        let json = #"{"kind": "crossLevelPair", "ids": ["\#(UUID().uuidString)"]}"#
        let anchor = try JSONDecoder().decode(MechanicAnchor.self, from: Data(json.utf8))
        #expect(anchor == .unanchored)
    }

    @Test("4. Неверное число ids (файл правили руками) → .unanchored")
    func wrongIDCountDegrades() throws {
        let json = #"{"kind": "chainEdge", "ids": ["\#(UUID().uuidString)"]}"#
        let anchor = try JSONDecoder().decode(MechanicAnchor.self, from: Data(json.utf8))
        #expect(anchor == .unanchored)
    }

    @Test("5. Пустой объект → .unanchored")
    func emptyObjectDegrades() throws {
        let anchor = try JSONDecoder().decode(MechanicAnchor.self, from: Data("{}".utf8))
        #expect(anchor == .unanchored)
    }

    // MARK: - Envelope v11

    @Test("6. Файл v10 читается: стикеры пустые, происхождения нет")
    func v10Reads() throws {
        let graph = Fixtures.closeMonth()
        var envelope = Envelope(graph: graph)
        envelope.version = 10
        // Кодируем как v10 руками: у Stage v10 не было stickers/mechanicOrigin,
        // но encodeIfPresent их и не запишет — достаточно подменить версию.
        let data = try JSONSerialization.data(
            withJSONObject: {
                var object = try! JSONSerialization.jsonObject(
                    with: try! envelope.encoded()
                ) as! [String: Any]
                object["version"] = 10
                return object
            }()
        )
        let decoded = try Envelope.decode(data)
        let stage = try #require(decoded.stages.first)
        #expect(stage.stickers.isEmpty)
        #expect(stage.mechanicOrigin == nil)
        #expect(decoded.version == Envelope.currentVersion)
    }

    @Test("7. v11 round-trip: стикер и происхождение переживают запись и чтение")
    func v11RoundTrip() throws {
        let graph = Fixtures.closeMonth()
        let jobID = try #require(graph.levels.last?.jobs.first?.id)
        let sticker = MechanicSticker(
            slug: "lower-the-price",
            anchor: .node(jobID),
            note: "подписка вместо покупки",
            createdAt: Date(timeIntervalSince1970: 1_000_000)
        )
        let origin = MechanicOrigin(
            slug: "kill-a-job",
            anchor: .node(jobID),
            anchorLabels: ["бухгалтер: хочу выгрузить банковскую выписку"],
            appliedAt: Date(timeIntervalSince1970: 2_000_000)
        )
        let stage = Envelope.Stage(stickers: [sticker], mechanicOrigin: origin, graph: graph)
        let envelope = Envelope(stages: [stage])

        let decoded = try Envelope.decode(try envelope.encoded())
        let read = try #require(decoded.stages.first)
        #expect(read.stickers == [sticker])
        #expect(read.mechanicOrigin == origin)
    }

    @Test("8. Пустые стикеры не пишутся в JSON")
    func emptyStickersOmitted() throws {
        let envelope = Envelope(graph: Fixtures.closeMonth())
        let json = String(decoding: try envelope.encoded(), as: UTF8.self)
        #expect(!json.contains("\"stickers\""))
    }

    // MARK: - Происхождение

    @Test("9. capture снимает тексты якорных работ ДО применения")
    func captureLabels() {
        let job = JobNode(verb: "распутать наушники", role: "слушатель")
        var graph = WorkGraph(levels: [GraphLevel(jobs: [job], isCore: true)])
        graph.ensureCoreLevel()
        let origin = MechanicOrigin.capture(slug: "kill-a-job", anchor: .node(job.id), in: graph)
        #expect(origin.anchorLabels == ["слушатель: распутать наушники"])
    }

    @Test("10. capture для области берёт имя рамки")
    func captureZoneLabel() {
        let zone = LevelZone()
        let job = JobNode(verb: "в зоне", zoneID: zone.id)
        var graph = WorkGraph(levels: [
            GraphLevel(jobs: [JobNode(verb: "кор"), job], isCore: true, zones: [zone])
        ])
        graph.ensureCoreLevel()
        let origin = MechanicOrigin.capture(
            slug: "more-jobs-one-solution", anchor: .zone(zone.id), in: graph
        )
        #expect(origin.anchorLabels == [LevelZone.defaultName])
    }
}
