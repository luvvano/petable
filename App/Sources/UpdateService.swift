import AppKit
import SwiftUI
import UserNotifications

/// Самообновление приложения. petable собирается из репозитория, поэтому
/// «обновление» = origin/main ушёл вперёд SHA, встроенного в сборку
/// (PetableBuildSHA/PetableRepoPath пишет скрипт-фаза project.yml).
/// Проверка: fetch → сравнение SHA; «Обновить»: клон origin/main во
/// временный каталог → make build → подмена .app → перезапуск.
@MainActor
final class UpdateService: ObservableObject {
    enum State: Equatable {
        case idle
        /// Есть обновление: N новых коммитов до origin/main.
        case available(commits: Int, sha: String)
        case updating(step: String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let buildSHA: String?
    private let repoPath: String?
    private var checkLoop: Task<Void, Never>?
    /// «Позже»: не показывать плашку до следующего нового SHA.
    private var dismissedSHA: String?
    private var notifiedSHA: String?

    init() {
        buildSHA = Bundle.main.object(forInfoDictionaryKey: "PetableBuildSHA") as? String
        repoPath = Bundle.main.object(forInfoDictionaryKey: "PetableRepoPath") as? String
    }

    /// Проверка при старте и раз в час.
    func startPeriodicChecks() {
        guard checkLoop == nil else { return }
        checkLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func dismiss() {
        if case let .available(_, sha) = state { dismissedSHA = sha }
        state = .idle
    }

    func check() async {
        if case .updating = state { return }
        guard let buildSHA, buildSHA != "unknown", !buildSHA.isEmpty,
              let repoPath,
              FileManager.default.fileExists(atPath: repoPath + "/.git")
        else { return }
        let found = await Task.detached { () -> (sha: String, commits: Int)? in
            // Оффлайн — fetch молча падает, сравниваем с последним известным.
            _ = try? Self.run("/usr/bin/git", ["-C", repoPath, "fetch", "--quiet", "origin", "main"])
            guard let origin = try? Self.run(
                "/usr/bin/git", ["-C", repoPath, "rev-parse", "refs/remotes/origin/main"]
            ), origin != buildSHA else { return nil }
            // Сборка должна быть предком origin/main — иначе это не
            // «отстали», а разошлись (локальная ветка): не дёргаем.
            guard (try? Self.run(
                "/usr/bin/git", ["-C", repoPath, "merge-base", "--is-ancestor", buildSHA, origin]
            )) != nil else { return nil }
            let count = (try? Self.run(
                "/usr/bin/git", ["-C", repoPath, "rev-list", "--count", "\(buildSHA)..\(origin)"]
            )).flatMap { Int($0) } ?? 0
            return (origin, count)
        }.value
        guard let found, found.sha != dismissedSHA else { return }
        if case .updating = state { return }
        state = .available(commits: found.commits, sha: found.sha)
        if notifiedSHA != found.sha {
            notifiedSHA = found.sha
            let content = UNMutableNotificationContent()
            content.title = "Доступно обновление petable"
            content.body = "Новых коммитов: \(found.commits) — кнопка «Обновить» в приложении"
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: "petable-update-\(found.sha)", content: content, trigger: nil
                ),
                withCompletionHandler: nil
            )
        }
    }

    /// Клон → сборка → подмена бандла → перезапуск. Откат при ошибке
    /// установки: старая копия возвращается на место.
    func update() async {
        guard case let .available(_, sha) = state, let repoPath else { return }
        let bundleURL = Bundle.main.bundleURL
        do {
            state = .updating(step: "клонирую origin/main…")
            let staging = try await Task.detached { () throws -> URL in
                let root = FileManager.default.urls(
                    for: .applicationSupportDirectory, in: .userDomainMask
                )[0].appendingPathComponent("Petable/update", isDirectory: true)
                try? FileManager.default.removeItem(at: root)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let clone = root.appendingPathComponent("src", isDirectory: true)
                // --shared: объекты берутся из репо сборки, клон мгновенный;
                // checkout — detached ровно на origin/main.
                try Self.run("/usr/bin/git", ["clone", "--shared", "--no-checkout", repoPath, clone.path])
                try Self.run("/usr/bin/git", ["-C", clone.path, "checkout", "--force", "--detach", sha])
                return clone
            }.value
            state = .updating(step: "собираю новую версию (1–2 мин)…")
            try await Task.detached {
                try Self.run("/bin/zsh", ["-lc", "make build"], cwd: staging.path)
            }.value
            state = .updating(step: "устанавливаю и перезапускаю…")
            try await Task.detached {
                let newApp = staging.appendingPathComponent(
                    "build/DerivedData/Build/Products/Release/petable.app"
                )
                guard FileManager.default.fileExists(atPath: newApp.path) else {
                    throw UpdateError(message: "сборка не оставила petable.app")
                }
                let backup = bundleURL.deletingLastPathComponent()
                    .appendingPathComponent("petable.app.old")
                try? FileManager.default.removeItem(at: backup)
                try FileManager.default.moveItem(at: bundleURL, to: backup)
                do {
                    try FileManager.default.moveItem(at: newApp, to: bundleURL)
                } catch {
                    try? FileManager.default.moveItem(at: backup, to: bundleURL) // откат
                    throw error
                }
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.removeItem(at: staging.deletingLastPathComponent())
            }.value
            relaunch(bundleURL)
        } catch {
            let message = (error as? UpdateError)?.message
                ?? (error as? RunError)?.output
                ?? error.localizedDescription
            state = .failed("Обновление сорвалось: \(String(message.suffix(300)))")
        }
    }

    private func relaunch(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 0.7; /usr/bin/open \"\(url.path)\""]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: Процессы

    struct UpdateError: Error { let message: String }

    struct RunError: Error { let output: String }

    /// Запуск процесса; не-0 — RunError с хвостом вывода.
    @discardableResult
    nonisolated private static func run(
        _ executable: String, _ arguments: [String], cwd: String? = nil
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw RunError(output: output.isEmpty ? "\(executable) exit \(process.terminationStatus)" : output)
        }
        return output
    }
}

/// Плашка обновления — над контентом окна: нашёл → «Обновить»/«Позже»,
/// во время обновления — шаги, при срыве — причина и «Повторить».
struct UpdateBannerView: View {
    @ObservedObject var updater: UpdateService

    var body: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case let .available(commits, _):
            banner(tint: .blue) {
                Label(
                    commits > 0
                        ? "Доступно обновление petable — новых коммитов: \(commits)"
                        : "Доступно обновление petable",
                    systemImage: "arrow.down.circle"
                )
                Spacer()
                Button("Обновить") { Task { await updater.update() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Позже") { updater.dismiss() }
                    .controlSize(.small)
            }
        case let .updating(step):
            banner(tint: .blue) {
                ProgressView().controlSize(.small)
                Text("Обновляю: \(step)")
                Spacer()
            }
        case let .failed(message):
            banner(tint: .orange) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .lineLimit(2)
                Spacer()
                Button("Повторить проверку") {
                    updater.dismiss()
                    Task { await updater.check() }
                }
                .controlSize(.small)
            }
        }
    }

    private func banner(tint: Color, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: 10, content: content)
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(tint.opacity(0.08))
            .overlay(alignment: .bottom) {
                Divider()
            }
    }
}
