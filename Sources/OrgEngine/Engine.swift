import Foundation
import AgentRuntime
import GraphCore

/// Машина состояний запуска — ЧИСТЫЕ переходы: вход (запуск + событие) →
/// новый запуск. Ни Process, ни файлов, ни часов — время и side effects
/// приносит вызывающий (демон). Вся логика тестируется FakeAdapter'ом
/// и голыми переходами (решение 5A).
public enum Engine {
    /// Лимит единого счётчика возвратов задачи (П5).
    public static let returnLimit = 3

    public enum EngineError: Error, Equatable {
        /// Тип задачи не задан или без маршрута — вопрос человеку до старта.
        case noRoute
        /// Флоу не проходит валидатор (гейт старта, T1).
        case invalidFlow
        /// Репозиторий задачи не разрешён.
        case noRepo
    }

    // MARK: Старт

    /// Гейт старта: маршрут → снапшот → стартовый этап.
    public static func startRun(
        organization: Organization,
        task: OrgTask,
        now: Date,
        runID: UUID = UUID()
    ) throws -> OrganizationRun {
        guard let typeID = task.taskTypeID,
              let flow = organization.flow(for: typeID)
        else { throw EngineError.noRoute }
        guard flow.validate().isEmpty, let start = flow.startStage else {
            throw EngineError.invalidFlow
        }
        guard let repoID = task.repoID,
              let repo = organization.repos.first(where: { $0.id == repoID })
        else { throw EngineError.noRepo }

        // Ветка с runID — коллизии при повторном запуске исключены (T4).
        let key = task.jiraKey.isEmpty ? task.id.uuidString.prefix(8).lowercased() : task.jiraKey
        let branch = "org/\(key)-\(runID.uuidString.prefix(6).lowercased())"

        return OrganizationRun(
            id: runID,
            orgID: organization.orgID,
            task: task,
            flow: flow,
            employees: organization.employees,
            repo: repo,
            branchName: branch,
            startStageID: start.id,
            startedAt: now
        )
    }

    // MARK: Переходы

    /// Этап завершился вердиктом сотрудника.
    public static func stageFinished(_ run: OrganizationRun, verdict: Verdict, now: Date) -> OrganizationRun {
        var run = run
        switch verdict.status {
        case .done:
            guard let stage = run.currentStage else { return needsAttention(run, "этап пропал из снапшота") }
            if stage.kind == .decompose {
                return decomposed(run, verdict: verdict)
            }
            if stage.gate == .human || stage.kind == .merge {
                run.status = .waitingGate
                run.statusReason = ""
                return run
            }
            return advance(run, now: now)
        case .changesRequested:
            return returnToWork(run, reason: verdict.note.isEmpty ? "ревьюер вернул" : verdict.note, now: now)
        case .cannotComplete:
            return needsAttention(run, verdict.note.isEmpty ? "сотрудник не смог завершить" : verdict.note)
        }
    }

    /// Этап упал: невалидный вердикт, краш CLI, таймаут.
    public static func stageFailed(_ run: OrganizationRun, reason: String) -> OrganizationRun {
        needsAttention(run, reason)
    }

    /// Вопрос CLI (needsInput): fallback П2 — «требует внимания», ответ
    /// человека уйдёт рестартом-с-контекстом.
    public static func inputRequested(_ run: OrganizationRun, prompt: String) -> OrganizationRun {
        needsAttention(run, "Вопрос сотрудника: \(prompt)")
    }

    /// Тест-этап: exit 0.
    public static func testPassed(_ run: OrganizationRun, now: Date) -> OrganizationRun {
        advance(run, now: now)
    }

    /// Тест-этап: exit ≠ 0 — возврат с выводом тестов (П5).
    public static func testFailed(_ run: OrganizationRun, output: String, now: Date) -> OrganizationRun {
        returnToWork(run, reason: "Тесты упали: \(output.prefix(300))", now: now)
    }

    /// Принять на гейте. На merge-этапе — в очередь merge (Approve →
    /// rebase → повторные тесты → merge, П5).
    public static func approve(_ run: OrganizationRun, now: Date) -> OrganizationRun {
        guard run.status == .waitingGate, let stage = run.currentStage else { return run }
        var run = run
        if stage.kind == .merge {
            run.status = .merging
            run.statusReason = ""
            return run
        }
        return advance(run, now: now)
    }

    /// Вернуть с гейта с комментарием.
    public static func reject(_ run: OrganizationRun, comment: String, now: Date) -> OrganizationRun {
        guard run.status == .waitingGate else { return run }
        return returnToWork(run, reason: comment.isEmpty ? "возвращено с гейта" : comment, now: now)
    }

    /// Merge прошёл (rebase + повторные тесты + merge).
    public static func mergeSucceeded(_ run: OrganizationRun, now: Date) -> OrganizationRun {
        var run = run
        run.status = .finished
        run.outcome = .merged
        run.finishedAt = now
        return run
    }

    /// Повторные тесты после rebase упали — одобрение аннулируется,
    /// возврат со счётчиком; нужен новый Принять после доработки (П5).
    public static func mergeTestsFailed(_ run: OrganizationRun, output: String, now: Date) -> OrganizationRun {
        returnToWork(run, reason: "Тесты после rebase упали: \(output.prefix(300))", now: now)
    }

    /// Конфликт rebase — «требует внимания» (П5).
    public static func rebaseConflict(_ run: OrganizationRun) -> OrganizationRun {
        needsAttention(run, "Конфликт rebase перед merge")
    }

    /// Отмена человеком.
    public static func cancel(_ run: OrganizationRun, now: Date) -> OrganizationRun {
        var run = run
        run.status = .finished
        run.outcome = .cancelled
        run.finishedAt = now
        return run
    }

    /// Закрыть из «требует внимания» без merge.
    public static func close(_ run: OrganizationRun, now: Date) -> OrganizationRun {
        var run = run
        run.status = .finished
        run.outcome = .closed
        run.finishedAt = now
        return run
    }

    /// Восстановление после рестарта демона: прерванный этап рестартует
    /// с чистого worktree (некоммиченное отброшено); терминальные и
    /// ждущие человека состояния не трогаются (П0).
    public static func recovered(_ run: OrganizationRun) -> OrganizationRun {
        var run = run
        if run.status == .merging {
            // Merge мог уйти вовне — recovery обязан сверить намерения (T2)
            // прежде чем продолжать; до сверки — внимание человеку.
            run.status = .needsAttention
            run.statusReason = "Рестарт во время merge: сверить намерения"
        }
        return run
    }

    // MARK: Декомпозиция (слайс 8)

    /// Decompose-этап выдал подзадачи: родитель переходит на join и ждёт
    /// детей. Спавн дочерних запусков — забота демона (нужна организация
    /// для резолвинга типов/репо по именам); валидный флоу гарантирует
    /// join среди достижимых (T1).
    static func decomposed(_ run: OrganizationRun, verdict: Verdict) -> OrganizationRun {
        var run = run
        guard !verdict.subtasks.isEmpty else {
            return needsAttention(run, "Декомпозиция без подзадач — уточните постановку")
        }
        guard let joinID = run.currentStage?.next.first,
              run.flow.stage(joinID)?.kind == .join
        else { return needsAttention(run, "После декомпозиции нет join-этапа") }
        run.currentStageID = joinID
        run.path.append(joinID)
        run.status = .waitingChildren
        run.statusReason = ""
        return run
    }

    /// Ребёнок пришёл к терминалу: родитель завершается, когда терминальны
    /// все. Все merged → родитель merged (join в v1 терминален); любой
    /// сбой/отмена → «требует внимания» (Модель данных).
    public static func childrenSettled(
        _ run: OrganizationRun,
        outcomes: [RunOutcome?],
        now: Date
    ) -> OrganizationRun {
        var run = run
        guard run.status == .waitingChildren else { return run }
        guard outcomes.allSatisfy({ $0 != nil }) else { return run } // ещё едут
        if outcomes.allSatisfy({ $0 == .merged }) {
            run.status = .finished
            run.outcome = .merged
            run.finishedAt = now
            return run
        }
        return needsAttention(run, "Дочерние запуски завершились не merge — разберите ветки")
    }

    // MARK: Внутреннее

    private static func advance(_ run: OrganizationRun, now: Date) -> OrganizationRun {
        var run = run
        guard let stage = run.currentStage else { return needsAttention(run, "этап пропал из снапшота") }
        let next = stage.next.compactMap { run.flow.stage($0) }
        guard let target = next.first else {
            // Терминал без merge-этапа валидатор не пропускает; сюда
            // попадает только merge как последний этап.
            return run
        }
        if next.count > 1 {
            // Ветвление вне decompose валидатор не описывает — честный стоп.
            return needsAttention(run, "Параллельные ветки без декомпозиции не поддержаны")
        }
        run.currentStageID = target.id
        run.path.append(target.id)
        // Merge — гейт без LLM: вход в него сразу ждёт человека (П5).
        run.status = target.kind == .merge ? .waitingGate : .running
        run.statusReason = ""
        return run
    }

    private static func returnToWork(_ run: OrganizationRun, reason: String, now: Date) -> OrganizationRun {
        var run = run
        run.returnCount += 1
        guard run.returnCount <= returnLimit else {
            return needsAttention(run, "Лимит возвратов (\(returnLimit)) исчерпан: \(reason)")
        }
        // Ближайший work-этап вверх по пути токена (П5).
        guard let index = run.path.lastIndex(where: { run.flow.stage($0)?.kind == .work }) else {
            return needsAttention(run, "Некуда возвращать: во флоу нет work-этапа выше")
        }
        run.path = Array(run.path.prefix(through: index))
        run.currentStageID = run.path[index]
        run.status = .running
        run.statusReason = reason
        return run
    }

    private static func needsAttention(_ run: OrganizationRun, _ reason: String) -> OrganizationRun {
        var run = run
        run.status = .needsAttention
        run.statusReason = reason
        return run
    }
}
