import Foundation

/// Поиск CLI-бинарей. Одна реализация на приложение и демон (4A):
/// GUI-приложение и launchd-демон не видят PATH шелла, поэтому после
/// env-PATH пробуется логин-zsh `command -v`; результат кэшируется.
public enum CLIDiscovery {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: URL?] = [:]
    /// Ручные пути из настроек движка — приоритетнее любого поиска.
    nonisolated(unsafe) private static var overrides: [String: String] = [:]

    /// Ручной путь к CLI (настройки движка); nil/пусто — автопоиск.
    public static func setOverride(_ name: String, path: String?) {
        lock.lock()
        overrides[name] = (path?.isEmpty ?? true) ? nil : path
        cache[name] = nil
        lock.unlock()
    }

    /// Путь к бинарю; nil — не установлен (состояние UI «CLI не найден»).
    /// Порядок: ручной путь → PATH процесса → стандартные каталоги
    /// (launchd-демон и GUI видят урезанный PATH; `~/.local/bin` и
    /// homebrew туда не входят) → login-zsh.
    public static func locate(_ name: String) -> URL? {
        lock.lock()
        if let override = overrides[name] {
            lock.unlock()
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        }
        if let cached = cache[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let found = searchEnvPATH(name) ?? searchWellKnown(name) ?? searchLoginShell(name)
        lock.lock()
        cache[name] = found
        lock.unlock()
        return found
    }

    /// Сброс кэша (настройки «переискать CLI»).
    public static func reset() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private static func searchWellKnown(_ name: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories = [
            "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
            "\(home)/bin", "\(home)/.claude/local", "/usr/bin",
        ]
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func searchEnvPATH(_ name: String) -> URL? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func searchLoginShell(_ name: String) -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let path = String(
            data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
