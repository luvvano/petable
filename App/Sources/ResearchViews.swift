import SwiftUI
import GraphCore

// MARK: - Форма интервью

/// Форма заполнения интервью по AJTBD: панель плейсхолдеров сверху,
/// секции шаблона с вопросами и ответами ниже. Значения плейсхолдеров
/// (`{решение}`, `{ожидаемый результат}`, …) подставляются во все
/// вопросы формы — руками из панели или автоматически из ответов
/// полей, которые их питают.
struct InterviewFormView: View {
    @ObservedObject var document: PetableDocument
    let interviewID: UUID

    var body: some View {
        if let interview = document.research.interviews.first(where: { $0.id == interviewID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(interview)
                    placeholderPanel(interview)
                    ForEach(interview.template.sections) { section in
                        sectionView(section, interview: interview)
                    }
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ContentUnavailableView("Интервью не найдено", systemImage: "text.bubble")
        }
    }

    private func header(_ interview: Interview) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CommittingTextField(
                prompt: "Название интервью",
                text: interview.name,
                onCommit: { document.renameInterview(interview.id, to: $0) }
            )
            .font(.system(size: 22, weight: .bold))
            .textFieldStyle(.plain)

            HStack(spacing: 8) {
                Label(interview.template.name, systemImage: "doc.text")
                Text(interview.createdAt, style: .date)
                if interview.resolvedOrigin == .agent {
                    Label("Создано ИИ-агентом", systemImage: "sparkles")
                        .foregroundStyle(Color.purple)
                        .help("Гипотеза, сгенерированная агентом по методологии AJTBD — проверьте реальными интервью")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    /// Панель плейсхолдеров: все ключи из вопросов шаблона. Заполненное
    /// значение немедленно подставляется во все формы ниже.
    @ViewBuilder
    private func placeholderPanel(_ interview: Interview) -> some View {
        let keys = interview.template.placeholderKeys
        if !keys.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label("Плейсхолдеры", systemImage: "curlybraces")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(keys, id: \.self) { key in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("{\(key)}")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 230, alignment: .trailing)
                        CommittingTextField(
                            prompt: "слова респондента",
                            text: interview.placeholderValues[key] ?? "",
                            onCommit: { document.setInterviewPlaceholder(interview.id, key: key, value: $0) }
                        )
                        .font(.system(size: 12))
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private func sectionView(_ section: InterviewTemplate.Section, interview: Interview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(section.title)
                .font(.system(size: 15, weight: .semibold))
            ForEach(section.fields) { field in
                fieldView(field, interview: interview)
            }
        }
    }

    private func fieldView(_ field: InterviewTemplate.Field, interview: Interview) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(field.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                if let key = field.fillsPlaceholder {
                    Text("→ {\(key)}")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                        .help("Ответ подставится во все вопросы формы вместо {\(key)}")
                }
            }
            Text(interview.resolvedQuestion(for: field))
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if let hint = field.hint, !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            CommittingTextField(
                prompt: "Ответ (слова респондента)…",
                text: interview.answers[field.id] ?? "",
                axis: .vertical,
                onCommit: { document.setInterviewAnswer(interview.id, fieldID: field.id, text: $0) }
            )
            .font(.system(size: 13))
            .lineLimit(2...12)
            .textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Редактор шаблона

/// Редактор шаблона интервью: имя, секции, вопросы. Правки коммитятся
/// по потере фокуса — целым шаблоном в undo-стек документа. Уже
/// созданные интервью держат свой снапшот и не меняются.
struct TemplateEditorView: View {
    @ObservedObject var document: PetableDocument
    let templateID: UUID

    var body: some View {
        if let template = document.research.templates.first(where: { $0.id == templateID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        CommittingTextField(
                            prompt: "Название шаблона",
                            text: template.name,
                            onCommit: { name in
                                var updated = template
                                updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                                if !updated.name.isEmpty { document.updateTemplate(updated) }
                            }
                        )
                        .font(.system(size: 22, weight: .bold))
                        .textFieldStyle(.plain)

                        Text("Плейсхолдеры вида {решение} в тексте вопроса подставляются из ответов интервью во все формы.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    ForEach(Array(template.sections.enumerated()), id: \.element.id) { sectionIndex, section in
                        sectionEditor(template: template, sectionIndex: sectionIndex, section: section)
                    }

                    Button {
                        var updated = template
                        updated.sections.append(
                            InterviewTemplate.Section(title: "Секция \(updated.sections.count + 1)")
                        )
                        document.updateTemplate(updated)
                    } label: {
                        Label("Добавить секцию", systemImage: "plus")
                    }
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ContentUnavailableView("Шаблон не найден", systemImage: "doc.text")
        }
    }

    private func sectionEditor(
        template: InterviewTemplate,
        sectionIndex: Int,
        section: InterviewTemplate.Section
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                CommittingTextField(
                    prompt: "Название секции",
                    text: section.title,
                    onCommit: { title in
                        var updated = template
                        updated.sections[sectionIndex].title = title
                        document.updateTemplate(updated)
                    }
                )
                .font(.system(size: 15, weight: .semibold))
                .textFieldStyle(.plain)
                Spacer()
                Button {
                    var updated = template
                    updated.sections.remove(at: sectionIndex)
                    document.updateTemplate(updated)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Удалить секцию")
            }

            ForEach(Array(section.fields.enumerated()), id: \.element.id) { fieldIndex, field in
                fieldEditor(
                    template: template,
                    sectionIndex: sectionIndex,
                    fieldIndex: fieldIndex,
                    field: field
                )
            }

            Button {
                var updated = template
                updated.sections[sectionIndex].fields.append(
                    InterviewTemplate.Field(title: "Вопрос", question: "")
                )
                document.updateTemplate(updated)
            } label: {
                Label("Добавить вопрос", systemImage: "plus")
                    .font(.system(size: 12))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    private func fieldEditor(
        template: InterviewTemplate,
        sectionIndex: Int,
        fieldIndex: Int,
        field: InterviewTemplate.Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CommittingTextField(
                    prompt: "Короткое имя поля",
                    text: field.title,
                    onCommit: { value in
                        var updated = template
                        updated.sections[sectionIndex].fields[fieldIndex].title = value
                        document.updateTemplate(updated)
                    }
                )
                .font(.system(size: 12, weight: .semibold))
                .textFieldStyle(.plain)
                Spacer()
                Button {
                    var updated = template
                    updated.sections[sectionIndex].fields.remove(at: fieldIndex)
                    document.updateTemplate(updated)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Удалить вопрос")
            }
            CommittingTextField(
                prompt: "Текст вопроса; можно {плейсхолдеры}",
                text: field.question,
                axis: .vertical,
                onCommit: { value in
                    var updated = template
                    updated.sections[sectionIndex].fields[fieldIndex].question = value
                    document.updateTemplate(updated)
                }
            )
            .font(.system(size: 12))
            .lineLimit(1...6)
            .textFieldStyle(.roundedBorder)
            CommittingTextField(
                prompt: "Подсказка интервьюеру (необязательно)",
                text: field.hint ?? "",
                axis: .vertical,
                onCommit: { value in
                    var updated = template
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    updated.sections[sectionIndex].fields[fieldIndex].hint = trimmed.isEmpty ? nil : trimmed
                    document.updateTemplate(updated)
                }
            )
            .font(.system(size: 11))
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
            HStack(spacing: 6) {
                Text("Ответ питает плейсхолдер:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                CommittingTextField(
                    prompt: "ключ, например: решение",
                    text: field.fillsPlaceholder ?? "",
                    onCommit: { value in
                        var updated = template
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        updated.sections[sectionIndex].fields[fieldIndex].fillsPlaceholder =
                            trimmed.isEmpty ? nil : trimmed
                        document.updateTemplate(updated)
                    }
                )
                .font(.system(size: 11, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Выбор шаблона при создании интервью

/// Шит создания интервью: список доступных шаблонов, клик — создать
/// интервью по выбранному и открыть его форму.
struct TemplatePickerSheet: View {
    @ObservedObject var document: PetableDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Новое интервью")
                .font(.system(size: 16, weight: .bold))

            if document.research.templates.isEmpty {
                Text("Шаблонов пока нет — создайте первый в разделе «Интервью → Шаблоны».")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Button("Создать шаблон") {
                    document.addTemplate()
                    dismiss()
                }
            } else {
                Text("Выберите шаблон:")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    ForEach(document.research.templates) { template in
                        Button {
                            document.addInterview(templateID: template.id)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(template.name)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(templateSummary(template))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )
                    }
                }
            }

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func templateSummary(_ template: InterviewTemplate) -> String {
        let sections = template.sections.count
        let fields = template.sections.reduce(0) { $0 + $1.fields.count }
        return "Секций: \(sections) · вопросов: \(fields)"
    }
}

// MARK: - Поле с коммитом по потере фокуса

/// TextField с локальным черновиком: значение уходит в документ по
/// потере фокуса или Enter, а не на каждый символ — одна запись undo
/// на правку поля и никакой борьбы за курсор с @Published-состоянием.
struct CommittingTextField: View {
    let prompt: String
    let text: String
    var axis: Axis = .horizontal
    let onCommit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(prompt, text: $draft, axis: axis)
            .focused($focused)
            .onSubmit { commit() }
            .onAppear { draft = text }
            .onChange(of: text) { _, newValue in
                // Внешнее изменение (undo, смена выбора) — только когда
                // поле не в фокусе, чтобы не съесть ввод пользователя.
                if !focused { draft = newValue }
            }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
    }

    private func commit() {
        guard draft != text else { return }
        onCommit(draft)
    }
}
