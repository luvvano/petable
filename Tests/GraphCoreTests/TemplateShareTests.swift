import Foundation
import Testing
@testable import GraphCore

@Suite("Экспорт и импорт шаблона интервью")
struct TemplateShareTests {
    @Test("1. Encode/decode round-trip: секции, поля, плейсхолдеры целы")
    func roundTrip() throws {
        let template = InterviewTemplate.oneOffJob()
        let data = try InterviewTemplateExportFile(template: template).encoded()
        let decoded = try InterviewTemplateExportFile.decode(data)
        #expect(decoded.template == template)
        #expect(decoded.type == InterviewTemplateExportFile.fileType)
        #expect(decoded.version == InterviewTemplateExportFile.currentVersion)
    }

    @Test("2. Чужой тип файла (интервью, граф) → понятная ошибка")
    func wrongTypeFails() throws {
        let interviewData = try InterviewExport.json(
            Interview(name: "И", template: InterviewTemplate.oneOffJob())
        )
        #expect(throws: ExportFileError.wrongType(
            found: InterviewExportFile.fileType,
            expected: InterviewTemplateExportFile.fileType
        )) {
            try InterviewTemplateExportFile.decode(interviewData)
        }
    }

    @Test("3. Версия новее поддерживаемой → ошибка, не порча")
    func futureVersionFails() throws {
        var file = InterviewTemplateExportFile(template: InterviewTemplate.oneOffJob())
        file.version = 99
        let data = try ExportCoding.makeEncoder().encode(file)
        #expect(throws: ExportFileError.unsupportedVersion(
            found: 99,
            supported: InterviewTemplateExportFile.currentVersion
        )) {
            try InterviewTemplateExportFile.decode(data)
        }
    }

    @Test("4. withRegeneratedIDs: свежие id, содержимое и плейсхолдеры не тронуты")
    func regeneratedIDs() {
        let original = InterviewTemplate.oneOffJob()
        let copy = original.withRegeneratedIDs()
        #expect(copy.id != original.id)
        #expect(copy.sections.map(\.id) != original.sections.map(\.id))
        #expect(copy.sections.flatMap(\.fields).map(\.id)
            != original.sections.flatMap(\.fields).map(\.id))
        #expect(copy.name == original.name)
        #expect(copy.sections.map(\.title) == original.sections.map(\.title))
        #expect(copy.sections.flatMap(\.fields).map(\.question)
            == original.sections.flatMap(\.fields).map(\.question))
        #expect(copy.sections.flatMap(\.fields).map(\.fillsPlaceholder)
            == original.sections.flatMap(\.fields).map(\.fillsPlaceholder))
        #expect(copy.placeholderKeys == original.placeholderKeys)
    }
}
