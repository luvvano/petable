import Foundation
import OrgEngine

/// Установка и обновление движка-демона из приложения (П0): бинарь
/// petable-daemon лежит в ресурсах бандла; установка = копия в стабильный
/// путь `~/Library/Application Support/Petable` + LaunchAgent-plist +
/// `launchctl bootstrap`. Обновление поверх активных этапов — только
/// после drain (оркеструет OrganizationController).
enum DaemonManager {
    static let label = petableDaemonMachService

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Petable", isDirectory: true)
    }

    static var installedBinary: URL {
        supportDir.appendingPathComponent("petable-daemon")
    }

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Бинарь демона из ресурсов бандла; nil — сборка без него
    /// (скрипт-фаза «Embed daemon» не отработала).
    static var bundledBinary: URL? {
        Bundle.main.url(forResource: "petable-daemon", withExtension: nil)
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
            && FileManager.default.fileExists(atPath: installedBinary.path)
    }

    /// Бинарь в бандле отличается от установленного — движок пора
    /// обновить. Сравнение содержимого: версии-строки у демона нет,
    /// одинаковый код даёт одинаковый файл (SPM-кэш).
    static var updateAvailable: Bool {
        guard let bundled = bundledBinary,
              let fresh = try? Data(contentsOf: bundled),
              let installed = try? Data(contentsOf: installedBinary)
        else { return false }
        return fresh != installed
    }

    enum InstallError: LocalizedError {
        case noBundledBinary
        case bootstrapFailed(String)

        var errorDescription: String? {
            switch self {
            case .noBundledBinary:
                return "в сборке приложения нет бинаря демона"
            case let .bootstrapFailed(output):
                return "launchctl bootstrap: \(output)"
            }
        }
    }

    /// bootout старого → копия бинаря → plist → bootstrap. Идемпотентно.
    /// Прошлый инстанс демона умирает; свежий поднимет запуски через
    /// recovery из event-log (П0).
    static func install() throws {
        guard let bundled = bundledBinary else { throw InstallError.noBundledBinary }
        launchctl("bootout", "gui/\(getuid())/\(label)")
        try FileManager.default.createDirectory(
            at: supportDir, withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: installedBinary.path) {
            try FileManager.default.removeItem(at: installedBinary)
        }
        try FileManager.default.copyItem(at: bundled, to: installedBinary)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(label)</string>
          <key>Program</key><string>\(installedBinary.path)</string>
          <key>MachServices</key><dict><key>\(label)</key><true/></dict>
          <key>StandardErrorPath</key><string>\(supportDir.appendingPathComponent("daemon.log").path)</string>
        </dict>
        </plist>
        """
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        let result = launchctl("bootstrap", "gui/\(getuid())", plistURL.path)
        guard result.exitCode == 0 else {
            throw InstallError.bootstrapFailed(result.output)
        }
    }

    /// Перезапуск установленного демона БЕЗ замены бинаря: свежий процесс
    /// переищет CLI (план устранения «исполнитель не установлен»).
    static func restart() throws {
        launchctl("bootout", "gui/\(getuid())/\(label)")
        let result = launchctl("bootstrap", "gui/\(getuid())", plistURL.path)
        guard result.exitCode == 0 else {
            throw InstallError.bootstrapFailed(result.output)
        }
    }

    @discardableResult
    private static func launchctl(_ args: String...) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (127, "\(error)") }
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        return (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
