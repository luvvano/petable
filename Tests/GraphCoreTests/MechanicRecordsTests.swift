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

    // MARK: - Envelope v12: тред и подписи якоря у стикера

    @Test("11. v12 round-trip: тред и подписи якоря переживают запись и чтение")
    func v12RoundTrip() throws {
        let graph = Fixtures.closeMonth()
        let jobID = try #require(graph.levels.last?.jobs.first?.id)
        let sticker = MechanicSticker(
            slug: "kill-a-job",
            anchor: .node(jobID),
            note: "гипотеза: шаг лишний",
            messages: [
                StickerMessage(text: "проверить на интервью", createdAt: Date(timeIntervalSince1970: 3_000_000))
            ],
            anchorLabels: ["бухгалтер: хочу выгрузить банковскую выписку"],
            createdAt: Date(timeIntervalSince1970: 1_000_000)
        )
        let stage = Envelope.Stage(stickers: [sticker], graph: graph)
        let decoded = try Envelope.decode(try Envelope(stages: [stage]).encoded())
        let read = try #require(decoded.stages.first)
        #expect(read.stickers == [sticker])
    }

    @Test("12. Стикер v11 (без messages и anchorLabels) читается пустыми")
    func v11StickerReads() throws {
        let json = #"""
        {"id": "\#(UUID().uuidString)", "slug": "lower-the-price",
         "anchor": {"kind": "unanchored", "ids": []},
         "note": "", "createdAt": 700000000}
        """#
        let sticker = try JSONDecoder().decode(MechanicSticker.self, from: Data(json.utf8))
        #expect(sticker.messages.isEmpty)
        #expect(sticker.anchorLabels.isEmpty)
    }

    @Test("13. Пустые тред и подписи не пишутся в JSON")
    func emptyThreadOmitted() throws {
        let sticker = MechanicSticker(slug: "bundle", anchor: .unanchored)
        let json = String(decoding: try JSONEncoder().encode(sticker), as: UTF8.self)
        #expect(!json.contains("\"messages\""))
        #expect(!json.contains("\"anchorLabels\""))
    }

    // MARK: - Envelope v13: убитая работа

    @Test("15. v13: killed переживает round-trip, старый JSON читается живым")
    func killedRoundTrip() throws {
        var job = JobNode(verb: "распутать наушники")
        job.killed = true
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(JobNode.self, from: data)
        #expect(decoded.killed)

        // Файл до v13 — ключа killed нет: работа живая.
        let legacy = #"{"id": "\#(UUID().uuidString)", "verb": "старая"}"#
        let read = try JSONDecoder().decode(JobNode.self, from: Data(legacy.utf8))
        #expect(!read.killed)

        // Живая работа не пишет killed в JSON — файлы не растут.
        let alive = JobNode(verb: "живая")
        let json = String(decoding: try JSONEncoder().encode(alive), as: UTF8.self)
        #expect(!json.contains("\"killed\""))
    }

    @Test("16. Интент setKilled: пометка, снятие, no-op на том же состоянии")
    func setKilledIntent() {
        let job = JobNode(verb: "лишний шаг")
        var graph = WorkGraph(levels: [GraphLevel(jobs: [job], isCore: true)])
        graph.ensureCoreLevel()

        let killed = GraphEngine.apply(.setKilled(job.id, true), to: graph)
        #expect(killed?.graph.job(job.id)?.killed == true)
        // То же состояние — no-op (undo не регистрируется).
        #expect(GraphEngine.apply(.setKilled(job.id, true), to: killed!.graph) == nil)

        let revived = GraphEngine.apply(.setKilled(job.id, false), to: killed!.graph)
        #expect(revived?.graph.job(job.id)?.killed == false)
    }

    @Test("14. MechanicSticker.capture снимает тексты якорных работ ДО применения")
    func stickerCaptureLabels() {
        let job = JobNode(verb: "распутать наушники", role: "слушатель")
        var graph = WorkGraph(levels: [GraphLevel(jobs: [job], isCore: true)])
        graph.ensureCoreLevel()
        let record = MechanicSticker.capture(
            slug: "kill-a-job", anchor: .node(job.id), note: "лишний шаг", in: graph
        )
        #expect(record.anchorLabels == ["слушатель: распутать наушники"])
        #expect(record.note == "лишний шаг")
    }
}
