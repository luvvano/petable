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

    @State private var graphsExpanded = true
    @State private var interviewsExpanded = true
    @State private var templatesExpanded = false
    @State private var hoveredRow: UUID?
    @State private var renamingID: UUID?
    @State private var renameDraft = ""
    @State private var templatePickerShown = false
    @FocusState private var renameFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: selectionBinding) {
                DisclosureGroup(isExpanded: $graphsExpanded) {
                    ForEach(document.graphStages) { stage in
                        graphRow(stage)
                            .tag(SidebarItem.graph(stage.id))
                    }
                    newItemRow("Создать новый", help: "Добавить граф работ в проект") {
                        document.addGraph()
                    }
                } label: {
                    Label("Граф работ", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 13, weight: .semibold))
                }

                DisclosureGroup(isExpanded: $interviewsExpanded) {
                    ForEach(document.research.interviews) { interview in
                        interviewRow(interview)
                            .tag(SidebarItem.interview(interview.id))
                    }
                    newItemRow("Создать интервью", help: "Новое интервью по шаблону AJTBD") {
                        templatePickerShown = true
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
                    Label("Интервью", systemImage: "person.wave.2")
                        .font(.system(size: 13, weight: .semibold))
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
        .sheet(isPresented: $templatePickerShown) {
            TemplatePickerSheet(document: document)
        }
    }

    private func newItemRow(_ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: "plus")
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
                deletable: document.graphStages.count > 1,
                deleteHelp: "Удалить граф",
                onDelete: { document.deleteGraph(stage.id) },
                onRename: { beginRename(id: stage.id, name: stage.name) }
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
                deletable: true,
                deleteHelp: "Удалить интервью",
                onDelete: { document.deleteInterview(interview.id) },
                onRename: { beginRename(id: interview.id, name: interview.name) }
            )
        }
    }

    @ViewBuilder
    private func templateRow(_ template: InterviewTemplate) -> some View {
        sidebarRow(
            id: template.id,
            name: template.name,
            icon: "doc.text",
            deletable: true,
            deleteHelp: "Удалить шаблон",
            onDelete: { document.deleteTemplate(template.id) },
            onRename: nil
        )
    }

    /// Строка сайдбара: имя + корзина при наведении + контекстное меню.
    private func sidebarRow(
        id: UUID,
        name: String,
        icon: String,
        deletable: Bool,
        deleteHelp: String,
        onDelete: @escaping () -> Void,
        onRename: (() -> Void)?
    ) -> some View {
        HStack {
            Label(name, systemImage: icon)
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
