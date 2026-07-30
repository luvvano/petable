import Foundation
import Testing
import AgentRuntime
@testable import OrgEngine
import GraphCore

/// Организация с дефолтным флоу «Разработка → Ревью → Тесты → Merge»,
/// репозиторием и задачей, готовой к запуску.
private func makeFixture() -> (Organization, OrgTask) {
    var org = Organization.makeDefault()
    let repo = RepoRef(name: "demo", path: "/tmp/demo", testCommand: "swift test")
    org.repos = [repo]
    let task = OrgTask(
        title: "Экспорт отчёта",
        taskTypeID: org.taskTypes[0].id,
        repoID: repo.id,
        jiraKey: "DN-341"
    )
    return (org, task)
}

private let t0 = Date(timeIntervalSince1970: 1000)

@Suite("Движок: старт запуска")
struct EngineStartTests {
    @Test("Старт: снапшот, ветка с runID, стартовый этап work")
    func start() throws {
        let (org, task) = makeFixture()
        let run = try Engine.startRun(organization: org, task: task, now: t0)
        #expect(run.currentStage?.kind == .work)
        #expect(run.status == .running)
        #expect(run.branchName.hasPrefix("org/DN-341-"))
        #expect(run.branchName.count > "org/DN-341-".count) // runID-суффикс (T4)
        #expect(run.flow == org.flows[0])
        #expect(run.path.count == 1)
    }

    @Test("Тип без маршрута → noRoute (вопрос человеку, не догадка)")
    func noRoute() {
        let (org, task) = makeFixture()
        var orphan = task
        orphan.taskTypeID = UUID()
        #expect(throws: Engine.EngineError.noRoute) {
            try Engine.startRun(organization: org, task: orphan, now: t0)
        }
    }

    @Test("Невалидный флоу не стартует (гейт старта T1)")
    func invalidFlowBlocked() {
        var (org, task) = makeFixture()
        org.flows[0].stages.removeAll { $0.kind == .merge } // терминал пропал
        #expect(throws: Engine.EngineError.invalidFlow) {
            try Engine.startRun(organization: org, task: task, now: t0)
        }
    }

    @Test("Задача без репозитория → noRepo")
    func noRepo() {
        let (org, task) = makeFixture()
        var homeless = task
        homeless.repoID = nil
        #expect(throws: Engine.EngineError.noRepo) {
            try Engine.startRun(organization: org, task: homeless, now: t0)
        }
    }
}

@Suite("Движок: счастливый путь и возвраты")
struct EngineFlowTests {
    private func started() throws -> OrganizationRun {
        let (org, task) = makeFixture()
        return try Engine.startRun(organization: org, task: task, now: t0)
    }

    @Test("Счастливый путь: work → review → tests → гейт merge → merge → merged")
    func happyPath() throws {
        var run = try started()
        run = Engine.stageFinished(run, verdict: Verdict(status: .done), now: t0)
        #expect(run.currentStage?.kind == .review)
        run = Engine.stageFinished(run, verdict: Verdict(status: .done), now: t0)
        #expect(run.currentStage?.kind == .test)
        run = Engine.testPassed(run, now: t0)
        #expect(run.currentStage?.kind == .merge)
        #expect(run.status == .waitingGate) // вход в merge = гейт, человек всегда (П5)
        run = Engine.approve(run, now: t0)
        #expect(run.status == .merging)
        run = Engine.mergeSucceeded(run, now: t0.addingTimeInterval(60))
        #expect(run.status == .finished)
        #expect(run.outcome == .merged)
        #expect(run.summary?.returnCount == 0)
    }

    @Test("changesRequested ревьюера: возврат на ближайший work, счётчик растёт, путь усечён")
    func reviewReturn() throws {
        var run = try started()
        run = Engine.stageFinished(run, verdict: Verdict(status: .done), now: t0)
        run = Engine.stageFinished(
            run, verdict: Verdict(status: .changesRequested, note: "нет тестов"), now: t0
        )
        #expect(run.currentStage?.kind == .work)
        #expect(run.returnCount == 1)
        #expect(run.status == .running)
        #expect(run.statusReason == "нет тестов")
        #expect(run.path.count == 1)
    }

    @Test("Провал тестов — тот же возврат; ревью+тесты+Reject делят один счётчик (П5)")
    func unifiedReturnCounter() throws {
        var run = try started()
        // 1: ревьюер вернул
        run = Engine.stageFinished(run, verdict: Verdict(status: .done), now: t0)
        run = Engine.stageFinished(run, verdict: Verdict(status: .changesRequested), now: t0)
        #expect(run.returnCount == 1)
        // 2: тесты упали
        run = Engine.stageFinished(run, verdict: Verdict(status: .done), now: t0)
        run = Engine.stageFinished(run, verdict: Verdict(status: .done), now: t0)
        run = Engine.testFailed(run, output: "2 failed", now: t0)
        #expect(run.returnCount == 2)
        #expect(run.currentStage?.kind == .work)
        // 3: человек вернул с финального гейта
        run = Engine.stageFinished(run, verdict: Verdict(status: .done), now: t0)
        run = Engine.stageFinished(run, verdict: Verdict(status: .done), now: t0)
        run = Engine.testPassed(run, now: t0)
        run = Engine.stageFinished(run, verdict: Verdict(status: .done), now: t0)
        run = Engine.reject(run, comment: "не то", now: t0)
        #expect(run.returnCount == 3)
        #expect(run.status == .running)
        // 4: лимит исчерпан → требует внимания, не крутится вечно
        run = Engine.stageFinished(run, verdict: Verdict(status: .done), now: t0)
        run = Engine.stageFinished(run, verdict: Verdict(status: .changesRequested), now: t0)
        #expect(run.returnCount == 4)
        #expect(run.status == .needsAttention)
        #expect(run.statusReason.contains("Лимит возвратов"))
    }

    @Test("cannotComplete и failed → требует внимания с причиной")
    func attentionStates() throws {
        var run = try started()
        run = Engine.stageFinished(
            run, verdict: Verdict(status: .cannotComplete, note: "нет доступа"), now: t0
        )
        #expect(run.status == .needsAttention)
        #expect(run.statusReason == "нет доступа")

        var run2 = try started()
        run2 = Engine.stageFailed(run2, reason: "процесс убит")
        #expect(run2.status == .needsAttention)

        var run3 = try started()
        run3 = Engine.inputRequested(run3, prompt: "какой пароль?")
        #expect(run3.status == .needsAttention)
        #expect(run3.statusReason.contains("какой пароль?"))
    }

    @Test("Провал повторных тестов после rebase аннулирует одобрение (П5)")
    func mergeAnnulled() throws {
        var run = try started()
        run = Engine.stageFinished(run, verdict: Verdict(status: .done), now: t0)
        run = Engine.stageFinished(run, verdict: Verdict(status: .done), now: t0)
        run = Engine.testPassed(run, now: t0)
        run = Engine.stageFinished(run, verdict: Verdict(status: .done), now: t0)
        run = Engine.approve(run, now: t0)
        #expect(run.status == .merging)
        run = Engine.mergeTestsFailed(run, output: "1 failed", now: t0)
        #expect(run.status == .running)
        #expect(run.currentStage?.kind == .work)
        #expect(run.returnCount == 1)

        // Конфликт rebase → внимание.
        var run2 = try started()
        run2.status = .merging
        run2 = Engine.rebaseConflict(run2)
        #expect(run2.status == .needsAttention)
    }

    @Test("Approve вне гейта — no-op; отмена и закрытие терминальны")
    func guardsAndTerminals() throws {
        var run = try started()
        let same = Engine.approve(run, now: t0)
        #expect(same == run)

        run = Engine.cancel(run, now: t0)
        #expect(run.outcome == .cancelled)

        var run2 = try started()
        run2 = Engine.stageFailed(run2, reason: "х")
        run2 = Engine.close(run2, now: t0)
        #expect(run2.outcome == .closed)
        #expect(run2.summary?.outcome == .closed)
    }

    @Test("Recovery: merging → сверка намерений (требует внимания), running не трогается")
    func recovery() throws {
        var run = try started()
        run.status = .merging
        let recovered = Engine.recovered(run)
        #expect(recovered.status == .needsAttention)
        #expect(recovered.statusReason.contains("сверить намерения"))

        let running = try started()
        #expect(Engine.recovered(running) == running)
    }
}
