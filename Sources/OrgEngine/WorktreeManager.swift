import Foundation
import GraphCore

/// Git-жизненный цикл запуска (Модель данных дизайн-дока):
/// ветка `org/<key>-<runID6>` + worktree в `<root>/worktrees/<runID>`;
/// harness-файлы — через PER-WORKTREE exclude (`.git/worktrees/<name>/info/exclude`,
/// НЕ общий `.git/info/exclude` — тот утёк бы во все worktree репо, T7.1);
/// пины: base SHA при создании, ref `refs/petable/<runID>` — GC не съедает
/// точки форка (T4). Merge-этап: rebase на default → тесты → merge (П5).
public struct WorktreeManager: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public struct GitError: Error, Equatable {
        public let command: String
        public let output: String
    }

    public func worktreeURL(runID: UUID) -> URL {
        root.appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    /// Создаёт ветку от текущего default и worktree запуска.
    /// Возвращает base SHA (пин T4).
    @discardableResult
    /// `from` — базовый SHA (fork стартует от точки форка источника,
    /// пин refs/petable держит её от GC); nil/пусто — HEAD репозитория.
    public func createWorktree(run: OrganizationRun, from baseSHA: String? = nil) throws -> String {
        let repo = URL(fileURLWithPath: run.repo.path)
        let worktree = worktreeURL(runID: run.id)
        try FileManager.default.createDirectory(
            at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let base: String
        if let baseSHA, !baseSHA.isEmpty {
            base = baseSHA
        } else {
            base = try git(repo, "rev-parse", "HEAD")
        }
        try git(repo, "worktree", "add", "-b", run.branchName, worktree.path, base)
        // Пин от GC: точка форка живёт и после удаления ветки (T4).
        try git(repo, "update-ref", "refs/petable/\(run.id.uuidString)", base)
        return base
    }

    /// Материализует harness-файл сотрудника вне git-индекса (П8).
    /// Находка живого git (правит T7.1 дизайн-дока): `info/exclude` git
    /// читает из COMMON dir — per-worktree `$GIT_DIR/info/exclude` не
    /// действует, а общий утёк бы во все worktree репозитория. Поэтому
    /// изоляция — pathspec-исключением: имя пишется в
    /// `$GIT_DIR/petable-harness`, и коммит артефакта исключает эти пути.
    /// Файл, уже существующий В РЕПОЗИТОРИИ, не перезаписывается — вернёт
    /// false (инструкции тогда уходят append-to-system-prompt).
    @discardableResult
    public func materializeHarness(
        run: OrganizationRun,
        fileName: String,
        contents: String
    ) throws -> Bool {
        let worktree = worktreeURL(runID: run.id)
        let target = worktree.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: target.path) {
            return false
        }
        try contents.write(to: target, atomically: true, encoding: .utf8)
        let list = try harnessListFile(worktree: worktree)
        let existing = (try? String(contentsOf: list, encoding: .utf8)) ?? ""
        if !existing.split(separator: "\n").contains(Substring(fileName)) {
            try (existing + fileName + "\n").write(to: list, atomically: true, encoding: .utf8)
        }
        return true
    }

    /// Материализованные harness-имена этого worktree.
    public func harnessNames(run: OrganizationRun) -> [String] {
        let worktree = worktreeURL(runID: run.id)
        guard let list = try? harnessListFile(worktree: worktree),
              let contents = try? String(contentsOf: list, encoding: .utf8)
        else { return [] }
        return contents.split(separator: "\n").map(String.init)
    }

    private func harnessListFile(worktree: URL) throws -> URL {
        // $GIT_DIR worktree — приватный каталог .git/worktrees/<name>.
        let gitDir = try git(worktree, "rev-parse", "--absolute-git-dir")
        return URL(fileURLWithPath: gitDir).appendingPathComponent("petable-harness")
    }

    /// Коммит артефакта work-этапа при `finished: done` (П5); harness-файлы
    /// исключены pathspec'ом. Возвращает SHA (пин этапа в event-log, T4).
    /// Нечего коммитить — nil, не ошибка.
    public func commitStageArtifact(run: OrganizationRun, message: String) throws -> String? {
        let worktree = worktreeURL(runID: run.id)
        let excludes = harnessNames(run: run).map { ":(exclude)\($0)" }
        try git(worktree, ["add", "-A", "--", "."] + excludes)
        let status = try git(worktree, ["status", "--porcelain", "--", "."] + excludes)
        guard !status.isEmpty else { return nil }
        try git(worktree, ["-c", "user.name=petable", "-c", "user.email=petable@local",
                           "commit", "-m", message])
        return try git(worktree, "rev-parse", "HEAD")
    }

    /// Сброс к чистому состоянию ветки — рестарт этапа при recovery (П0):
    /// некоммиченное отбрасывается, этапы идемпотентны по построению.
    public func resetToCleanState(run: OrganizationRun) throws {
        let worktree = worktreeURL(runID: run.id)
        try git(worktree, "reset", "--hard", "HEAD")
        try git(worktree, "clean", "-fd")
    }

    public enum MergeResult: Equatable, Sendable {
        case merged(sha: String)
        case rebaseConflict
    }

    /// Финальный шаг П5: rebase ветки на актуальный default → merge
    /// (ff-only после rebase). Повторные тесты гоняет вызывающий МЕЖДУ
    /// rebase и merge — поэтому шаги разделены.
    public func rebaseOnDefault(run: OrganizationRun, defaultBranch: String) throws -> MergeResult {
        let worktree = worktreeURL(runID: run.id)
        do {
            try git(worktree, "fetch", ".", defaultBranch)
            try git(worktree, "rebase", defaultBranch)
        } catch {
            _ = try? git(worktree, "rebase", "--abort")
            return .rebaseConflict
        }
        return .merged(sha: try git(worktree, "rev-parse", "HEAD"))
    }

    /// Merge ветки запуска в default (после успешных повторных тестов).
    public func mergeIntoDefault(run: OrganizationRun, defaultBranch: String) throws -> String {
        let repo = URL(fileURLWithPath: run.repo.path)
        try git(repo, "checkout", defaultBranch)
        try git(repo, "merge", "--ff-only", run.branchName)
        return try git(repo, "rev-parse", "HEAD")
    }

    /// Push default и ветки запуска в origin после merge (T7.4). Возвращает
    /// https-URL коммита, когда remote распознан и push прошёл; иначе nil —
    /// комментарий в Jira деградирует до хеша с дифф-статом, битых ссылок
    /// не бывает. Отказ push — предупреждение, не блокер конвейера.
    public func pushAndCommitURL(
        run: OrganizationRun, defaultBranch: String, sha: String
    ) -> String? {
        let repo = URL(fileURLWithPath: run.repo.path)
        guard let remote = try? git(repo, "remote", "get-url", "origin"),
              (try? git(repo, "push", "origin", defaultBranch, run.branchName)) != nil
        else { return nil }
        return Self.commitURL(remote: remote, sha: sha)
    }

    /// `git@host:owner/repo.git` / `https://host/owner/repo(.git)` →
    /// `https://host/owner/repo/commit/<sha>`; непонятный remote — nil.
    static func commitURL(remote: String, sha: String) -> String? {
        var path = remote
        if let sshRange = path.range(of: "^[^@/]+@([^:]+):", options: .regularExpression) {
            let host = String(path[sshRange].dropLast().split(separator: "@").last ?? "")
            path = "https://\(host)/" + String(path[sshRange.upperBound...])
        }
        guard path.hasPrefix("https://") || path.hasPrefix("http://") else { return nil }
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        if path.hasSuffix("/") { path = String(path.dropLast()) }
        return "\(path)/commit/\(sha)"
    }

    /// Короткий дифф-стат merge-коммита — для комментария в Jira.
    public func diffStat(run: OrganizationRun, sha: String) -> String {
        let repo = URL(fileURLWithPath: run.repo.path)
        let stat = (try? git(repo, "show", "--stat", "--format=", sha)) ?? ""
        return String(stat.prefix(600))
    }

    /// Уборка: worktree удаляется после merge/отмены; при failed остаётся
    /// для разбора (Модель данных). Ref-пин живёт до ручной чистки истории.
    public func removeWorktree(run: OrganizationRun, keepBranch: Bool = false) throws {
        let repo = URL(fileURLWithPath: run.repo.path)
        let worktree = worktreeURL(runID: run.id)
        try git(repo, "worktree", "remove", "--force", worktree.path)
        if !keepBranch {
            _ = try? git(repo, "branch", "-D", run.branchName)
        }
    }

    // MARK: git

    @discardableResult
    func git(_ cwd: URL, _ arguments: String...) throws -> String {
        try git(cwd, arguments)
    }

    @discardableResult
    func git(_ cwd: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let stdout = String(
            data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0 else {
            let stderr = String(
                data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            ) ?? ""
            throw GitError(
                command: "git " + arguments.joined(separator: " "),
                output: stderr.isEmpty ? stdout : stderr
            )
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
