import SwiftUI

/// Хаб проектов: список `.petable`-файлов из `~/Documents/Petable`.
/// Создать → файл с одним пустым графом + открытие окна документа;
/// переименовать — инлайн; открыть — двойной клик или кнопка.
struct ProjectsView: View {
    static let windowID = "projects"

    @StateObject private var store = ProjectStore()
    @Environment(\.openDocument) private var openDocument

    @State private var creating = false
    @State private var nameDraft = ""
    @State private var renamingID: URL?
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    private static let dateFormat: Date.FormatStyle = .dateTime.day().month().year().hour().minute()

    var body: some View {
        VStack(spacing: 0) {
            if store.projects.isEmpty {
                emptyState
            } else {
                projectList
            }
            Divider()
            footer
        }
        .navigationTitle("Проекты")
        .onAppear { store.refresh() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in store.refresh() }
        .sheet(isPresented: $creating) { createSheet }
        .alert(
            "Ошибка",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { if !$0 { store.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.lastError ?? "")
        }
        .frame(minWidth: 440, minHeight: 320)
    }

    // MARK: - Список

    private var projectList: some View {
        List(store.projects) { project in
            row(project)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { open(project.url) }
                .contextMenu {
                    Button("Открыть") { open(project.url) }
                    Button("Переименовать") { beginRename(project) }
                    Button("Показать в Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([project.url])
                    }
                }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func row(_ project: ProjectStore.Project) -> some View {
        HStack {
            Image(systemName: "square.grid.2x2")
                .foregroundStyle(Color.accentColor)
            if renamingID == project.id {
                TextField("Название проекта", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFocused)
                    .onSubmit { commitRename(project) }
                    .onExitCommand { renamingID = nil }
            } else {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
            }
            Spacer()
            Text(project.modified, format: Self.dateFormat)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Пока нет проектов")
                .font(.headline)
            Text("Проекты хранятся в Documents/Petable.\nСоздайте первый — он откроется сразу.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Button {
                nameDraft = ""
                creating = true
            } label: {
                Label("Новый проект", systemImage: "plus")
            }
            Spacer()
        }
        .padding(12)
    }

    // MARK: - Создание

    private var createSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Новый проект")
                .font(.headline)
            TextField("Название", text: $nameDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { createProject() }
            HStack {
                Spacer()
                Button("Отмена") { creating = false }
                    .keyboardShortcut(.cancelAction)
                Button("Создать") { createProject() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(nameDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
    }

    private func createProject() {
        guard let url = store.create(named: nameDraft) else { return }
        creating = false
        open(url)
    }

    // MARK: - Действия

    private func open(_ url: URL) {
        Task {
            do {
                try await openDocument(at: url)
            } catch {
                store.lastError = "Не удалось открыть проект: \(error.localizedDescription)"
            }
        }
    }

    private func beginRename(_ project: ProjectStore.Project) {
        renameDraft = project.name
        renamingID = project.id
        renameFocused = true
    }

    private func commitRename(_ project: ProjectStore.Project) {
        renamingID = nil
        store.rename(project, to: renameDraft)
    }
}
