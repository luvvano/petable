import Foundation
import Testing
@testable import GraphCore

@Suite("Исследования: шаблоны, интервью, плейсхолдеры")
struct ResearchTests {
    @Test("1. Извлечение ключей плейсхолдеров: порядок, дубли, мусор")
    func placeholderKeys() {
        #expect(InterviewPlaceholders.keys(in: "Зачем вам {ожидаемый результат} от {решение}?")
            == ["ожидаемый результат", "решение"])
        #expect(InterviewPlaceholders.keys(in: "{a} и снова {a}") == ["a"])
        #expect(InterviewPlaceholders.keys(in: "без плейсхолдеров") == [])
        #expect(InterviewPlaceholders.keys(in: "пустой {} игнорируется") == [])
    }

    @Test("2. Подстановка: заполненные ключи заменяются, пустые остаются видимыми")
    func substitution() {
        let text = "Что вы ожидали от {решение}, чтобы получить {ожидаемый результат}?"
        let partial = InterviewPlaceholders.substitute(text, values: ["решение": "Kayak"])
        #expect(partial == "Что вы ожидали от Kayak, чтобы получить {ожидаемый результат}?")
        let empty = InterviewPlaceholders.substitute(text, values: ["решение": ""])
        #expect(empty == text)
    }

    @Test("3. Ответ поля с fillsPlaceholder распространяется на остальные вопросы")
    func answerFeedsPlaceholder() throws {
        let template = InterviewTemplate.oneOffJob()
        var interview = Interview(name: "Тест", template: template)

        let solutionField = try #require(
            template.sections.flatMap(\.fields).first { $0.fillsPlaceholder == InterviewTemplate.solutionKey }
        )
        interview.setAnswer("Kayak", for: solutionField.id)
        #expect(interview.placeholderValues[InterviewTemplate.solutionKey] == "Kayak")

        let contextField = try #require(
            template.sections.flatMap(\.fields).first { $0.title == "Контекст" }
        )
        #expect(interview.resolvedQuestion(for: contextField).contains("Kayak"))
        #expect(!interview.resolvedQuestion(for: contextField).contains("{решение}"))

        // Очистка ответа убирает значение — ключ снова виден в вопросах.
        interview.setAnswer("  ", for: solutionField.id)
        #expect(interview.placeholderValues[InterviewTemplate.solutionKey] == nil)
        #expect(interview.resolvedQuestion(for: contextField).contains("{решение}"))
    }

    @Test("4. Дефолтные шаблоны: каждый fillsPlaceholder-ключ встречается в вопросах")
    func defaultTemplatesConsistent() {
        for template in InterviewTemplate.defaultTemplates() {
            let keys = Set(template.placeholderKeys)
            let feeding = template.sections.flatMap(\.fields).compactMap(\.fillsPlaceholder)
            #expect(!feeding.isEmpty)
            for key in feeding {
                #expect(keys.contains(key), "ключ \(key) не используется в вопросах «\(template.name)»")
            }
        }
        // Шаблоны не делят id секций и полей.
        let one = InterviewTemplate.oneOffJob()
        let recurring = InterviewTemplate.recurringJob()
        let oneIDs = Set(one.sections.flatMap(\.fields).map(\.id) + one.sections.map(\.id))
        let recurringIDs = Set(recurring.sections.flatMap(\.fields).map(\.id) + recurring.sections.map(\.id))
        #expect(oneIDs.isDisjoint(with: recurringIDs))
    }

    @Test("5. Envelope v4: research переживает round-trip")
    func envelopeRoundTrip() throws {
        let template = InterviewTemplate.oneOffJob()
        var interview = Interview(
            name: "Респондент 1",
            template: template,
            createdAt: Date(timeIntervalSinceReferenceDate: 700_000_000)
        )
        let field = template.sections.flatMap(\.fields)[0]
        interview.setAnswer("роль, сегмент, платил 3 раза", for: field.id)

        let envelope = Envelope(
            stages: [Envelope.Stage(graph: Fixtures.closeMonth())],
            research: Research(templates: [template], interviews: [interview])
        )
        let decoded = try Envelope.decode(try envelope.encoded())
        #expect(decoded == envelope)
        #expect(decoded.research?.interviews.first?.answers[field.id] == "роль, сегмент, платил 3 раза")
        #expect(decoded.version == Envelope.currentVersion)
    }

    @Test("6. Файл v3 без research читается: research == nil")
    func v3FileReadsWithoutResearch() throws {
        let graphJSON = try String(data: JSONEncoder().encode(Fixtures.closeMonth()), encoding: .utf8)!
        let json = #"{"version": 3, "stages": [{"type": "jobGraph", "name": "Граф", "graph": \#(graphJSON)}]}"#
        let decoded = try Envelope.decode(json.data(using: .utf8)!)
        #expect(decoded.research == nil)
        #expect(decoded.version == Envelope.currentVersion)
    }
}
