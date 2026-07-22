import SwiftUI
import GraphCore

@main
struct PetableApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Первая сцена — то, что открывается при запуске: хаб проектов,
        // а не системный диалог открытия файла от DocumentGroup.
        Window("Проекты", id: ProjectsView.windowID) {
            ProjectsView()
        }
        .defaultSize(width: 520, height: 420)

        DocumentGroup(newDocument: { PetableDocument() }) { configuration in
            AppShellView(document: configuration.document)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Проекты…") {
                    openWindow(id: ProjectsView.windowID)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }

        // Настройки (⌘,): токены и конфигурация ИИ-агента.
        Settings {
            AgentSettingsView()
        }
    }
}

/// Без делегата NSDocumentController при запуске/реактивации требует
/// untitled-документ — SwiftUI отвечает на это диалогом открытия файла.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Оболочка окна проекта: сайдбар с разделами слева + detail справа.
/// Разделы: «Граф работ» (канвас) и «Интервью» (исследования AJTBD —
/// список интервью, шаблоны, форма интервью).
struct AppShellView: View {
    @ObservedObject var document: PetableDocument

    /// Единый тип выбора в сайдбаре: граф, интервью или шаблон.
    enum SidebarItem: Hashable {
        case graph(UUID)
        case interview(UUID)
        case template(UUID)
    }

    /// Фильтр артефактов по происхождению: все / человек / агент.
    enum OriginFilter: String, CaseIterable {
        case all = "Все"
        case human = "Человек"
        case agent = "Агент"

        func matches(_ origin: ArtifactOrigin) -> Bool {
            switch self {
            case .all: return true
            case .human: return origin == .human
            case .agent: return origin == .agent
            }
        }
    }

    @State private var graphsExpanded = true
    @State private var interviewsExpanded = true
    @State private var templatesExpanded = false
    @State private var hoveredRow: UUID?
    @State private var renamingID: UUID?
    @State private var renameDraft = ""
    @State private var templatePickerShown = false
    @State private var agentSheetShown = false
    @State private var graphFilter: OriginFilter = .all
    @State private var interviewFilter: OriginFilter = .all
    @FocusState private var renameFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: selectionBinding) {
                DisclosureGroup(isExpanded: $graphsExpanded) {
                    ForEach(document.graphStages.filter { graphFilter.matches($0.resolvedOrigin) }) { stage in
                        graphRow(stage)
                            .tag(SidebarItem.graph(stage.id))
                    }
                    newItemRow("Создать новый", help: "Добавить граф работ в проект") {
                        document.addGraph()
                    }
                    Menu {
                        Button("Из файла…") {
                            ExportImport.importGraph(into: document)
                        }
                        Button("Вставить из буфера") {
                            ExportImport.importGraphFromClipboard(into: document)
                        }
                    } label: {
                        Label("Импортировать…", systemImage: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("Импортировать граф работ из JSON: файл или буфер обмена")
                } label: {
                    sectionLabel(
                        "Граф работ",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        filter: $graphFilter
                    )
                }

                DisclosureGroup(isExpanded: $interviewsExpanded) {
                    ForEach(document.research.interviews.filter { interviewFilter.matches($0.resolvedOrigin) }) { interview in
                        interviewRow(interview)
                            .tag(SidebarItem.interview(interview.id))
                    }
                    newItemRow("Создать интервью", help: "Новое интервью по шаблону AJTBD") {
                        templatePickerShown = true
                    }
                    newItemRow(
                        "Исследовать агентом…",
                        systemImage: "sparkles",
                        help: "ИИ-агент раскопает работы по решению и построит интервью + граф работ"
                    ) {
                        agentSheetShown = true
                    }
                    DisclosureGroup(isExpanded: $templatesExpanded) {
                        ForEach(document.research.templates) { template in
                            templateRow(template)
                                .tag(SidebarItem.template(template.id))
                        }
                        newItemRow("Создать шаблон", help: "Новый шаблон интервью") {
                            document.addTemplate()
                        }
                    } label: {
                        Label("Шаблоны", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                    }
                } label: {
                    sectionLabel(
                        "Интервью",
                        systemImage: "person.wave.2",
                        filter: $interviewFilter
                    )
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        } detail: {
            switch document.selectedResearchItem {
            case .interview(let id):
                InterviewFormView(document: document, interviewID: id)
            case .template(let id):
                TemplateEditorView(document: document, templateID: id)
            case nil:
                CanvasRootView(document: document)
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                exportToolbarMenu
            }
        }
        .sheet(isPresented: $templatePickerShown) {
            TemplatePickerSheet(document: document)
        }
        .sheet(isPresented: $agentSheetShown) {
            AgentRunSheet(document: document)
        }
    }

    /// Кнопка «Экспорт» в правом верхнем углу окна: меню под то, что
    /// открыто в detail — интервью (JSON/Markdown/PDF в файл, JSON/Markdown
    /// в буфер) или выбранный граф (JSON в файл / в буфер). Для редактора
    /// шаблона экспорта нет — кнопка скрывается.
    @ViewBuilder
    private var exportToolbarMenu: some View {
        switch document.selectedResearchItem {
        case .interview(let id):
            if let interview = document.research.interviews.first(where: { $0.id == id }) {
                Menu {
                    Button("Экспортировать в JSON…") { ExportImport.exportInterviewJSON(interview) }
                    Button("Экспортировать в Markdown…") { ExportImport.exportInterviewMarkdown(interview) }
                    Button("Экспортировать в PDF…") { ExportImport.exportInterviewPDF(interview) }
                    Divider()
                    Button("Скопировать JSON") { ExportImport.copyInterviewJSON(interview) }
                    Button("Скопировать Markdown") { ExportImport.copyInterviewMarkdown(interview) }
                } label: {
                    Label("Экспорт", systemImage: "square.and.arrow.up")
                }
                .help("Экспортировать интервью: в файл или в буфер обмена")
            }
        case .template:
            EmptyView()
        case nil:
            if let stage = document.graphStages.first(where: { $0.id == document.selectedGraphID }) {
                Menu {
                    Button("Экспортировать в JSON…") { ExportImport.exportGraphJSON(stage) }
                    Divider()
                    Button("Скопировать JSON") { ExportImport.copyGraphJSON(stage) }
                } label: {
                    Label("Экспорт", systemImage: "square.and.arrow.up")
                }
                .help("Экспортировать граф работ: в файл или в буфер обмена")
            }
        }
    }

    /// Заголовок раздела с меню фильтра по происхождению; активный
    /// фильтр подсвечивается залитой иконкой.
    private func sectionLabel(
        _ title: String,
        systemImage: String,
        filter: Binding<OriginFilter>
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Menu {
                Picker("Показывать", selection: filter) {
                    ForEach(OriginFilter.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            } label: {
                Image(systemName: filter.wrappedValue == .all
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(filter.wrappedValue == .all ? Color.secondary : Color.accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Фильтр: созданы человеком или агентом")
        }
    }

    private func newItemRow(
        _ title: String,
        systemImage: String = "plus",
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Выбор в списке ↔ состояние документа (граф или элемент исследований).
    private var selectionBinding: Binding<SidebarItem?> {
        Binding(
            get: {
                switch document.selectedResearchItem {
                case .interview(let id): return .interview(id)
                case .template(let id): return .template(id)
                case nil: return document.selectedGraphID.map(SidebarItem.graph)
                }
            },
            set: { item in
                switch item {
                case .graph(let id): document.selectGraph(id)
                case .interview(let id): document.selectResearch(.interview(id))
                case .template(let id): document.selectResearch(.template(id))
                case nil: break
                }
            }
        )
    }

    @ViewBuilder
    private func graphRow(_ stage: Envelope.Stage) -> some View {
        if renamingID == stage.id {
            renameField("Название графа") { document.renameGraph(stage.id, to: $0) }
        } else {
            sidebarRow(
                id: stage.id,
                name: stage.name,
                icon: "circle.hexagonpath",
                isAgent: stage.resolvedOrigin == .agent,
                deletable: document.graphStages.count > 1,
                deleteHelp: "Удалить граф",
                onDelete: { document.deleteGraph(stage.id) },
                onRename: { beginRename(id: stage.id, name: stage.name) },
                exportItems: [
                    ("Экспортировать в JSON…", { ExportImport.exportGraphJSON(stage) }),
                    ("Скопировать JSON", { ExportImport.copyGraphJSON(stage) }),
                ]
            )
        }
    }

    @ViewBuilder
    private func interviewRow(_ interview: Interview) -> some View {
        if renamingID == interview.id {
            renameField("Название интервью") { document.renameInterview(interview.id, to: $0) }
        } else {
            sidebarRow(
                id: interview.id,
                name: interview.name,
                icon: "text.bubble",
                isAgent: interview.resolvedOrigin == .agent,
                deletable: true,
                deleteHelp: "Удалить интервью",
                onDelete: { document.deleteInterview(interview.id) },
                onRename: { beginRename(id: interview.id, name: interview.name) },
                exportItems: [
                    ("Экспортировать в JSON…", { ExportImport.exportInterviewJSON(interview) }),
                    ("Экспортировать в Markdown…", { ExportImport.exportInterviewMarkdown(interview) }),
                    ("Экспортировать в PDF…", { ExportImport.exportInterviewPDF(interview) }),
                    ("Скопировать JSON", { ExportImport.copyInterviewJSON(interview) }),
                    ("Скопировать Markdown", { ExportImport.copyInterviewMarkdown(interview) }),
                ]
            )
        }
    }

    @ViewBuilder
    private func templateRow(_ template: InterviewTemplate) -> some View {
        sidebarRow(
            id: template.id,
            name: template.name,
            icon: "doc.text",
            isAgent: false,
            deletable: true,
            deleteHelp: "Удалить шаблон",
            onDelete: { document.deleteTemplate(template.id) },
            onRename: nil
        )
    }

    /// Строка сайдбара: имя + бейдж «агент» + корзина при наведении
    /// + контекстное меню (переименовать, экспорт, удалить).
    private func sidebarRow(
        id: UUID,
        name: String,
        icon: String,
        isAgent: Bool,
        deletable: Bool,
        deleteHelp: String,
        onDelete: @escaping () -> Void,
        onRename: (() -> Void)?,
        exportItems: [(title: String, action: () -> Void)] = []
    ) -> some View {
        HStack {
            Label(name, systemImage: icon)
            if isAgent {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.purple)
                    .help("Создано ИИ-агентом")
            }
            Spacer()
            if hoveredRow == id, deletable {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(deleteHelp)
            }
        }
        .onHover { inside in
            if inside {
                hoveredRow = id
            } else if hoveredRow == id {
                hoveredRow = nil
            }
        }
        .contextMenu {
            if let onRename {
                Button("Переименовать", action: onRename)
            }
            if !exportItems.isEmpty {
                Divider()
                ForEach(exportItems, id: \.title) { item in
                    Button(item.title, action: item.action)
                }
            }
            Divider()
            Button("Удалить", role: .destructive, action: onDelete)
                .disabled(!deletable)
        }
    }

    private func renameField(_ prompt: String, commit: @escaping (String) -> Void) -> some View {
        TextField(prompt, text: $renameDraft)
            .textFieldStyle(.plain)
            .focused($renameFocused)
            .onSubmit {
                commit(renameDraft)
                renamingID = nil
            }
            .onExitCommand { renamingID = nil }
            .onChange(of: renameFocused) { _, focused in
                if !focused, renamingID != nil {
                    commit(renameDraft)
                    renamingID = nil
                }
            }
    }

    private func beginRename(id: UUID, name: String) {
        renameDraft = name
        renamingID = id
        renameFocused = true
    }
}
