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

/// Оболочка окна проекта: сайдбар с графами работ слева + канвас справа.
struct AppShellView: View {
    @ObservedObject var document: PetableDocument

    @State private var renamingID: UUID?
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: selectionBinding) {
                Section("Графы работ") {
                    ForEach(document.graphStages) { stage in
                        graphRow(stage)
                            .tag(stage.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 280)
            .safeAreaInset(edge: .bottom) {
                Button {
                    document.addGraph()
                } label: {
                    Label("Новый граф", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .help("Добавить граф работ в проект")
            }
        } detail: {
            CanvasRootView(document: document)
        }
        .navigationTitle("")
    }

    /// Выбор в списке ↔ выбранный граф документа.
    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { document.selectedGraphID },
            set: { id in
                if let id { document.selectGraph(id) }
            }
        )
    }

    @ViewBuilder
    private func graphRow(_ stage: Envelope.Stage) -> some View {
        if renamingID == stage.id {
            TextField("Название графа", text: $renameDraft)
                .textFieldStyle(.plain)
                .focused($renameFocused)
                .onSubmit { commitRename(stage.id) }
                .onExitCommand { renamingID = nil }
                .onChange(of: renameFocused) { _, focused in
                    if !focused, renamingID == stage.id { commitRename(stage.id) }
                }
        } else {
            Label(stage.name, systemImage: "point.3.connected.trianglepath.dotted")
                .contextMenu {
                    Button("Переименовать") { beginRename(stage) }
                    Button("Удалить", role: .destructive) {
                        document.deleteGraph(stage.id)
                    }
                    .disabled(document.graphStages.count == 1)
                }
        }
    }

    private func beginRename(_ stage: Envelope.Stage) {
        renameDraft = stage.name
        renamingID = stage.id
        renameFocused = true
    }

    private func commitRename(_ id: UUID) {
        document.renameGraph(id, to: renameDraft)
        renamingID = nil
    }
}
