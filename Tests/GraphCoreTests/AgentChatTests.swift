import XCTest
@testable import GraphCore

final class AgentChatTests: XCTestCase {
    // MARK: - Разбор ответа

    func testParsePlainTextHasNoActions() {
        let reply = AgentChatReply.parse(from: "Работа — единица мотивации, не проблема.")
        XCTAssertEqual(reply.text, "Работа — единица мотивации, не проблема.")
        XCTAssertTrue(reply.actions.isEmpty)
        XCTAssertEqual(reply.invalidActionCount, 0)
    }

    func testParseCreateGraphActionAndStripsBlock() {
        let raw = """
        Создаю граф.
        ```petable-action
        {"action": "create_graph", "graph": {"name": "Кофе", "levels": [[{"verb": "взбодриться"}], [{"verb": "выпить кофе", "role": "гость"}]], "edges": [{"fromLevel": 0, "fromIndex": 0, "toLevel": 1, "toIndex": 0}]}}
        ```
        Готово.
        """
        let reply = AgentChatReply.parse(from: raw)
        XCTAssertEqual(reply.text, "Создаю граф.\n\nГотово.")
        XCTAssertEqual(reply.invalidActionCount, 0)
        guard case .createGraph(let graph) = reply.actions.first else {
            return XCTFail("Ожидалась команда create_graph, получено: \(reply.actions)")
        }
        XCTAssertEqual(graph.name, "Кофе")
        XCTAssertEqual(graph.levels.count, 2)
        XCTAssertEqual(graph.levels[1][0].role, "гость")
        XCTAssertEqual(graph.edges, [.init(fromLevel: 0, fromIndex: 0, toLevel: 1, toIndex: 0)])
    }

    func testParseMultipleActions() {
        let graphID = UUID()
        let interviewID = UUID()
        let fieldID = UUID()
        let raw = """
        ```petable-action
        {"action": "update_graph", "graphID": "\(graphID.uuidString)", "graph": {"name": "", "levels": [[{"verb": "жить"}]], "edges": []}}
        ```
        и правлю интервью:
        ```petable-action
        {"action": "update_interview", "interviewID": "\(interviewID.uuidString)", "placeholders": {"решение": "Kayak"}, "answers": [{"fieldID": "\(fieldID.uuidString)", "answer": "за 4 минуты"}]}
        ```
        """
        let reply = AgentChatReply.parse(from: raw)
        XCTAssertEqual(reply.actions.count, 2)
        XCTAssertEqual(reply.text, "и правлю интервью:")
        guard case .updateGraph(let id, let graph) = reply.actions[0] else {
            return XCTFail("Ожидалась update_graph")
        }
        XCTAssertEqual(id, graphID)
        XCTAssertEqual(graph.levels, [[.init(verb: "жить")]])
        guard case .updateInterview(let iid, let placeholders, let answers) = reply.actions[1] else {
            return XCTFail("Ожидалась update_interview")
        }
        XCTAssertEqual(iid, interviewID)
        XCTAssertEqual(placeholders, ["решение": "Kayak"])
        XCTAssertEqual(answers, [.init(fieldID: fieldID, answer: "за 4 минуты")])
    }

    func testParseCreateInterviewAction() {
        let templateID = UUID()
        let raw = """
        ```petable-action
        {"action": "create_interview", "templateID": "\(templateID.uuidString)", "interviewName": "Гипотеза: Kayak", "placeholders": {}, "answers": []}
        ```
        """
        let reply = AgentChatReply.parse(from: raw)
        guard case .createInterview(let tid, let name, _, _) = reply.actions.first else {
            return XCTFail("Ожидалась create_interview")
        }
        XCTAssertEqual(tid, templateID)
        XCTAssertEqual(name, "Гипотеза: Kayak")
    }

    func testParseUpdateJobAction() {
        let graphID = UUID()
        let raw = """
        ```petable-action
        {"action": "update_job", "graphID": "\(graphID.uuidString)", "level": 1, "index": 2, "card": {"trigger": ["гость сказал «да»"], "successCriteria": ["внести за 1 минуту"], "frequency": "20 раз/мес"}}
        ```
        """
        let reply = AgentChatReply.parse(from: raw)
        XCTAssertEqual(reply.invalidActionCount, 0)
        guard case .updateJob(let id, let level, let index, let card) = reply.actions.first else {
            return XCTFail("Ожидалась update_job, получено: \(reply.actions)")
        }
        XCTAssertEqual(id, graphID)
        XCTAssertEqual(level, 1)
        XCTAssertEqual(index, 2)
        XCTAssertEqual(card.trigger, ["гость сказал «да»"])
        XCTAssertEqual(card.successCriteria, ["внести за 1 минуту"])
        XCTAssertEqual(card.frequency, "20 раз/мес")
        // Не перечисленные поля не трогаются (nil, не пустой список).
        XCTAssertNil(card.context)
        XCTAssertNil(card.inOrderTo)
    }

    func testParseUpdateJobWithEmptyCardInvalid() {
        let raw = """
        ```petable-action
        {"action": "update_job", "graphID": "\(UUID().uuidString)", "level": 0, "index": 0, "card": {}}
        ```
        """
        let reply = AgentChatReply.parse(from: raw)
        XCTAssertTrue(reply.actions.isEmpty)
        XCTAssertEqual(reply.invalidActionCount, 1)
    }

    func testInvalidBlocksCountedNotFatal() {
        let raw = """
        До.
        ```petable-action
        {"action": "explode_project"}
        ```
        ```petable-action
        это вообще не JSON
        ```
        После.
        """
        let reply = AgentChatReply.parse(from: raw)
        XCTAssertTrue(reply.actions.isEmpty)
        XCTAssertEqual(reply.invalidActionCount, 2)
        XCTAssertEqual(reply.text, "До.\n\n\nПосле.")
    }

    func testUnclosedFenceStillParsed() {
        let raw = """
        Хвост:
        ```petable-action
        {"action": "create_graph", "graph": {"name": "Х", "levels": [[{"verb": "жить"}]], "edges": []}}
        """
        let reply = AgentChatReply.parse(from: raw)
        XCTAssertEqual(reply.actions.count, 1)
        XCTAssertEqual(reply.text, "Хвост:")
    }

    // MARK: - Контекст проекта

    func testContextDescribesGraphTemplatesInterviews() {
        let jobA = JobNode(verb: "взбодриться")
        let jobB = JobNode(verb: "выпить кофе", role: "гость")
        let stage = Envelope.Stage(
            name: "Кофе",
            graph: WorkGraph(
                levels: [GraphLevel(jobs: [jobA]), GraphLevel(jobs: [jobB])],
                edges: [JobEdge(from: jobA.id, to: jobB.id)]
            )
        )
        let field = InterviewTemplate.Field(title: "Триггер", question: "Что случилось?")
        let template = InterviewTemplate(
            name: "Шаблон",
            sections: [.init(title: "С", fields: [field])]
        )
        var interview = Interview(name: "Интервью 1", template: template)
        interview.setAnswer("сломалась кофемашина", for: field.id)

        let context = AgentChatContext.describe(
            graphs: [stage],
            research: Research(templates: [template], interviews: [interview]),
            segments: []
        )
        XCTAssertTrue(context.contains("graphID \(stage.id.uuidString) «Кофе»"))
        XCTAssertTrue(context.contains("уровень 1: [0] «гость: выпить кофе»"))
        XCTAssertTrue(context.contains("рёбра: 0.0→1.0"))
        XCTAssertTrue(context.contains("templateID \(template.id.uuidString)"))
        XCTAssertTrue(context.contains("fieldID \(field.id.uuidString): «Триггер»"))
        XCTAssertTrue(context.contains("(«Триггер»): сломалась кофемашина"))
    }

    func testContextIncludesJobCards() {
        let plain = JobNode(verb: "взбодриться")
        let filled = JobNode(
            verb: "внести бронь",
            details: JobDetails(
                trigger: ["гость сказал «да»"],
                successCriteria: ["за 1 минуту", "ничего не потерялось"],
                frequency: "20 раз/мес"
            )
        )
        let stage = Envelope.Stage(
            name: "Брони",
            graph: WorkGraph(levels: [GraphLevel(jobs: [plain, filled])])
        )
        let context = AgentChatContext.describe(
            graphs: [stage],
            research: Research(),
            segments: []
        )
        XCTAssertTrue(context.contains("карточка 0.1: триггер: гость сказал «да» | критерии успеха: за 1 минуту; ничего не потерялось | частота: 20 раз/мес"))
        // Пустая карточка не засоряет контекст.
        XCTAssertFalse(context.contains("карточка 0.0"))
    }
}
