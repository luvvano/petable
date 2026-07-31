import Foundation
import AgentRuntime
import GraphCore

/// Ядро демона без XPC-обвязки: принимает Wire-команды как Data,
/// исполняет запуски, шлёт события подписчику. Будущий executable
/// оборачивает его в NSXPCListener (Codable-over-Data, 1A); тесты
/// говорят с ним напрямую — «пустой конвейер» слайса 2.
public actor DaemonCore {
    public let store: EventStore
    let registry: AdapterRegistry
    let worktrees: WorktreeManager
    let jira: any JiraGateway
    let github: GitHubClient
    let now: @Sendable () -> Date

    /// Активные запуски в памяти; источник правды — event-store.
    private var runs: [UUID: OrganizationRun] = [:]
    private var organizations: [UUID: Organization] = [:]
    /// Секреты Jira — ТОЛЬКО в памяти (Безопасность дизайн-дока);
    /// приходят ConfigureCommand при коннекте приложения.
    private var jiraConfig: JiraConfig?
    /// GitHub-токен — тоже только в памяти: агентное создание
    /// репозиториев под подзадачи декомпозиции (правка №5).
    private var githubToken: String?
    /// Очередь write-back в Jira: финалы, случившиеся без секретов
    /// (демон рестартовал, приложение закрыто), уходят при коннекте.
    private var pendingJira: [JiraWriteBack] = []
    /// Последний этап, о котором рассказали Jira, — дедуп синка статусов.
    private var jiraStageSync: [UUID: UUID] = [:]
    /// Подписчик событий (EventSink приложения): получает упакованные
    /// Wire-сообщения. Один клиент-владелец на orgID — T6 (упрощение v1:
    /// один подписчик на демона).
    private var sink: (@Sendable (Data) -> Void)?
    /// Drain перед обновлением (П0): новые этапы не начинаются, текущие
    /// дорабатывают. Снимается только рестартом демона.
    private var draining = false
    /// Исполняющиеся сейчас LLM-этапы — drain ждёт нуля.
    private var activeStageCount = 0

    public init(
        store: EventStore,
        registry: AdapterRegistry,
        worktrees: WorktreeManager? = nil,
        jira: any JiraGateway = JiraClient(),
        github: GitHubClient = GitHubClient(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.registry = registry
        self.worktrees = worktrees ?? WorktreeManager(root: store.root)
        self.jira = jira
        self.github = github
        self.now = now
    }

    public func subscribe(_ sink: @escaping @Sendable (Data) -> Void) {
        self.sink = sink
        // Reconnect = снапшот состояния запусков (П0): канвас догоняет
        // сразу, не ждёт следующего события.
        for run in Array(runs.values) {
            publishState(run)
        }
    }

    public func run(_ id: UUID) -> OrganizationRun? { runs[id] }

    public func runID(forTask taskID: UUID) -> UUID? {
        // Primary приоритетнее теней/форков той же задачи.
        runs.values.first(where: { $0.task.id == taskID && !$0.isExperimental })?.id
            ?? runs.values.first(where: { $0.task.id == taskID })?.id
    }

    public func allRuns() -> [OrganizationRun] { Array(runs.values) }

    /// Вход демона: одна Wire-команда → обновлённое состояние.
    /// Незнакомый тип — игнор (minor-дрейф протокола, П0).
    public func handle(_ data: Data) async throws {
        let (type, envelope) = try WireEnvelope.unpack(data)
        switch type {
        case .startRun:
            let command = try envelope.payload(as: StartRunCommand.self)
            try await startRun(command)
        case .approve:
            let runID = try envelope.payload(as: UUID.self)
            await transition(runID) { Engine.approve($0, now: self.now()) }
            await continueMergeIfNeeded(runID)
        case .reject:
            let payload = try envelope.payload(as: ChatCommand.self)
            await transition(payload.runID) {
                Engine.reject($0, comment: payload.text, now: self.now())
            }
            await continueRunIfRunning(payload.runID)
        case .cancel:
            let runID = try envelope.payload(as: UUID.self)
            await transition(runID) { Engine.cancel($0, now: self.now()) }
            await settleParentIfNeeded(of: runID)
        case .chat:
            let payload = try envelope.payload(as: ChatCommand.self)
            await chat(payload)
        case .configure:
            let payload = try envelope.payload(as: ConfigureCommand.self)
            jiraConfig = payload.jira
            if let token = payload.githubToken { githubToken = token }
            await flushJiraQueue()
        case .drain:
            draining = true
            publishDrainedIfIdle()
        case .shadowRun:
            let command = try envelope.payload(as: ShadowRunCommand.self)
            try await startShadow(command)
        case .forkRun:
            let command = try envelope.payload(as: ForkRunCommand.self)
            try await startFork(command)
        case .subscribe, .runState, .logBatch, .attention, .handshake, .drained, nil:
            break
        }
    }

    // MARK: Запуск

    private func startRun(_ command: StartRunCommand) async throws {
        guard let picked = command.organization.tasks.first(where: { $0.id == command.taskID }) else {
            return
        }
        let (task, organization) = await resolveRepoIfNeeded(
            picked, organization: command.organization, candidates: command.candidates ?? []
        )
        var run = try Engine.startRun(organization: organization, task: task, now: now())
        organizations[run.orgID] = command.organization
        try store.append(
            RunEvent(seq: 0, date: now(), kind: .runStarted), orgID: run.orgID, runID: run.id
        )
        if FileManager.default.fileExists(atPath: run.repo.path) {
            do {
                run.baseSHA = try worktrees.createWorktree(run: run)
            } catch {
                run = Engine.stageFailed(run, reason: "git: \(error)")
            }
        }
        runs[run.id] = run
        publishState(run)
        try store.append(
            RunEvent(seq: 0, date: now(), kind: .snapshot, run: run),
            orgID: run.orgID, runID: run.id
        )
        await syncJiraStage(run)
        await continueRunIfRunning(run.id)
    }

    // MARK: Experimental: тени (слайс 13) и форки (слайс 12)

    /// Теневой запуск: та же задача по экспериментальному флоу.
    /// Experimental по построению: Jira/push выключены, merge недостижим
    /// (Принять на финальном гейте закрывает итогом для сравнения).
    private func startShadow(_ command: ShadowRunCommand) async throws {
        guard let task = command.organization.tasks.first(where: { $0.id == command.taskID }),
              let flow = command.organization.flows.first(where: { $0.id == command.flowID })
        else { return }
        // Организация с маршрутом типа задачи на экспериментальный флоу —
        // остальная механика старта общая.
        var experimental = command.organization
        if let typeID = task.taskTypeID {
            experimental.routes.removeAll { $0.taskTypeID == typeID }
            experimental.routes.append(OrgRoute(taskTypeID: typeID, flowID: flow.id))
        }
        let (resolved, organization) = await resolveRepoIfNeeded(
            task, organization: experimental, candidates: []
        )
        var run = try Engine.startRun(organization: organization, task: resolved, now: now())
        run.experimental = true
        run.shadowOf = runID(forTask: task.id)
        run.branchName = run.branchName.replacingOccurrences(of: "org/", with: "org/shadow/")
        organizations[run.orgID] = organization
        try store.append(
            RunEvent(seq: 0, date: now(), kind: .runStarted), orgID: run.orgID, runID: run.id
        )
        if FileManager.default.fileExists(atPath: run.repo.path) {
            do {
                run.baseSHA = try worktrees.createWorktree(run: run)
            } catch {
                run = Engine.stageFailed(run, reason: "git: \(error)")
            }
        }
        runs[run.id] = run
        publishState(run)
        try store.append(
            RunEvent(seq: 0, date: now(), kind: .snapshot, run: run),
            orgID: run.orgID, runID: run.id
        )
        await continueRunIfRunning(run.id)
    }

    /// Fork запуска (⌥Enter): продолжить с ТЕКУЩЕГО этапа источника в
    /// свежем worktree от точки форка (baseSHA источника, пин
    /// refs/petable) с override модели у всех сотрудников снапшота.
    private func startFork(_ command: ForkRunCommand) async throws {
        guard let source = runs[command.runID] else { return }
        var fork = source
        fork.id = UUID()
        fork.experimental = true
        fork.forkOf = source.id
        fork.shadowOf = nil
        // Fork на merge-этапе ждёт гейта сразу (вход в merge = гейт, П5).
        fork.status = source.currentStage?.kind == .merge ? .waitingGate : .running
        fork.statusReason = ""
        fork.startedAt = now()
        fork.finishedAt = nil
        fork.outcome = nil
        fork.costEstimate = 0
        fork.stageSessions = [:]
        fork.childRunIDs = nil
        fork.mergeSHA = nil
        fork.commitURL = nil
        fork.diffStat = nil
        fork.pushFailed = nil
        let key = fork.task.jiraKey.isEmpty
            ? fork.task.id.uuidString.prefix(8).lowercased()
            : fork.task.jiraKey
        fork.branchName = "org/fork/\(key)-\(fork.id.uuidString.prefix(6).lowercased())"
        if !command.model.isEmpty {
            fork.employees = fork.employees.map { employee in
                var updated = employee
                updated.adapter.model = command.model
                return updated
            }
        }
        try store.append(
            RunEvent(seq: 0, date: now(), kind: .runStarted), orgID: fork.orgID, runID: fork.id
        )
        if FileManager.default.fileExists(atPath: fork.repo.path) {
            do {
                fork.baseSHA = try worktrees.createWorktree(run: fork, from: source.baseSHA)
            } catch {
                fork = Engine.stageFailed(fork, reason: "git: \(error)")
            }
        }
        runs[fork.id] = fork
        publishState(fork)
        try store.append(
            RunEvent(seq: 0, date: now(), kind: .snapshot, run: fork),
            orgID: fork.orgID, runID: fork.id
        )
        await continueRunIfRunning(fork.id)
    }

    /// Задача без репозитория (правка автора: ничего не привязывать
    /// руками): реестр есть — один берётся сам, из нескольких выбирает
    /// короткий LLM-вызов по тексту задачи; реестр ПУСТ — выбор из
    /// GitHub-кандидатов приложения и автоклон в хранилище демона.
    /// Агента нет или ответ не распознан — первый вариант.
    private func resolveRepoIfNeeded(
        _ task: OrgTask, organization: Organization, candidates: [RemoteRepoCandidate]
    ) async -> (OrgTask, Organization) {
        if let id = task.repoID, organization.repos.contains(where: { $0.id == id }) {
            return (task, organization)
        }
        var resolved = task

        if !organization.repos.isEmpty {
            let names = organization.repos.map { repo in
                "\(repo.name)\(repo.jiraProject.isEmpty ? "" : " (Jira: \(repo.jiraProject))")"
            }
            let pickedName = await pickRepoName(
                options: names, plain: organization.repos.map(\.name),
                task: task, organization: organization
            )
            let chosen = organization.repos.first {
                $0.name.caseInsensitiveCompare(pickedName ?? "") == .orderedSame
            } ?? organization.repos[0]
            resolved.repoID = chosen.id
            return (resolved, organization)
        }

        // Реестр пуст: агент выбирает из GitHub-кандидатов, демон клонирует.
        guard !candidates.isEmpty else { return (task, organization) }
        let pickedName = await pickRepoName(
            options: candidates.map(\.name), plain: candidates.map(\.name),
            task: task, organization: organization
        )
        let candidate = candidates.first {
            $0.name.caseInsensitiveCompare(pickedName ?? "") == .orderedSame
        } ?? candidates[0]
        guard let repo = cloneCandidate(candidate) else { return (task, organization) }
        var updated = organization
        updated.repos.append(repo)
        resolved.repoID = repo.id
        return (resolved, updated)
    }

    /// Клон кандидата в `<store>/repos/<имя>`; уже есть на диске —
    /// используется как есть (идемпотентно). ssh → https.
    private func cloneCandidate(_ candidate: RemoteRepoCandidate) -> RepoRef? {
        let root = store.root.appendingPathComponent("repos", isDirectory: true)
        let target = root.appendingPathComponent(candidate.name, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) {
            return RepoRef(name: candidate.name, path: target.path)
        }
        for url in [candidate.sshURL, candidate.httpsURL] where !url.isEmpty {
            if let path = try? RepoProvisioner.clone(url: url, into: root, name: candidate.name) {
                return RepoRef(name: candidate.name, path: path)
            }
        }
        return nil
    }

    /// Короткий LLM-выбор имени из списка; один вариант/нет адаптера/не
    /// распознан → первый.
    private func pickRepoName(
        options: [String], plain: [String], task: OrgTask, organization: Organization
    ) async -> String? {
        guard plain.count > 1 else { return plain.first }
        let config = organization.employees.first?.adapter ?? AdapterConfig()
        guard let adapter = registry.adapter(for: config) else { return plain.first }
        let prompt = """
        Выбери репозиторий, в котором нужны изменения для задачи. Варианты:
        \(options.map { "- \($0)" }.joined(separator: "\n"))

        Задача \(task.jiraKey.isEmpty ? "" : "[\(task.jiraKey)] ")«\(task.title)».
        \(task.details.isEmpty ? "" : task.details + "\n")\
        Ничего не делай с кодом. Ответь ТОЛЬКО JSON-блоком:
        {"status": "done", "note": "<имя репозитория из списка>"}
        """
        try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        var picked: String?
        for await event in adapter.run(AgentRequest(
            prompt: prompt, workingDirectory: store.root, config: config
        )) {
            if case let .finished(verdict, _) = event {
                picked = plain.first { verdict.note.localizedCaseInsensitiveContains($0) }
            }
        }
        return picked ?? plain.first
    }

    /// Гоняет LLM/тест-этапы, пока запуск в `.running` (гейты и
    /// «требует внимания» останавливают цикл до команд человека).
    /// При drain цикл останавливается ПЕРЕД новым этапом: запуск остаётся
    /// `.running`, свежий демон доведёт его через recovery (П0).
    private func continueRunIfRunning(_ runID: UUID) async {
        while var run = runs[runID], run.status == .running, let stage = run.currentStage {
            if draining { break }
            switch stage.kind {
            case .work, .review, .decompose:
                let runner = StageRunner(store: store, registry: registry, now: now)
                activeStageCount += 1
                let result = await runner.runCurrentStage(
                    run, worktree: worktrees.worktreeURL(runID: run.id),
                    onEvent: { [weak self] in
                        Task { await self?.heartbeat(runID) }
                    }
                )
                activeStageCount -= 1
                run = result.run
                // Артефакт work-этапа — коммит при done (П5).
                if stage.kind == .work, run.status != .needsAttention,
                   FileManager.default.fileExists(atPath: run.repo.path) {
                    if let sha = try? worktrees.commitStageArtifact(
                        run: run, message: "\(stage.name): \(run.task.title)"
                    ) {
                        try? store.append(
                            RunEvent(seq: 0, date: now(), kind: .artifact,
                                     stageID: stage.id, sha: sha),
                            orgID: run.orgID, runID: run.id
                        )
                    }
                }
                // Декомпозиция выдала подзадачи — спавним детей (слайс 8).
                if run.status == .waitingChildren, let verdict = result.verdict {
                    runs[runID] = run
                    publishState(run)
                    await spawnChildren(parent: runID, subtasks: verdict.subtasks)
                    return
                }
            case .test:
                run = await runTestStage(run, stage: stage)
            case .merge, .join:
                // merge исполняется после Принять (approve → merging);
                // join ждёт детей (waitingChildren) — сюда не попадает.
                runs[runID] = run
                publishState(run)
                await syncJiraStage(run)
                return
            }
            runs[runID] = run
            publishState(run)
            await syncJiraStage(run)
        }
        await settleParentIfNeeded(of: runID)
        publishDrainedIfIdle()
    }

    // MARK: Декомпозиция (слайс 8)

    /// Спавн дочерних запусков из подзадач вердикта: тип и репозиторий
    /// резолвятся по именам из организации; незнакомое имя репозитория
    /// при наличии GitHub-токена создаётся и клонируется агентно
    /// (правка №5 — сотрудник задал scope, движок обеспечил); нерезолв
    /// типа — родитель «требует внимания». Дети едут последовательно
    /// (лимит параллелизма v1 = 1).
    private func spawnChildren(parent parentID: UUID, subtasks: [Verdict.Subtask]) async {
        guard var parent = runs[parentID],
              var organization = organizations[parent.orgID]
        else { return }

        var childIDs: [UUID] = []
        for subtask in subtasks {
            let taskType = organization.taskTypes.first {
                $0.name.caseInsensitiveCompare(subtask.taskType) == .orderedSame
            } ?? organization.taskTypes.first
            let repo = await resolveChildRepo(
                named: subtask.repo, organization: &organization, parent: parent
            )
            guard let taskType else {
                parent = Engine.stageFailed(parent, reason: "Подзадаче «\(subtask.title)» не нашёлся тип")
                runs[parentID] = parent
                publishState(parent)
                return
            }
            let childTask = OrgTask(
                title: subtask.title,
                taskTypeID: taskType.id,
                repoID: repo.id,
                jiraKey: parent.task.jiraKey.isEmpty ? "" : "\(parent.task.jiraKey).\(childIDs.count + 1)"
            )
            do {
                var child = try Engine.startRun(
                    organization: organization, task: childTask, now: now()
                )
                child.parentRunID = parentID
                try store.append(
                    RunEvent(seq: 0, date: now(), kind: .runStarted),
                    orgID: child.orgID, runID: child.id
                )
                if FileManager.default.fileExists(atPath: child.repo.path) {
                    child.baseSHA = (try? worktrees.createWorktree(run: child)) ?? ""
                }
                runs[child.id] = child
                childIDs.append(child.id)
                try store.append(
                    RunEvent(seq: 0, date: now(), kind: .snapshot, run: child),
                    orgID: child.orgID, runID: child.id
                )
                publishState(child)
            } catch {
                parent = Engine.stageFailed(
                    parent, reason: "Подзадача «\(subtask.title)» не стартует: \(error)"
                )
                runs[parentID] = parent
                publishState(parent)
                return
            }
        }

        organizations[parent.orgID] = organization // созданные репо видны дальше
        parent.childRunIDs = childIDs
        runs[parentID] = parent
        try? store.append(
            RunEvent(seq: 0, date: now(), kind: .snapshot, run: parent),
            orgID: parent.orgID, runID: parent.id
        )
        publishState(parent)

        for childID in childIDs {
            await continueRunIfRunning(childID)
        }
        await settleChildren(of: parentID)
    }

    /// Репозиторий подзадачи (правка №5): имя из реестра — как есть;
    /// незнакомое имя при GitHub-токене — создаётся приватный репозиторий
    /// и клонируется в хранилище демона (контроллер допишет его в реестр
    /// документа, увидев незнакомый run.repo); иначе — репозиторий
    /// родителя.
    private func resolveChildRepo(
        named name: String, organization: inout Organization, parent: OrganizationRun
    ) async -> RepoRef {
        if let existing = organization.repos.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return existing
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let token = githubToken else { return parent.repo }
        let root = store.root.appendingPathComponent("repos", isDirectory: true)
        let target = root.appendingPathComponent(trimmed, isDirectory: true)
        if FileManager.default.fileExists(atPath: target.path) {
            let repo = RepoRef(name: trimmed, path: target.path)
            organization.repos.append(repo)
            return repo
        }
        do {
            let cloneURL = try await github.createRepo(token: token, name: trimmed)
            let path = try RepoProvisioner.clone(url: cloneURL, into: root, name: trimmed)
            let repo = RepoRef(name: trimmed, path: path)
            organization.repos.append(repo)
            try? store.append(
                RunEvent(seq: 0, date: now(), kind: .log,
                         text: "создан репозиторий «\(trimmed)» под подзадачу"),
                orgID: parent.orgID, runID: parent.id
            )
            return repo
        } catch {
            try? store.append(
                RunEvent(seq: 0, date: now(), kind: .log,
                         text: "репозиторий «\(trimmed)» не создался: \(error) — подзадача едет в \(parent.repo.name)"),
                orgID: parent.orgID, runID: parent.id
            )
            return parent.repo
        }
    }

    /// Ребёнок пришёл к терминалу — проверить, не закрылся ли родитель.
    private func settleParentIfNeeded(of runID: UUID) async {
        guard let run = runs[runID], run.status == .finished,
              let parentID = run.parentRunID
        else { return }
        await settleChildren(of: parentID)
    }

    private func settleChildren(of parentID: UUID) async {
        guard let parent = runs[parentID], parent.status == .waitingChildren else { return }
        let outcomes = (parent.childRunIDs ?? []).map { runs[$0]?.outcome }
        let settled = Engine.childrenSettled(parent, outcomes: outcomes, now: now())
        guard settled != parent else { return }
        runs[parentID] = settled
        try? store.append(
            RunEvent(seq: 0, date: now(), kind: .snapshot, run: settled),
            orgID: settled.orgID, runID: settled.id
        )
        publishState(settled)
    }

    private func runTestStage(_ run: OrganizationRun, stage: OrgStage) async -> OrganizationRun {
        guard !run.repo.testCommand.isEmpty else {
            return Engine.testPassed(run, now: now()) // тестов нет — этап пуст
        }
        let result = Self.shell(
            run.repo.testCommand, cwd: worktrees.worktreeURL(runID: run.id)
        )
        try? store.append(
            RunEvent(
                seq: 0, date: now(),
                kind: result.exitCode == 0 ? .testPassed : .testFailed,
                stageID: stage.id, text: String(result.output.suffix(2000))
            ),
            orgID: run.orgID, runID: run.id
        )
        return result.exitCode == 0
            ? Engine.testPassed(run, now: now())
            : Engine.testFailed(run, output: result.output, now: now())
    }

    /// Принято на финальном гейте: intent-журнал (T2) → rebase → повторные
    /// тесты → merge.
    private func continueMergeIfNeeded(_ runID: UUID) async {
        // Experimental сюда не попадает (approve закрывает до merge) —
        // страховка от будущих путей.
        guard var run = runs[runID], run.status == .merging, !run.isExperimental else { return }
        guard FileManager.default.fileExists(atPath: run.repo.path) else {
            run = Engine.mergeSucceeded(run, now: now()) // мир без git — тесты ядра
            runs[runID] = run
            await enqueueJiraWriteBack(run, sha: "", commitURL: nil, diffStat: "")
            try? store.append(
                RunEvent(seq: 0, date: now(), kind: .snapshot, run: run),
                orgID: run.orgID, runID: run.id
            )
            publishState(run)
            await settleParentIfNeeded(of: runID)
            return
        }
        let intentKey = "merge:\(run.id.uuidString)"
        try? store.append(
            RunEvent(seq: 0, date: now(), kind: .intent, intentKey: intentKey),
            orgID: run.orgID, runID: run.id
        )
        do {
            let defaultBranch = try worktrees.git(
                URL(fileURLWithPath: run.repo.path), "rev-parse", "--abbrev-ref", "HEAD"
            )
            switch try worktrees.rebaseOnDefault(run: run, defaultBranch: defaultBranch) {
            case .rebaseConflict:
                run = Engine.rebaseConflict(run)
            case .merged:
                // Повторные тесты на свежей базе (П5).
                if !run.repo.testCommand.isEmpty {
                    let retest = Self.shell(
                        run.repo.testCommand, cwd: worktrees.worktreeURL(runID: run.id)
                    )
                    if retest.exitCode != 0 {
                        run = Engine.mergeTestsFailed(run, output: retest.output, now: now())
                        break
                    }
                }
                let sha = try worktrees.mergeIntoDefault(run: run, defaultBranch: defaultBranch)
                try? store.append(
                    RunEvent(seq: 0, date: now(), kind: .effectConfirmed,
                             intentKey: intentKey, sha: sha),
                    orgID: run.orgID, runID: run.id
                )
                // Push default + ветки в origin (T7.4); отказ — предупреждение,
                // ссылка в Jira деградирует до хеша.
                let commitURL = worktrees.pushAndCommitURL(
                    run: run, defaultBranch: defaultBranch, sha: sha
                )
                if commitURL == nil {
                    try? store.append(
                        RunEvent(seq: 0, date: now(), kind: .log,
                                 text: "push в origin не прошёл или remote нет — ссылки не будет"),
                        orgID: run.orgID, runID: run.id
                    )
                }
                let diffStat = worktrees.diffStat(run: run, sha: sha)
                // Итог merge — в запуск: терминальная карточка (6A).
                run.mergeSHA = sha
                run.commitURL = commitURL
                run.diffStat = diffStat
                run.pushFailed = commitURL == nil
                run = Engine.mergeSucceeded(run, now: now())
                await enqueueJiraWriteBack(
                    run, sha: sha, commitURL: commitURL, diffStat: diffStat
                )
                try? worktrees.removeWorktree(run: run)
            }
        } catch {
            run = Engine.stageFailed(run, reason: "merge: \(error)")
        }
        runs[runID] = run
        try? store.append(
            RunEvent(seq: 0, date: now(), kind: .snapshot, run: run),
            orgID: run.orgID, runID: run.id
        )
        publishState(run)
        // Возврат после аннулированного Approve продолжает конвейер.
        await continueRunIfRunning(runID)
    }

    // MARK: Jira write-back (П4″, T2)

    /// Финал merged Jira-задачи → комментарий + переход в Done по
    /// intent-протоколу: интент пишется ДО эффекта, маркер runID в теле
    /// комментария даёт сверку факта. Секретов нет — копится в очереди
    /// до коннекта приложения. Дети декомпозиции пропускаются: их
    /// jiraKey (`DN-9.N`) — не настоящая задача Jira.
    private func enqueueJiraWriteBack(
        _ run: OrganizationRun, sha: String, commitURL: String?, diffStat: String
    ) async {
        guard run.outcome == .merged, run.task.source == .jira,
              !run.task.jiraKey.isEmpty, run.parentRunID == nil,
              !run.isExperimental // side effects — только у primary (П5)
        else { return }
        var lines = ["Задача смёржена Petable."]
        if let commitURL {
            lines.append("Коммит: \(commitURL)")
        } else if !sha.isEmpty {
            lines.append("Коммит: \(sha)")
        }
        if !diffStat.isEmpty { lines.append(diffStat) }
        lines.append(Self.jiraMarker(run.id))
        let item = JiraWriteBack(
            orgID: run.orgID, runID: run.id,
            issueKey: run.task.jiraKey, body: lines.joined(separator: "\n")
        )
        try? store.append(
            RunEvent(seq: 0, date: now(), kind: .intent,
                     text: item.body, intentKey: item.intentKey),
            orgID: run.orgID, runID: run.id
        )
        pendingJira.append(item)
        await flushJiraQueue()
    }

    /// Исполняет очередь: сверка факта по маркеру (recovery T2) →
    /// комментарий → переход в Done → подтверждение. Неудача — элемент
    /// остаётся в очереди до следующего configure; дубль комментария
    /// невозможен по построению (hasComment перед повтором).
    private func flushJiraQueue() async {
        guard let config = jiraConfig, config.isComplete, !pendingJira.isEmpty else { return }
        var remaining: [JiraWriteBack] = []
        for item in pendingJira {
            do {
                let marker = Self.jiraMarker(item.runID)
                let alreadyThere = try await jira.hasComment(
                    config, issueKey: item.issueKey, marker: marker
                )
                if !alreadyThere {
                    try await jira.addComment(config, issueKey: item.issueKey, body: item.body)
                }
                try await jira.transitionToDone(config, issueKey: item.issueKey)
                try? store.append(
                    RunEvent(seq: 0, date: now(), kind: .effectConfirmed,
                             intentKey: item.intentKey),
                    orgID: item.orgID, runID: item.runID
                )
            } catch {
                remaining.append(item)
            }
        }
        pendingJira = remaining
    }

    static func jiraMarker(_ runID: UUID) -> String { "[petable:\(runID.uuidString)]" }

    /// Статус в Jira следует за конвейером (правка автора №7): при
    /// переходе задачи на этап — ближайший по смыслу статус, не 1:1.
    /// Конфигурируемый маппинг организации (`jiraStatusMap`) приоритетнее
    /// эвристики; эвристика остаётся fallback'ом. Best-effort: без
    /// секретов или похожего статуса — пропуск, следующий переход
    /// догонит; гарантированный Done при финале идёт intent-очередью.
    private func syncJiraStage(_ run: OrganizationRun) async {
        guard let config = jiraConfig, config.isComplete,
              run.task.source == .jira, !run.task.jiraKey.isEmpty,
              run.parentRunID == nil, !run.isExperimental,
              run.status == .running || run.status == .waitingGate,
              let stage = run.currentStage,
              jiraStageSync[run.id] != stage.id
        else { return }
        jiraStageSync[run.id] = stage.id
        let hints = Self.jiraStatusHints(for: stage.kind)
        let custom = Self.customStatus(
            for: stage.kind, map: organizations[run.orgID]?.jiraStatusMap
        )
        try? await jira.transitionBestMatch(
            config, issueKey: run.task.jiraKey,
            hints: (custom.map { [$0] } ?? []) + hints.names,
            category: hints.category
        )
    }

    /// Кастомный статус вида этапа из маппинга организации (№7);
    /// decompose/join наследуют work, merge — review, если своего нет.
    static func customStatus(for kind: StageKind, map: [String: String]?) -> String? {
        guard let map else { return nil }
        func value(_ kind: StageKind) -> String? {
            let raw = map[kind.rawValue]?.trimmingCharacters(in: .whitespaces)
            return (raw?.isEmpty ?? true) ? nil : raw
        }
        if let own = value(kind) { return own }
        switch kind {
        case .decompose, .join: return value(.work)
        case .merge: return value(.review)
        default: return nil
        }
    }

    /// Подсказки подбора статуса по виду этапа (порядок = приоритет).
    static func jiraStatusHints(for kind: StageKind) -> (names: [String], category: String?) {
        switch kind {
        case .work, .decompose, .join:
            return (["in progress", "в работе", "разработ"], "indeterminate")
        case .review, .merge:
            return (["review", "ревью"], nil)
        case .test:
            return (["test", "qa", "тест"], nil)
        }
    }

    /// Чат с сотрудником (П9): рестарт-с-контекстом текущего этапа в
    /// состояниях {ждёт гейта, требует внимания}; пройденные — read-only.
    private func chat(_ command: ChatCommand) async {
        guard !draining,
              var run = runs[command.runID],
              run.status == .waitingGate || run.status == .needsAttention
        else { return }
        run.status = .running
        run.statusReason = ""
        runs[command.runID] = run
        let runner = StageRunner(store: store, registry: registry, now: now)
        activeStageCount += 1
        let result = await runner.runCurrentStage(
            run,
            worktree: worktrees.worktreeURL(runID: run.id),
            extraContext: "Сообщение человека: \(command.text)",
            onEvent: { [weak self] in
                Task { await self?.heartbeat(command.runID) }
            }
        )
        activeStageCount -= 1
        runs[command.runID] = result.run
        publishState(result.run)
        // Чат на decompose-этапе тоже может выдать подзадачи.
        if result.run.status == .waitingChildren, let verdict = result.verdict {
            await spawnChildren(parent: command.runID, subtasks: verdict.subtasks)
        } else {
            await continueRunIfRunning(command.runID)
        }
    }

    // MARK: Восстановление (П0)

    /// Рестарт демона: поднять ВСЕ организации из хранилища — активные
    /// запуски (в т.ч. прерванные drain'ом при обновлении) продолжаются
    /// до первого коннекта приложения.
    public func recoverAll() async {
        for orgID in store.listOrgIDs() {
            await recover(orgID: orgID)
        }
        for run in runs.values where run.status == .running {
            await continueRunIfRunning(run.id)
        }
    }

    /// Рестарт демона: поднять запуски из журналов, убить осиротевшие
    /// процессы, прерванные этапы — с чистого worktree.
    public func recover(orgID: UUID) async {
        for (runID, loaded) in store.listRuns(orgID: orgID) {
            guard case let .events(events) = loaded,
                  var run = EventStore.restoreRun(from: events)
            else { continue }
            for pid in EventStore.orphanPIDs(in: events) {
                kill(Int32(pid), SIGTERM)
            }
            run = Engine.recovered(run)
            if run.status == .running, FileManager.default.fileExists(atPath: run.repo.path) {
                try? worktrees.resetToCleanState(run: run)
            }
            runs[runID] = run
            // Неподтверждённые Jira-интенты — обратно в очередь (T2):
            // при configure факт сверится по маркеру, дубля не будет.
            for key in EventStore.pendingIntents(in: events)
            where key.hasPrefix("jira:") && !pendingJira.contains(where: { $0.intentKey == key }) {
                guard let intent = events.last(where: {
                    $0.kindValue == .intent && $0.intentKey == key
                }), let body = intent.text else { continue }
                pendingJira.append(JiraWriteBack(
                    orgID: orgID, runID: runID, issueKey: run.task.jiraKey, body: body
                ))
            }
            publishState(run)
        }
    }

    // MARK: События наружу

    private func transition(_ runID: UUID, _ transform: (OrganizationRun) -> OrganizationRun) {
        guard let run = runs[runID] else { return }
        let updated = transform(run)
        runs[runID] = updated
        try? store.append(
            RunEvent(seq: 0, date: now(), kind: .snapshot, run: updated),
            orgID: updated.orgID, runID: updated.id
        )
        publishState(updated)
    }

    private func publishState(_ run: OrganizationRun) {
        // Каждая публикация — событие запуска: штамп для «последнее
        // событие N сек назад» и пульса (6A).
        var stamped = run
        stamped.lastEventAt = now()
        runs[run.id] = stamped
        guard let sink,
              let data = try? WireEnvelope.pack(.runState, RunStateMessage(run: stamped))
        else { return }
        sink(data)
    }

    /// Пульс этапа (6A): события адаптера коалесцируются до ~1 Гц.
    private func heartbeat(_ runID: UUID) {
        guard let run = runs[runID], run.status == .running else { return }
        if let last = run.lastEventAt, now().timeIntervalSince(last) < 1 { return }
        publishState(run)
    }

    /// Drain дошёл до нуля активных этапов — демона можно заменять.
    private func publishDrainedIfIdle() {
        guard draining, activeStageCount == 0, let sink,
              let data = try? WireEnvelope.pack(.drained, 0)
        else { return }
        sink(data)
    }

    static func shell(_ command: String, cwd: URL) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = cwd
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (127, "\(error)") }
        process.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        return (process.terminationStatus, output)
    }
}

/// Отложенный внешний эффект Jira — интент без подтверждения (T2).
struct JiraWriteBack: Sendable {
    var orgID: UUID
    var runID: UUID
    var issueKey: String
    var body: String

    var intentKey: String { "jira:\(runID.uuidString)" }
}

/// Команда чата/возврата: запуск + текст человека.
public struct ChatCommand: Codable, Equatable, Sendable {
    public var runID: UUID
    public var text: String

    public init(runID: UUID, text: String) {
        self.runID = runID
        self.text = text
    }
}
