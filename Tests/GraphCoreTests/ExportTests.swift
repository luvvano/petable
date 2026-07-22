import Foundation
import Testing
@testable import GraphCore

@Suite("Экспорт и импорт: интервью и граф работ")
struct ExportTests {
    @Test("1. JSON интервью: round-trip через файл экспорта")
    func interviewJSONRoundTrip() throws {
        let template = InterviewTemplate.oneOffJob()
        var interview = Interview(name: "Разговор с Кайей", template: template)
        let solutionField = try #require(
            template.sections.flatMap(\.fields).first { $0.fillsPlaceholder == InterviewTemplate.solutionKey }
        )
        interview.setAnswer("Kayak", for: solutionField.id)

        let data = try InterviewExport.json(interview)
        let decoded = try InterviewExportFile.decode(data)
        #expect(decoded.type == InterviewExportFile.fileType)
        #expect(decoded.version == InterviewExportFile.currentVersion)
        #expect(decoded.interview.name == interview.name)
        #expect(decoded.interview.answers == interview.answers)
        #expect(decoded.interview.placeholderValues == interview.placeholderValues)
        #expect(decoded.interview.template == interview.template)
    }

    @Test("2. Markdown интервью: вопросы с подставленными плейсхолдерами и ответы")
    func interviewMarkdown() throws {
        let template = InterviewTemplate(name: "Мини", sections: [
            InterviewTemplate.Section(title: "Секция А", fields: [
                InterviewTemplate.Field(
                    title: "Решение",
                    question: "Каким решением вы пользовались?",
                    fillsPlaceholder: InterviewTemplate.solutionKey
                ),
                InterviewTemplate.Field(
                    title: "Контекст",
                    question: "В какой ситуации вы использовали {решение}?"
                ),
                InterviewTemplate.Field(title: "Пусто", question: "Вопрос без ответа?"),
            ]),
        ])
        var interview = Interview(name: "Интервью 1", template: template)
        let solutionField = template.sections[0].fields[0]
        interview.setAnswer("Kayak", for: solutionField.id)
        interview.setAnswer("Летел в отпуск\nвторая строка", for: template.sections[0].fields[1].id)

        let markdown = InterviewExport.markdown(interview)
        #expect(markdown.contains("# Интервью 1"))
        #expect(markdown.contains("- Шаблон: Мини"))
        #expect(markdown.contains("## Секция А"))
        #expect(markdown.contains("### Контекст"))
        // Плейсхолдер подставлен в вопрос и виден в панели плейсхолдеров.
        #expect(markdown.contains("В какой ситуации вы использовали Kayak?"))
        #expect(markdown.contains("- `{решение}` — Kayak"))
        // Многострочный ответ — цитата построчно; пустой — заглушка.
        #expect(markdown.contains("> Летел в отпуск"))
        #expect(markdown.contains("> вторая строка"))
        #expect(markdown.contains("_Нет ответа._"))
    }

    @Test("3. JSON графа: round-trip с именем и структурой")
    func workGraphRoundTrip() throws {
        let graph = Fixtures.closeMonth()
        let data = try WorkGraphExportFile(name: "Закрыть месяц", graph: graph).encoded()
        let decoded = try WorkGraphExportFile.decode(data)
        #expect(decoded.name == "Закрыть месяц")
        #expect(decoded.graph == graph)
    }

    @Test("4. Импорт отклоняет чужой тип и более новую версию")
    func decodeRejectsWrongFiles() throws {
        var wrongType = WorkGraphExportFile(name: "x", graph: WorkGraph())
        wrongType.type = "petable.interview"
        let wrongTypeData = try ExportCoding.makeEncoder().encode(wrongType)
        #expect(throws: ExportFileError.wrongType(
            found: "petable.interview", expected: WorkGraphExportFile.fileType
        )) {
            try WorkGraphExportFile.decode(wrongTypeData)
        }

        var newer = WorkGraphExportFile(name: "x", graph: WorkGraph())
        newer.version = WorkGraphExportFile.currentVersion + 1
        let newerData = try ExportCoding.makeEncoder().encode(newer)
        #expect(throws: ExportFileError.unsupportedVersion(
            found: WorkGraphExportFile.currentVersion + 1,
            supported: WorkGraphExportFile.currentVersion
        )) {
            try WorkGraphExportFile.decode(newerData)
        }

        #expect(throws: Error.self) {
            try WorkGraphExportFile.decode(Data("{\"foo\": 1}".utf8))
        }
    }

    @Test("5. withRegeneratedIDs: структура та же, id новые, рёбра переписаны")
    func regeneratedIDs() throws {
        let graph = Fixtures.closeMonth()
        let copy = graph.withRegeneratedIDs()

        // Структура и содержимое сохранены.
        #expect(copy.levels.count == graph.levels.count)
        #expect(copy.allJobs.map(\.verb) == graph.allJobs.map(\.verb))
        #expect(copy.allJobs.map(\.role) == graph.allJobs.map(\.role))
        #expect(copy.edges.count == graph.edges.count)

        // Все id свежие.
        let oldIDs = Set(graph.allJobs.map(\.id))
        #expect(oldIDs.isDisjoint(with: Set(copy.allJobs.map(\.id))))

        // Рёбра указывают на те же работы по смыслу (сверка по глаголам).
        func verb(_ id: UUID, in graph: WorkGraph) -> String? { graph.job(id)?.verb }
        let oldPairs = Set(graph.edges.map { "\(verb($0.from, in: graph) ?? "?")→\(verb($0.to, in: graph) ?? "?")" })
        let newPairs = Set(copy.edges.map { "\(verb($0.from, in: copy) ?? "?")→\(verb($0.to, in: copy) ?? "?")" })
        #expect(oldPairs == newPairs)
    }

    @Test("6. withRegeneratedIDs отбрасывает рёбра на несуществующие узлы")
    func regeneratedIDsDropsBrokenEdges() {
        var graph = Fixtures.closeMonth()
        graph.edges.append(JobEdge(from: UUID(), to: UUID()))
        let copy = graph.withRegeneratedIDs()
        #expect(copy.edges.count == graph.edges.count - 1)
    }
}
