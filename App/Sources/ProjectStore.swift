import Foundation
import GraphCore

/// Каталог проектов пользователя: папка `~/Documents/Petable`,
/// проект = файл `.petable` в ней. Имя проекта = имя файла (в конверте
/// отдельного поля нет — см. Envelope). Файлы, открытые из других мест,
/// продолжают работать как обычные документы — хаб их просто не видит.
@MainActor
final class ProjectStore: ObservableObject {
    struct Project: Identifiable, Equatable {
        var url: URL
        var name: String
        var modified: Date

        var id: URL { url }
    }

    @Published private(set) var projects: [Project] = []
    @Published var lastError: String?

    static let fileExtension = "petable"

    /// `~/Documents/Petable`. Создаётся при первой записи.
    nonisolated static var folderURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Petable", isDirectory: true)
    }

    /// Перечитывает папку. Отсутствие папки — не ошибка: проектов ещё нет.
    func refresh() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: Self.folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            projects = []
            return
        }
        projects = items
            .filter { $0.pathExtension == Self.fileExtension }
            .map { url in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return Project(
                    url: url,
                    name: url.deletingPathExtension().lastPathComponent,
                    modified: modified
                )
            }
            .sorted { $0.modified > $1.modified }
    }

    /// Создаёт файл проекта с одним пустым графом. Возвращает URL для открытия.
    func create(named rawName: String) -> URL? {
        guard let name = sanitized(rawName) else { return nil }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.folderURL, withIntermediateDirectories: true)
            let url = Self.folderURL
                .appendingPathComponent(name)
                .appendingPathExtension(Self.fileExtension)
            guard !fm.fileExists(atPath: url.path) else {
                lastError = "Проект «\(name)» уже существует."
                return nil
            }
            let envelope = Envelope(graph: WorkGraph(levels: [GraphLevel(jobs: [JobNode(verb: "")])]))
            try envelope.encoded().write(to: url, options: .atomic)
            refresh()
            return url
        } catch {
            lastError = "Не удалось создать проект: \(error.localizedDescription)"
            return nil
        }
    }

    /// Переименовывает файл проекта. Открытый документ переезжает вместе
    /// с файлом — NSDocument отслеживает перемещение как file presenter.
    func rename(_ project: Project, to rawName: String) {
        guard let name = sanitized(rawName), name != project.name else { return }
        let destination = Self.folderURL
            .appendingPathComponent(name)
            .appendingPathExtension(Self.fileExtension)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            lastError = "Проект «\(name)» уже существует."
            return
        }
        do {
            try FileManager.default.moveItem(at: project.url, to: destination)
            refresh()
        } catch {
            lastError = "Не удалось переименовать: \(error.localizedDescription)"
        }
    }

    /// Имя → безопасное имя файла: без пустоты и разделителей пути.
    private func sanitized(_ raw: String) -> String? {
        let name = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return name.isEmpty ? nil : name
    }
}
