import Foundation

/// Поиск CLI-бинарей. Одна реализация на приложение и демон (4A):
/// GUI-приложение и launchd-демон не видят PATH шелла, поэтому после
/// env-PATH пробуется логин-zsh `command -v`; результат кэшируется.
public enum CLIDiscovery {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: URL?] = [:]

    /// Путь к бинарю; nil — не установлен (состояние UI «CLI не найден»).
    public static func locate(_ name: String) -> URL? {
        lock.lock()
        if let cached = cache[name] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let found = searchEnvPATH(name) ?? searchLoginShell(name)
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
