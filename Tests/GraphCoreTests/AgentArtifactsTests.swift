import Foundation
import Testing
@testable import GraphCore

@Suite("Артефакты ИИ-агента")
struct AgentArtifactsTests {
    private func samplePayloadJSON(fieldID: UUID) -> String {
        """
        Вот результат исследования:
        {
          "interviewName": "Kayak: семейные перелёты",
          "placeholders": {"решение": "Kayak", "ожидаемый результат": "купить билеты"},
          "answers": [{"fieldID": "\(fieldID.uuidString)", "answer": "Купить билеты туда-обратно до $1800"}],
          "graph": {
            "name": "Kayak: граф работ",
            "levels": [
              [{"verb": "устроить семье отличные каникулы", "role": "родитель"}],
              [{"verb": "купить авиабилеты"}, {"verb": "забронировать отель"}]
            ],
            "edges": [
              {"fromLevel": 0, "fromIndex": 0, "toLevel": 1, "toIndex": 0},
              {"fromLevel": 0, "fromIndex": 0, "toLevel": 1, "toIndex": 1},
              {"fromLevel": 5, "fromIndex": 9, "toLevel": 0, "toIndex": 0}
            ]
          }
        }
        Конец.
        """
    }

    @Test("1. JSON извлекается из прозы и парсится; кривые рёбра отбрасываются")
    func parseAndBuildGraph() throws {
        let template = InterviewTemplate.oneOffJob()
        let fieldID = template.sections.flatMap(\.fields)[0].id
        let payload = try AgentArtifactsPayload.parse(from: samplePayloadJSON(fieldID: fieldID))

        #expect(payload.interviewName == "Kayak: семейные перелёты")

        let graph = payload.makeWorkGraph()
        #expect(graph.levels.count == 2)
        #expect(graph.levels[0].jobs[0].role == "родитель")
        #expect(graph.levels[1].jobs.count == 2)
        // Ребро с несуществующими индексами отброшено, валидные два остались.
        #expect(graph.edges.count == 2)
        #expect(graph.targets(of: graph.levels[0].jobs[0].id).count == 2)
    }

    @Test("2. makeInterview: ответы по валидным id, плейсхолдеры, origin == .agent")
    func makeInterview() throws {
        let template = InterviewTemplate.oneOffJob()
        let fieldID = template.sections.flatMap(\.fields)[0].id
        let payload = try AgentArtifactsPayload.parse(from: samplePayloadJSON(fieldID: fieldID))

        let interview = payload.makeInterview(template: template)
        #expect(interview.resolvedOrigin == .agent)
        #expect(interview.answers[fieldID] == "Купить билеты туда-обратно до $1800")
        #expect(interview.placeholderValues["решение"] == "Kayak")
        // Ответ на чужой fieldID не попадает в интервью.
        let foreign = AgentArtifactsPayload(
            interviewName: "x",
            answers: [.init(fieldID: UUID(), answer: "мусор")],
            graph: .init(name: "g", levels: [[.init(verb: "v")]])
        )
        #expect(foreign.makeInterview(template: template).answers.isEmpty)
    }

    @Test("3. Текст без JSON и пустой граф — понятные ошибки")
    func parseErrors() {
        #expect(throws: AgentArtifactsPayload.ParseError.noJSONFound) {
            try AgentArtifactsPayload.parse(from: "никакого джейсона тут нет")
        }
        let empty = """
        {"interviewName": "x", "placeholders": {}, "answers": [],
         "graph": {"name": "g", "levels": [[]], "edges": []}}
        """
        #expect(throws: AgentArtifactsPayload.ParseError.emptyGraph) {
            try AgentArtifactsPayload.parse(from: empty)
        }
    }

    @Test("4. Скобки внутри строк не ломают извлечение JSON")
    func bracesInsideStrings() throws {
        let text = #"префикс {"a": "тут { скобка и \" кавычка", "b": {"c": 1}} суффикс"#
        let json = try #require(AgentArtifactsPayload.firstJSONObject(in: text))
        #expect(json.hasSuffix("}}"))
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(object?["a"] as? String == "тут { скобка и \" кавычка")
    }

    @Test("5. origin стадии и интервью переживает round-trip конверта")
    func originRoundTrip() throws {
        var interview = Interview(
            name: "Агентское",
            template: InterviewTemplate.oneOffJob(),
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            origin: .agent
        )
        interview.modifiedAt = nil
        let envelope = Envelope(
            stages: [
                Envelope.Stage(name: "Ручной", graph: Fixtures.closeMonth()),
                Envelope.Stage(name: "Агентский", origin: .agent, graph: Fixtures.closeMonth()),
            ],
            research: Research(templates: [], interviews: [interview])
        )
        let decoded = try Envelope.decode(try envelope.encoded())
        #expect(decoded == envelope)
        #expect(decoded.stages[0].resolvedOrigin == .human)
        #expect(decoded.stages[1].resolvedOrigin == .agent)
        #expect(decoded.research?.interviews[0].resolvedOrigin == .agent)
    }
}
