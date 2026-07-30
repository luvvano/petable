import Foundation
import Testing
@testable import OrgEngine
import GraphCore

@Suite("EventStore: журнал, карантин, намерения, реконсиляция")
struct EventStoreTests {
    private func makeStore() throws -> EventStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("petable-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return EventStore(root: root)
    }

    private func makeRun() -> OrganizationRun {
        var org = Organization.makeDefault()
        let repo = RepoRef(name: "demo", path: "/tmp/demo")
        org.repos = [repo]
        let task = OrgTask(title: "Задача", taskTypeID: org.taskTypes[0].id, repoID: repo.id)
        return try! Engine.startRun(
            organization: org, task: task, now: Date(timeIntervalSince1970: 1000)
        )
    }

    @Test("Append/load round-trip, слепок восстанавливает запуск")
    func roundTrip() throws {
        let store = try makeStore()
        let run = makeRun()
        let t = Date(timeIntervalSince1970: 2000)
        try store.append(
            RunEvent(seq: 0, date: t, kind: .runStarted), orgID: run.orgID, runID: run.id
        )
        try store.append(
            RunEvent(seq: 1, date: t, kind: .snapshot, run: run), orgID: run.orgID, runID: run.id
        )
        try store.append(
            RunEvent(seq: 2, date: t, kind: .log, text: "работаю"), orgID: run.orgID, runID: run.id
        )
        guard case let .events(events) = store.load(orgID: run.orgID, runID: run.id) else {
            Issue.record("broken вместо events")
            return
        }
        #expect(events.count == 3)
        #expect(EventStore.restoreRun(from: events) == run)
    }

    @Test("Карантин 3A: обрезанная хвостовая строка отбрасывается — запись не случилась")
    func truncatedTailDropped() throws {
        let store = try makeStore()
        let run = makeRun()
        let t = Date(timeIntervalSince1970: 2000)
        try store.append(
            RunEvent(seq: 0, date: t, kind: .snapshot, run: run), orgID: run.orgID, runID: run.id
        )
        let file = store.runDirectory(orgID: run.orgID, runID: run.id)
            .appendingPathComponent("events.jsonl")
        var data = try Data(contentsOf: file)
        data.append(Data(#"{"seq":1,"date":123,"ki"#.utf8)) // краш посреди записи
        try data.write(to: file)

        guard case let .events(events) = store.load(orgID: run.orgID, runID: run.id) else {
            Issue.record("обрезанный хвост уронил запуск")
            return
        }
        #expect(events.count == 1)
        #expect(EventStore.restoreRun(from: events) == run)
    }

    @Test("Карантин 3A: битая строка в СЕРЕДИНЕ → broken, но не крашлуп")
    func corruptMiddleIsBroken() throws {
        let store = try makeStore()
        let run = makeRun()
        let file = store.runDirectory(orgID: run.orgID, runID: run.id)
            .appendingPathComponent("events.jsonl")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let good = #"{"seq":0,"date":100,"kind":"runStarted"}"#
        try Data("мусор\n\(good)\n".utf8).write(to: file)
        guard case let .broken(reason) = store.load(orgID: run.orgID, runID: run.id) else {
            Issue.record("битая середина не помечена broken")
            return
        }
        #expect(reason.contains("№1"))
    }

    @Test("listRuns: битый каталог не роняет остальные (демон стартует дальше)")
    func brokenRunDoesNotSinkOthers() throws {
        let store = try makeStore()
        let run = makeRun()
        let t = Date(timeIntervalSince1970: 2000)
        try store.append(
            RunEvent(seq: 0, date: t, kind: .snapshot, run: run), orgID: run.orgID, runID: run.id
        )
        // Второй запуск — каталог без events.jsonl.
        let brokenID = UUID()
        try FileManager.default.createDirectory(
            at: store.runDirectory(orgID: run.orgID, runID: brokenID),
            withIntermediateDirectories: true
        )
        let all = store.listRuns(orgID: run.orgID)
        #expect(all.count == 2)
        guard case .events = all[run.id] else { Issue.record("живой запуск утонул"); return }
        guard case .broken = all[brokenID] else { Issue.record("битый не помечен"); return }
    }

    @Test("Интенты T2: намерение без подтверждения висит, с подтверждением — закрыто")
    func pendingIntents() {
        let t = Date(timeIntervalSince1970: 0)
        let events = [
            RunEvent(seq: 0, date: t, kind: .intent, intentKey: "merge:run1"),
            RunEvent(seq: 1, date: t, kind: .effectConfirmed, intentKey: "merge:run1"),
            RunEvent(seq: 2, date: t, kind: .intent, intentKey: "jira:run1"),
        ]
        #expect(EventStore.pendingIntents(in: events) == ["jira:run1"])
    }

    @Test("Осиротевшие PID собираются для kill до пересоздания worktree (П0)")
    func orphanPIDs() {
        let t = Date(timeIntervalSince1970: 0)
        let events = [
            RunEvent(seq: 0, date: t, kind: .processSpawned, pid: 101),
            RunEvent(seq: 1, date: t, kind: .processSpawned, pid: 202),
        ]
        #expect(EventStore.orphanPIDs(in: events) == [101, 202])
    }

    @Test("Реконсиляция идемпотентна по runID: копия документа не плодит дубликаты (П1′)")
    func reconcileIdempotent() throws {
        let store = try makeStore()
        var run = makeRun()
        run = Engine.cancel(run, now: Date(timeIntervalSince1970: 3000))
        try store.append(
            RunEvent(seq: 0, date: Date(timeIntervalSince1970: 3000), kind: .snapshot, run: run),
            orgID: run.orgID, runID: run.id
        )
        var org = Organization.makeDefault()
        org.orgID = run.orgID
        let summaries = store.summaries(orgID: run.orgID)
        #expect(summaries.count == 1)

        org.reconcile(summaries: summaries)
        #expect(org.runSummaries.count == 1)
        org.reconcile(summaries: summaries) // повторное открытие/копия
        #expect(org.runSummaries.count == 1)
        #expect(org.runSummaries[0].outcome == .cancelled)
    }

    @Test("Broken-запуск попадает в саммари outcome=broken — задача не исчезает молча")
    func brokenSummary() throws {
        let store = try makeStore()
        let orgID = UUID()
        let brokenID = UUID()
        try FileManager.default.createDirectory(
            at: store.runDirectory(orgID: orgID, runID: brokenID),
            withIntermediateDirectories: true
        )
        let summaries = store.summaries(orgID: orgID)
        #expect(summaries.map(\.outcome) == [.broken])
        #expect(summaries[0].runID == brokenID)
    }
}
