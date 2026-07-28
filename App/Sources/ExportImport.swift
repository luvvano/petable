import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers
import GraphCore

/// Транспорт шаблона для системной кнопки «Поделиться» (ShareLink).
/// Файл пишется лениво — в момент, когда пользователь выбрал сервис,
/// а не при каждом показе меню.
struct TemplateShareItem: Transferable {
    let template: InterviewTemplate

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { item in
            SentTransferredFile(try ExportImport.temporaryTemplateFile(item.template))
        }
    }
}

/// Экспорт интервью (JSON / Markdown / PDF) и экспорт/импорт графа
/// работ (JSON) через системные панели сохранения/открытия.
/// Форматы файлов — в GraphCore (Export.swift); здесь только AppKit:
/// панели, запись на диск, PDF-рендер и алерты об ошибках.
@MainActor
enum ExportImport {

    // MARK: - Интервью

    static func exportInterviewJSON(_ interview: Interview) {
        guard let url = runSavePanel(suggestedName: interview.name, type: .json) else { return }
        do {
            try InterviewExport.json(interview).write(to: url)
        } catch {
            showError("Не удалось экспортировать интервью", error)
        }
    }

    static func exportInterviewMarkdown(_ interview: Interview) {
        let markdown = UTType(filenameExtension: "md") ?? .plainText
        guard let url = runSavePanel(suggestedName: interview.name, type: markdown) else { return }
        do {
            try Data(InterviewExport.markdown(interview).utf8).write(to: url)
        } catch {
            showError("Не удалось экспортировать интервью", error)
        }
    }

    static func copyInterviewJSON(_ interview: Interview) {
        do {
            copyToClipboard(String(decoding: try InterviewExport.json(interview), as: UTF8.self))
        } catch {
            showError("Не удалось скопировать интервью", error)
        }
    }

    static func copyInterviewMarkdown(_ interview: Interview) {
        copyToClipboard(InterviewExport.markdown(interview))
    }

    static func exportInterviewPDF(_ interview: Interview) {
        guard let url = runSavePanel(suggestedName: interview.name, type: .pdf) else { return }
        if !writePDF(pdfContent(interview), to: url) {
            showError(
                "Не удалось экспортировать интервью",
                nil,
                fallback: "Ошибка при создании PDF-файла."
            )
        }
    }

    // MARK: - Шаблоны интервью

    static func exportTemplateJSON(_ template: InterviewTemplate) {
        guard let url = runSavePanel(suggestedName: template.name, type: .json) else { return }
        do {
            try InterviewTemplateExportFile(template: template).encoded().write(to: url)
        } catch {
            showError("Не удалось экспортировать шаблон", error)
        }
    }

    static func copyTemplateJSON(_ template: InterviewTemplate) {
        do {
            let data = try InterviewTemplateExportFile(template: template).encoded()
            copyToClipboard(String(decoding: data, as: UTF8.self))
        } catch {
            showError("Не удалось скопировать шаблон", error)
        }
    }

    /// Файл шаблона во временной папке — для системного шаринга
    /// (ShareLink): Mail, Сообщения, AirDrop, Telegram, WhatsApp и
    /// другие установленные share-расширения. Своя подпапка на вызов —
    /// имя файла человеческое и не конфликтует с прошлыми.
    nonisolated static func temporaryTemplateFile(_ template: InterviewTemplate) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("petable-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = template.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = directory.appendingPathComponent("Шаблон AJTBD — \(name).json")
        try InterviewTemplateExportFile(template: template).encoded().write(to: url)
        return url
    }

    static func importTemplate(into document: PetableDocument) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Выберите JSON-файл шаблона интервью, экспортированный из petable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            importTemplateData(try Data(contentsOf: url), into: document)
        } catch {
            showError("Не удалось импортировать шаблон", error)
        }
    }

    static func importTemplateFromClipboard(into document: PetableDocument) {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            showError(
                "Не удалось импортировать шаблон",
                nil,
                fallback: "Буфер обмена пуст или не содержит текста."
            )
            return
        }
        importTemplateData(Data(text.utf8), into: document)
    }

    private static func importTemplateData(_ data: Data, into document: PetableDocument) {
        do {
            let file = try InterviewTemplateExportFile.decode(data)
            document.importTemplate(file.template)
        } catch let error as ExportFileError {
            showError("Не удалось импортировать шаблон", error)
        } catch {
            showError(
                "Не удалось импортировать шаблон",
                nil,
                fallback: "JSON не похож на экспорт шаблона интервью petable."
            )
        }
    }

    // MARK: - Граф работ

    static func exportGraphJSON(_ stage: Envelope.Stage) {
        guard let url = runSavePanel(suggestedName: stage.name, type: .json) else { return }
        do {
            try WorkGraphExportFile(name: stage.name, graph: stage.graph).encoded().write(to: url)
        } catch {
            showError("Не удалось экспортировать граф работ", error)
        }
    }

    static func copyGraphJSON(_ stage: Envelope.Stage) {
        do {
            let data = try WorkGraphExportFile(name: stage.name, graph: stage.graph).encoded()
            copyToClipboard(String(decoding: data, as: UTF8.self))
        } catch {
            showError("Не удалось скопировать граф работ", error)
        }
    }

    /// PNG-снапшот графа: офскрин-рендер GraphSnapshotView в 2x.
    /// Тема картинки — текущая тема приложения (ImageRenderer сам
    /// её не наследует, среда задаётся явно).
    static func exportGraphPNG(_ stage: Envelope.Stage) {
        exportGraphPNG(name: stage.name, graph: stage.graph)
    }

    static func exportGraphPNG(name: String, graph: WorkGraph) {
        guard let url = runSavePanel(suggestedName: name, type: .png) else { return }
        let isDark = NSApp.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let renderer = ImageRenderer(
            content: GraphSnapshotView(graph: graph)
                .environment(\.colorScheme, isDark ? .dark : .light)
        )
        renderer.scale = 2
        guard let cgImage = renderer.cgImage,
              let data = NSBitmapImageRep(cgImage: cgImage)
                  .representation(using: .png, properties: [:])
        else {
            showError(
                "Не удалось экспортировать граф работ",
                nil,
                fallback: "Ошибка при создании PNG-изображения."
            )
            return
        }
        do {
            try data.write(to: url)
        } catch {
            showError("Не удалось экспортировать граф работ", error)
        }
    }

    static func importGraph(into document: PetableDocument) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Выберите JSON-файл графа работ, экспортированный из petable"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            importGraphData(try Data(contentsOf: url), into: document)
        } catch {
            showError("Не удалось импортировать граф работ", error)
        }
    }

    static func importGraphFromClipboard(into document: PetableDocument) {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            showError(
                "Не удалось импортировать граф работ",
                nil,
                fallback: "Буфер обмена пуст или не содержит текста."
            )
            return
        }
        importGraphData(Data(text.utf8), into: document)
    }

    /// Общий хвост импорта: разбор JSON экспорта + понятные ошибки.
    private static func importGraphData(_ data: Data, into document: PetableDocument) {
        do {
            let file = try WorkGraphExportFile.decode(data)
            document.importGraph(name: file.name, graph: file.graph)
        } catch let error as ExportFileError {
            showError("Не удалось импортировать граф работ", error)
        } catch {
            showError(
                "Не удалось импортировать граф работ",
                nil,
                fallback: "JSON не похож на экспорт графа работ petable."
            )
        }
    }

    // MARK: - Работы в буфере обмена

    /// Своя разновидность данных для копирования работ. Кладём вместе
    /// с текстом: внутри приложения читается точно (текст в буфере мог
    /// оказаться чужим), наружу уходит тот же JSON — его можно вставить
    /// в редактор или переслать.
    static let jobsPasteboardType = NSPasteboard.PasteboardType("com.egorproskurin.petable.jobs")

    static func copyJobs(_ clipboard: JobClipboard) {
        do {
            let data = try clipboard.encoded()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setData(data, forType: jobsPasteboardType)
            pasteboard.setString(String(decoding: data, as: UTF8.self), forType: .string)
        } catch {
            showError("Не удалось скопировать работы", error)
        }
    }

    /// Работы из буфера обмена; nil — там что-то другое.
    static func readJobs() -> JobClipboard? {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: jobsPasteboardType),
           let clipboard = try? JobClipboard.decode(data) {
            return clipboard
        }
        guard let text = pasteboard.string(forType: .string) else { return nil }
        return try? JobClipboard.decode(Data(text.utf8))
    }

    /// Есть ли что вставлять — для disabled-состояния пунктов меню.
    static var hasJobsInClipboard: Bool {
        readJobs()?.isEmpty == false
    }

    // MARK: - Панели, буфер обмена и алерты

    private static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func runSavePanel(suggestedName: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName
        return panel.runModal() == .OK ? panel.url : nil
    }

    private static func showError(_ message: String, _ error: Error?, fallback: String = "") {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = error?.localizedDescription ?? fallback
        alert.runModal()
    }

    // MARK: - PDF

    /// Пагинацию делает NSPrintOperation по офскрин-NSTextView:
    /// jobDisposition = .save пишет PDF без диалога печати.
    private static func writePDF(_ content: NSAttributedString, to url: URL) -> Bool {
        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: 595.28, height: 841.89) // A4
        printInfo.topMargin = 48
        printInfo.bottomMargin = 48
        printInfo.leftMargin = 48
        printInfo.rightMargin = 48
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url as NSURL

        let contentWidth = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: 1))
        textView.textStorage?.setAttributedString(content)
        guard let container = textView.textContainer, let layoutManager = textView.layoutManager else {
            return false
        }
        layoutManager.ensureLayout(for: container)
        let usedHeight = layoutManager.usedRect(for: container).height
        textView.setFrameSize(NSSize(width: contentWidth, height: ceil(usedHeight) + 1))

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation.run()
    }

    /// Тот же состав, что и Markdown-экспорт: шапка, плейсхолдеры,
    /// секции с вопросами (плейсхолдеры подставлены) и ответами.
    private static func pdfContent(_ interview: Interview) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func append(
            _ text: String,
            font: NSFont,
            color: NSColor = .black,
            spacingBefore: CGFloat = 0,
            spacingAfter: CGFloat = 4
        ) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacingBefore = spacingBefore
            paragraph.paragraphSpacing = spacingAfter
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]))
        }

        append(interview.name, font: .boldSystemFont(ofSize: 20), spacingAfter: 6)
        var meta = "Шаблон: \(interview.template.name) · Создано: \(InterviewExport.dateString(interview.createdAt))"
        if let modified = interview.modifiedAt {
            meta += " · Изменено: \(InterviewExport.dateString(modified))"
        }
        if interview.resolvedOrigin == .agent {
            meta += " · Создано ИИ-агентом"
        }
        append(meta, font: .systemFont(ofSize: 10), color: .darkGray, spacingAfter: 10)

        let keys = interview.template.placeholderKeys
        if !keys.isEmpty {
            append("Плейсхолдеры", font: .boldSystemFont(ofSize: 14), spacingBefore: 8)
            for key in keys {
                let value = interview.placeholderValues[key] ?? ""
                append(
                    "{\(key)} — \(value.isEmpty ? "—" : value)",
                    font: .systemFont(ofSize: 11),
                    spacingAfter: 2
                )
            }
        }

        for section in interview.template.sections {
            append(section.title, font: .boldSystemFont(ofSize: 14), spacingBefore: 14)
            for field in section.fields {
                append(
                    field.title.uppercased(),
                    font: .systemFont(ofSize: 9, weight: .semibold),
                    color: .darkGray,
                    spacingBefore: 8,
                    spacingAfter: 2
                )
                append(
                    interview.resolvedQuestion(for: field),
                    font: .systemFont(ofSize: 11),
                    color: .darkGray,
                    spacingAfter: 3
                )
                let answer = (interview.answers[field.id] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                append(
                    answer.isEmpty ? "Нет ответа." : answer,
                    font: .systemFont(ofSize: 12),
                    color: answer.isEmpty ? .gray : .black
                )
            }
        }
        return result
    }
}
