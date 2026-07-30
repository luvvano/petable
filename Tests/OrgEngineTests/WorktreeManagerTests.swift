import Foundation
import Testing
@testable import OrgEngine
import GraphCore

/// Живой git в временном каталоге: реальный жизненный цикл worktree.
@Suite("WorktreeManager: git-жизненный цикл запуска", .serialized)
struct WorktreeManagerTests {
    private let t0 = Date(timeIntervalSince1970: 7000)

    /// Репозиторий с одним коммитом (main) + организация с задачей.
    private func makeWorld() throws -> (WorktreeManager, OrganizationRun, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("petable-git-\(UUID().uuidString)")
        let repoURL = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)
        let manager = WorktreeManager(root: base.appendingPathComponent("state"))
        try manager.git(repoURL, "init", "-b", "main")
        try manager.git(repoURL, "-c", "user.name=t", "-c", "user.email=t@local",
                        "commit", "--allow-empty", "-m", "init")
        try "print(1)".write(
            to: repoURL.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8
        )
        try manager.git(repoURL, "add", "-A")
        try manager.git(repoURL, "-c", "user.name=t", "-c", "user.email=t@local",
                        "commit", "-m", "code")

        var org = Organization.makeDefault()
        let repo = RepoRef(name: "demo", path: repoURL.path)
        org.repos = [repo]
        let task = OrgTask(
            title: "Задача", taskTypeID: org.taskTypes[0].id, repoID: repo.id, jiraKey: "DN-7"
        )
        let run = try Engine.startRun(organization: org, task: task, now: t0)
        return (manager, run, repoURL)
    }

    @Test("Создание: ветка org/<key>-<runID6>, worktree, base SHA, ref-пин от GC (T4)")
    func createWorktree() throws {
        let (manager, run, repoURL) = try makeWorld()
        let base = try manager.createWorktree(run: run)
        #expect(!base.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: manager.worktreeURL(runID: run.id).appendingPathComponent("main.swift").path
        ))
        let branches = try manager.git(repoURL, "branch", "--list", run.branchName)
        #expect(branches.contains(run.branchName))
        let pin = try manager.git(repoURL, "rev-parse", "refs/petable/\(run.id.uuidString)")
        #expect(pin == base)
    }

    @Test("Harness (П8): файл вне индекса через per-worktree exclude; файл репо не перезаписывается")
    func harness() throws {
        let (manager, run, _) = try makeWorld()
        try manager.createWorktree(run: run)
        let placed = try manager.materializeHarness(
            run: run, fileName: "AGENTS.md", contents: "инструкции"
        )
        #expect(placed)
        // Не попадает в дифф work-этапа.
        let sha = try manager.commitStageArtifact(run: run, message: "этап")
        #expect(sha == nil) // единственное изменение — harness, он вне индекса

        // Коллизия с файлом репозитория → false, файл не тронут.
        let collision = try manager.materializeHarness(
            run: run, fileName: "main.swift", contents: "перезапись"
        )
        #expect(collision == false)
        let contents = try String(
            contentsOf: manager.worktreeURL(runID: run.id).appendingPathComponent("main.swift"),
            encoding: .utf8
        )
        #expect(contents == "print(1)")
    }

    @Test("Коммит артефакта: SHA при изменениях, nil без них; reset отбрасывает некоммиченное (П0)")
    func commitAndReset() throws {
        let (manager, run, _) = try makeWorld()
        try manager.createWorktree(run: run)
        let worktree = manager.worktreeURL(runID: run.id)
        try "print(2)".write(
            to: worktree.appendingPathComponent("feature.swift"), atomically: true, encoding: .utf8
        )
        let sha = try manager.commitStageArtifact(run: run, message: "фича")
        #expect(sha?.isEmpty == false)

        // Полузаписанное состояние → рестарт этапа с чистого worktree.
        try "мусор".write(
            to: worktree.appendingPathComponent("halfdone.swift"), atomically: true, encoding: .utf8
        )
        try manager.resetToCleanState(run: run)
        #expect(!FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent("halfdone.swift").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: worktree.appendingPathComponent("feature.swift").path
        ))
    }

    @Test("Финал П5: rebase на default → merge; уборка worktree")
    func rebaseAndMerge() throws {
        let (manager, run, repoURL) = try makeWorld()
        try manager.createWorktree(run: run)
        let worktree = manager.worktreeURL(runID: run.id)
        try "print(3)".write(
            to: worktree.appendingPathComponent("feature.swift"), atomically: true, encoding: .utf8
        )
        _ = try manager.commitStageArtifact(run: run, message: "фича DN-7")

        // Default уехал вперёд, пока сотрудник работал (не конфликтуя).
        try "// readme".write(
            to: repoURL.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )
        try manager.git(repoURL, "add", "-A")
        try manager.git(repoURL, "-c", "user.name=t", "-c", "user.email=t@local",
                        "commit", "-m", "parallel")

        let rebased = try manager.rebaseOnDefault(run: run, defaultBranch: "main")
        guard case .merged = rebased else {
            Issue.record("неожиданный конфликт rebase")
            return
        }
        let mergedSHA = try manager.mergeIntoDefault(run: run, defaultBranch: "main")
        #expect(!mergedSHA.isEmpty)
        let log = try manager.git(repoURL, "log", "--oneline", "-3")
        #expect(log.contains("фича DN-7"))

        try manager.removeWorktree(run: run)
        #expect(!FileManager.default.fileExists(atPath: worktree.path))
    }

    @Test("Конфликт rebase → .rebaseConflict, worktree не остаётся в half-rebase")
    func rebaseConflict() throws {
        let (manager, run, repoURL) = try makeWorld()
        try manager.createWorktree(run: run)
        let worktree = manager.worktreeURL(runID: run.id)
        try "print(branch)".write(
            to: worktree.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8
        )
        _ = try manager.commitStageArtifact(run: run, message: "правка main.swift")

        // Default конфликтующе правит тот же файл.
        try "print(default)".write(
            to: repoURL.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8
        )
        try manager.git(repoURL, "add", "-A")
        try manager.git(repoURL, "-c", "user.name=t", "-c", "user.email=t@local",
                        "commit", "-m", "conflict")

        let result = try manager.rebaseOnDefault(run: run, defaultBranch: "main")
        #expect(result == .rebaseConflict)
        // rebase --abort вернул ветку в рабочее состояние.
        let status = try manager.git(worktree, "status", "--porcelain")
        #expect(status.isEmpty)
    }
}
