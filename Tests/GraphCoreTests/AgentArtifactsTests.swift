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

    @Test("4. coreLevel из payload помечает уровень; без него и при кривом индексе core — верхний")
    func coreLevelMapping() throws {
        let withCore = AgentArtifactsPayload.Graph(
            name: "g",
            levels: [[.init(verb: "большая работа")], [.init(verb: "кóровая работа")]],
            coreLevel: 1
        )
        #expect(withCore.makeWorkGraph().levels.map(\.isCore) == [false, true])

        let without = AgentArtifactsPayload.Graph(
            name: "g",
            levels: [[.init(verb: "работа")], [.init(verb: "ещё работа")]]
        )
        #expect(without.makeWorkGraph().levels.map(\.isCore) == [true, false])

        let outOfRange = AgentArtifactsPayload.Graph(
            name: "g",
            levels: [[.init(verb: "работа")]],
            coreLevel: 7
        )
        #expect(outOfRange.makeWorkGraph().levels.map(\.isCore) == [true])
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

    @Test("6. JobCard.merged: nil не трогает, значение перезаписывает, пусто — чистит")
    func jobCardMerge() {
        let details = JobDetails(
            context: ["на ходу"],
            trigger: ["старый триггер"],
            positiveEmotions: ["спокойствие"],
            frequency: "5 раз/год"
        )
        let card = AgentArtifactsPayload.JobCard(
            trigger: ["гость сказал «да»", "  "],
            positiveEmotions: [],
            frequency: "20 раз/мес"
        )
        let merged = card.merged(into: details)
        #expect(merged.context == ["на ходу"]) // nil — поле не тронуто
        #expect(merged.trigger == ["гость сказал «да»"]) // перезапись + trim пустых
        #expect(merged.positiveEmotions == []) // пустой список — очистка
        #expect(merged.frequency == "20 раз/мес")
        #expect(AgentArtifactsPayload.JobCard().isEmpty)
        #expect(!card.isEmpty)
    }

    @Test("7. update_graph сохраняет карточки, id и имена уровней по совпадению узлов")
    func preservingWorkGraphKeepsCards() {
        let filled = JobNode(
            verb: "выпить кофе",
            role: "гость",
            details: JobDetails(trigger: ["утро"], frequency: "1 раз/день")
        )
        let doomed = JobNode(verb: "мыть турку")
        let old = WorkGraph(
            levels: [GraphLevel(jobs: [filled, doomed], name: "Кóровые")],
            edges: [JobEdge(from: filled.id, to: doomed.id)]
        )
        // Агент переставил узел на новый уровень и убрал «мыть турку».
        let transport = AgentArtifactsPayload.Graph(
            name: "",
            levels: [
                [.init(verb: "взбодриться")],
                [.init(verb: "выпить кофе", role: "гость")],
            ],
            edges: [.init(fromLevel: 0, fromIndex: 0, toLevel: 1, toIndex: 0)]
        )
        let rebuilt = transport.makeWorkGraph(preservingFrom: old)
        let survivor = rebuilt.levels[1].jobs[0]
        #expect(survivor.id == filled.id)
        #expect(survivor.details == filled.details)
        #expect(rebuilt.levels[0].jobs[0].details.isEmpty) // новый узел — пустая карточка
        #expect(rebuilt.levels[0].name == "Кóровые") // имя уровня по индексу
        #expect(rebuilt.edges == [JobEdge(from: rebuilt.levels[0].jobs[0].id, to: filled.id)])
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
