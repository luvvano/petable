import Foundation
import AgentRuntime
import GraphCore

/// Оркестрация одного LLM-этапа: адаптер → события → журнал → переход
/// машины состояний. Точка, где чистый Engine встречается с асинхронным
/// миром; сама остаётся без Process — исполнитель приходит протоколом
/// AgentAdapter, часы — параметром (тестируется FakeAdapter'ом, 5A).
public struct StageRunner: Sendable {
    public let store: EventStore
    public let registry: AdapterRegistry
    public let now: @Sendable () -> Date

    public init(store: EventStore, registry: AdapterRegistry, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.registry = registry
        self.now = now
    }

    public struct StageResult: Sendable {
        public let run: OrganizationRun
        /// Вердикт этапа; nil — этап упал/оборвался. Демону нужен для
        /// decompose (подзадачи спавнятся из вердикта).
        public let verdict: Verdict?
    }

    /// Исполняет ТЕКУЩИЙ этап запуска: журналирует события, применяет
    /// вердикт к машине состояний, пишет слепок. Возвращает обновлённый
    /// запуск и вердикт. Worktree уже подготовлен вызывающим (демоном).
    public func runCurrentStage(
        _ run: OrganizationRun,
        worktree: URL,
        extraContext: String = ""
    ) async -> StageResult {
        guard let stage = run.currentStage else {
            return StageResult(
                run: finish(Engine.stageFailed(run, reason: "этап пропал из снапшота"), run: run),
                verdict: nil
            )
        }
        guard let employee = run.employee(for: stage) else {
            return StageResult(
                run: finish(
                    Engine.stageFailed(run, reason: "У этапа «\(stage.name)» нет сотрудника"),
                    run: run
                ),
                verdict: nil
            )
        }
        guard let adapter = registry.adapter(for: employee.adapter) else {
            // «CLI не найден» — состояние интерфейса (матрица 4A), не тихий сбой.
            return StageResult(
                run: finish(
                    Engine.stageFailed(
                        run, reason: "Исполнитель «\(employee.adapter.cli)» не установлен"
                    ),
                    run: run
                ),
                verdict: nil
            )
        }

        append(run, .init(seq: 0, date: now(), kind: .stageStarted, stageID: stage.id))

        let prompt = Self.prompt(run: run, stage: stage, employee: employee, extra: extraContext)
        let request = AgentRequest(
            prompt: prompt,
            workingDirectory: worktree,
            config: employee.adapter,
            resumeSessionID: run.stageSessions[stage.id]
        )

        var updated = run
        for await event in adapter.run(request) {
            switch event {
            case let .started(sessionID):
                updated.stageSessions[stage.id] = sessionID
            case let .log(text):
                append(updated, .init(seq: 0, date: now(), kind: .log, stageID: stage.id, text: text))
            case let .artifact(kind, path):
                append(updated, .init(
                    seq: 0, date: now(), kind: .artifact, stageID: stage.id,
                    text: path, status: kind
                ))
            case let .needsInput(prompt):
                append(updated, .init(
                    seq: 0, date: now(), kind: .needsInput, stageID: stage.id, text: prompt
                ))
                return StageResult(
                    run: finish(Engine.inputRequested(updated, prompt: prompt), run: updated),
                    verdict: nil
                )
            case let .finished(verdict, usage):
                updated.costEstimate += usage.costEstimate
                append(updated, .init(
                    seq: 0, date: now(), kind: .stageFinished, stageID: stage.id,
                    text: verdict.note, status: verdict.status.rawValue, cost: usage.costEstimate
                ))
                return StageResult(
                    run: finish(
                        Engine.stageFinished(updated, verdict: verdict, now: now()),
                        run: updated
                    ),
                    verdict: verdict
                )
            case let .failed(reason):
                append(updated, .init(
                    seq: 0, date: now(), kind: .stageFailed, stageID: stage.id, text: reason
                ))
                return StageResult(
                    run: finish(Engine.stageFailed(updated, reason: reason), run: updated),
                    verdict: nil
                )
            }
        }
        // Поток закончился без терминального события — процесс исчез.
        return StageResult(
            run: finish(
                Engine.stageFailed(updated, reason: "Стрим оборвался без вердикта"),
                run: updated
            ),
            verdict: nil
        )
    }

    /// Промпт этапа: роль сотрудника + шаблон этапа + задача (+ контекст
    /// чата при рестарте, П9) + обязательный вердикт-блок (T5).
    static func prompt(
        run: OrganizationRun,
        stage: OrgStage,
        employee: Employee,
        extra: String
    ) -> String {
        var parts: [String] = []
        if !employee.rolePrompt.isEmpty { parts.append(employee.rolePrompt) }
        if !stage.promptTemplate.isEmpty { parts.append(stage.promptTemplate) }
        parts.append("Задача \(run.task.jiraKey.isEmpty ? "" : "[\(run.task.jiraKey)] ")«\(run.task.title)».")
        if !run.task.details.isEmpty { parts.append(run.task.details) }
        if !run.statusReason.isEmpty { parts.append("Причина возврата: \(run.statusReason)") }
        if !extra.isEmpty { parts.append(extra) }
        parts.append(verdictInstruction(for: stage.kind))
        return parts.joined(separator: "\n\n")
    }

    /// Требование вердикт-блока в финале ответа (T5).
    static func verdictInstruction(for kind: StageKind) -> String {
        switch kind {
        case .review:
            return """
            Заверши ответ ровно одним JSON-блоком вердикта:
            {"status":"done"|"changesRequested","note":"краткое обоснование"}
            """
        case .decompose:
            return """
            Заверши ответ ровно одним JSON-блоком:
            {"status":"done","subtasks":[{"title":"…","taskType":"…","repo":"…"}]}
            """
        default:
            return """
            Заверши ответ ровно одним JSON-блоком:
            {"status":"done"|"cannotComplete","note":"кратко"}
            """
        }
    }

    // MARK: Журнал

    private func append(_ run: OrganizationRun, _ event: RunEvent) {
        try? store.append(event, orgID: run.orgID, runID: run.id)
    }

    /// Терминальная запись перехода + слепок состояния (восстановление
    /// без реплея: последний snapshot + хвост, П0).
    private func finish(_ transitioned: OrganizationRun, run: OrganizationRun) -> OrganizationRun {
        append(run, .init(seq: 0, date: now(), kind: .snapshot, run: transitioned))
        if transitioned.status == .needsAttention {
            append(run, .init(
                seq: 0, date: now(), kind: .needsAttention, text: transitioned.statusReason
            ))
        }
        if transitioned.status == .finished {
            append(run, .init(
                seq: 0, date: now(), kind: .runFinished,
                status: transitioned.outcome?.rawValue
            ))
        }
        return transitioned
    }
}
