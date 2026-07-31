import AppKit
import SwiftUI
import UniformTypeIdentifiers
import GraphCore

// Каталог знаний per-CLI для редактора сотрудника (правка автора):
// модели, уровни effort и инструменты с описаниями — выпадающие списки
// с поиском. Списки справочные: версии зависят от установленного CLI,
// свободный ввод всегда доступен.

struct CatalogOption: Identifiable {
    let name: String
    let detail: String
    var id: String { name }
}

enum CLICatalog {
    static func models(for cli: String) -> [CatalogOption] {
        switch cli {
        case "claude":
            // Алиасы CLI (`claude --help`: fable/opus/sonnet) берут
            // последнюю версию линейки; полные имена пиннят версию.
            return [
                CatalogOption(name: "fable", detail: "алиас Fable — самая способная линейка"),
                CatalogOption(name: "opus", detail: "алиас Opus — сильная, дорогая"),
                CatalogOption(name: "sonnet", detail: "алиас Sonnet — баланс цены и качества"),
                CatalogOption(name: "haiku", detail: "алиас Haiku — быстрая, дешёвая"),
                CatalogOption(name: "claude-fable-5", detail: "Fable 5 — фиксированная версия"),
                CatalogOption(name: "claude-opus-5", detail: "Opus 5 — фиксированная версия"),
                CatalogOption(name: "claude-sonnet-5", detail: "Sonnet 5 — фиксированная версия"),
                CatalogOption(name: "claude-haiku-4-5-20251001", detail: "Haiku 4.5 — фиксированная версия"),
            ]
        case "codex":
            return [
                CatalogOption(name: "gpt-5.6-sol", detail: "рассуждающая, сильная — ревью и архитектура"),
                CatalogOption(name: "gpt-5.6-codex", detail: "кодовая — генерация и правки"),
                CatalogOption(name: "o3", detail: "рассуждающая предыдущего поколения"),
                CatalogOption(name: "o4-mini", detail: "быстрая и дешёвая"),
            ]
        default:
            return []
        }
    }

    static func efforts(for cli: String) -> [CatalogOption] {
        switch cli {
        case "claude":
            // `claude --help`: --effort <low, medium, high, xhigh, max>.
            return [
                CatalogOption(name: "low", detail: "минимум рассуждений — быстрые правки"),
                CatalogOption(name: "medium", detail: "стандартный уровень"),
                CatalogOption(name: "high", detail: "глубокие рассуждения — сложные задачи"),
                CatalogOption(name: "xhigh", detail: "очень глубокие рассуждения"),
                CatalogOption(name: "max", detail: "максимум — медленно и дорого"),
            ]
        case "codex":
            // `model_reasoning_effort` из ~/.codex/config.toml.
            return [
                CatalogOption(name: "minimal", detail: "почти без рассуждений"),
                CatalogOption(name: "low", detail: "лёгкие задачи"),
                CatalogOption(name: "medium", detail: "стандартный уровень"),
                CatalogOption(name: "high", detail: "сложные задачи"),
                CatalogOption(name: "xhigh", detail: "очень глубокие рассуждения"),
                CatalogOption(name: "max", detail: "максимум — медленно и дорого"),
            ]
        default:
            return []
        }
    }

    /// Инструменты claude (`--allowedTools`); пустой allowlist — все
    /// дефолтные. Для codex allowlist не транслируется (П8).
    static func tools(for cli: String) -> [CatalogOption] {
        guard cli == "claude" else { return [] }
        return [
            CatalogOption(name: "Bash", detail: "запуск команд в терминале"),
            CatalogOption(name: "Edit", detail: "точечные правки файлов"),
            CatalogOption(name: "Write", detail: "создание и перезапись файлов"),
            CatalogOption(name: "Read", detail: "чтение файлов"),
            CatalogOption(name: "Glob", detail: "поиск файлов по маске"),
            CatalogOption(name: "Grep", detail: "поиск по содержимому"),
            CatalogOption(name: "WebFetch", detail: "загрузка веб-страниц"),
            CatalogOption(name: "WebSearch", detail: "поиск в интернете"),
            CatalogOption(name: "NotebookEdit", detail: "правка Jupyter-ноутбуков"),
            CatalogOption(name: "TodoWrite", detail: "списки задач агента"),
            CatalogOption(name: "Task", detail: "субагенты для подзадач"),
            // Скоуп-паттерны CLI: «Bash(git *)» разрешает только git.
            CatalogOption(name: "Bash(git *)", detail: "только git-команды (скоуп Bash)"),
            CatalogOption(name: "Bash(npm *)", detail: "только npm-команды (скоуп Bash)"),
        ]
    }
}

// MARK: - Выпадающий список с поиском (одно значение)

/// Поле со свободным вводом + кнопка-дропдаун: поиск по каталогу,
/// строка = имя + описание; выбор подставляет значение.
struct SearchableDropdown: View {
    let placeholder: String
    let options: [CatalogOption]
    @Binding var text: String
    var width: CGFloat = 200
    /// Значение приходит параметром — вызывающий не зависит от порядка
    /// обновления @State после выбора в списке.
    var onCommit: (String) -> Void

    @State private var shown = false
    @State private var query = ""

    var body: some View {
        HStack(spacing: 2) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onCommit(text) }
            if !options.isEmpty {
                Button {
                    query = ""
                    shown.toggle()
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $shown, arrowEdge: .bottom) {
                    optionList
                }
            }
        }
        .frame(width: width)
    }

    private var filtered: [CatalogOption] {
        query.isEmpty ? options : options.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.detail.localizedCaseInsensitiveContains(query)
        }
    }

    private var optionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Поиск…", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { option in
                        Button {
                            text = option.name
                            shown = false
                            onCommit(option.name)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(option.name)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    if option.name == text {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 9))
                                    }
                                }
                                Text(option.detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if filtered.isEmpty {
                        Text("Ничего не нашлось — впиши своё значение в поле")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .padding(4)
                    }
                }
            }
            .frame(maxHeight: 220)
            Text("Список справочный — свободный ввод в поле работает всегда")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(width: 300)
    }
}

// MARK: - Мульти-выбор с поиском (инструменты)

/// Кнопка-состояние + поповер: поиск, чекбоксы с описаниями, свой
/// инструмент текстом.
struct SearchableMultiDropdown: View {
    let placeholder: String
    let options: [CatalogOption]
    @Binding var selection: [String]
    /// Новый список приходит параметром (см. SearchableDropdown).
    var onCommit: ([String]) -> Void

    @State private var shown = false
    @State private var query = ""
    @State private var custom = ""

    var body: some View {
        Button {
            query = ""
            shown.toggle()
        } label: {
            HStack(spacing: 6) {
                Text(selection.isEmpty ? placeholder : selection.joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(selection.isEmpty ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.secondary.opacity(0.35))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            optionList
        }
    }

    private var filtered: [CatalogOption] {
        query.isEmpty ? options : options.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.detail.localizedCaseInsensitiveContains(query)
        }
    }

    private var optionList: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Поиск по инструментам…", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // Выбранные вне каталога (свои) — сверху, снимаемые.
                    ForEach(selection.filter { name in
                        !options.contains(where: { $0.name == name })
                    }, id: \.self) { name in
                        toggleRow(name: name, detail: "свой инструмент")
                    }
                    ForEach(filtered) { option in
                        toggleRow(name: option.name, detail: option.detail)
                    }
                }
            }
            .frame(maxHeight: 240)
            HStack(spacing: 6) {
                TextField("Свой инструмент… (⏎)", text: $custom)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit(addCustom)
                Button("Добавить", action: addCustom)
                    .controlSize(.small)
                    .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Пустой список — дефолтный набор CLI")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(width: 320)
    }

    private func toggleRow(name: String, detail: String) -> some View {
        Button {
            var updated = selection
            if let index = updated.firstIndex(of: name) {
                updated.remove(at: index)
            } else {
                updated.append(name)
            }
            selection = updated
            onCommit(updated)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: selection.contains(name) ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(selection.contains(name) ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func addCustom() {
        let name = custom.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !selection.contains(name) else { return }
        let updated = selection + [name]
        selection = updated
        custom = ""
        onCommit(updated)
    }
}

// MARK: - Экспорт/импорт сотрудника (правка автора)

/// JSON-обмен настройками сотрудника: экспорт целиком, импорт создаёт
/// НОВОГО сотрудника (id перегенерируется — конфликтов нет).
enum EmployeeTransfer {
    static func exportJSON(_ employee: Employee) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let slug = employee.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "employee-\(slug).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try (try encoder.encode(employee)).write(to: url)
        } catch {
            alert("Экспорт не удался: \(error.localizedDescription)")
        }
    }

    static func importJSON() -> Employee? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            let data = try Data(contentsOf: url)
            var employee = try JSONDecoder().decode(Employee.self, from: data)
            employee.id = UUID()
            return employee
        } catch {
            alert("Файл не похож на настройки сотрудника: \(error.localizedDescription)")
            return nil
        }
    }

    private static func alert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}
