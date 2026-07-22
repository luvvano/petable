import Foundation
import Testing
@testable import GraphCore

@Suite("Конверт документа")
struct EnvelopeTests {
    @Test("1. Encode/decode round-trip: роли, порядок детей, UUID стабильны")
    func roundTrip() throws {
        let envelope = Envelope(graph: Fixtures.closeMonth())
        let data = try envelope.encoded()
        let decoded = try Envelope.decode(data)
        #expect(decoded == envelope)
        #expect(decoded.jobGraph?.children.map(\.id) == envelope.jobGraph?.children.map(\.id))
        #expect(decoded.jobGraph?.children[1].children.count == 3)
        #expect(decoded.version == Envelope.currentVersion)
    }

    @Test("2. Версия больше текущей → понятная ошибка, не порча")
    func futureVersionFails() throws {
        let json = #"{"version": 99, "stages": []}"#.data(using: .utf8)!
        #expect(throws: Envelope.EnvelopeError.unsupportedVersion(found: 99, supported: 1)) {
            try Envelope.decode(json)
        }
    }

    @Test("2а. Версия 1 открывается штатно")
    func currentVersionDecodes() throws {
        let data = try Envelope(graph: Job(verb: "x")).encoded()
        #expect(try Envelope.decode(data).jobGraph?.verb == "x")
    }
}
