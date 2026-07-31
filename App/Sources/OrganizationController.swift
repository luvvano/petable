import AppKit
import Foundation
import SwiftUI
import UserNotifications
import AgentRuntime
import GraphCore
import OrgEngine

/// Контроллер конвейера в приложении: транспорт к движку (демон по XPC,
/// иначе in-process fallback с честным баннером), живые состояния
/// запусков для канваса, реконсиляция саммари в документ (П1′).
@MainActor
final class OrganizationController: ObservableObject {
    enum Mode: Equatable {
        case daemon
        case inProcess
        /// Ни демона, ни CLI — конвейер запускать нечем (матрица 4A).
        case unavailable(String)

        var banner: String? {
            switch self {
            case .daemon: return nil
            case .inProcess: return "Движок в приложении — демон не установлен; конвейер остановится при закрытии"
            case let .unavailable(reason): return reason
            }
        }

        var isUnavailable: Bool {
            if case .unavailable = self { return true }
            return false
        }
    }

    @Published private(set) var runs: [UUID: OrganizationRun] = [:]
    @Published private(set) var mode: Mode = .inProcess
    /// Статус последнего импорта/ошибки Jira — баннер борда (матрица 4A).
    @Published var jiraStatus: String?
    /// 401 от Jira: токен протух — баннер с кнопкой переавторизации.
    @Published var jiraNeedsReauth = false
    @Published private(set) var jiraImporting = false
    /// Логин подключённого GitHub-аккаунта; пустой — не подключён.
    @Published var githubLogin = GitHubSettingsStore.login
    /// Статус последней операции интеграций (клон, создание репо…).
    @Published var integrationStatus: String?
    /// Сводка при открытии после отсутствия: «пока вас не было — N задач
    /// ждут» (5A). Гаснет при первом взаимодействии со списком.
    @Published var awaySummary: String?

    /// Движок пора обновить: бинарь демона в бандле новее установленного.
    @Published private(set) var engineUpdateAvailable = false
    /// Статус установки/обновления движка (мини-прогресс, матрица 4A).
    @Published var engineStatus: String?
    /// Ожидание drained-события демона при обновлении (П0).
    private var drainContinuation: CheckedContinuation<Void, Never>?

    /// Цикл оркестратора (правки №8/№9) и дедуп его нотификаций.
    private var orchestratorTask: Task<Void, Never>?
    private var stuckNotified: Set<UUID> = []

    private weak var document: PetableDocument?
    private var transport: (any EngineTransport)?

    /// Запуски, требующие человека, — очередь внимания (N/P, Dock-бейдж).
    /// Experimental не зовут: их итог живёт в дебаггере.
    var attentionRuns: [OrganizationRun] {
        runs.values
            .filter {
                ($0.status == .needsAttention || $0.status == .waitingGate)
                    && !$0.isExperimental
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    func run(forTask taskID: UUID) -> OrganizationRun? {
        // Primary приоритетнее теней/форков (они живут в дебаггере).
        runs.values.first(where: {
            $0.task.id == taskID && $0.status != .finished && !$0.isExperimental
        })
            ?? runs.values.first(where: { $0.task.id == taskID && !$0.isExperimental })
            ?? runs.values.first(where: { $0.task.id == taskID })
    }

    /// Experimental-запуски задачи — тени и форки (полупрозрачные, 13).
    func experimentalRuns(forTask taskID: UUID) -> [OrganizationRun] {
        runs.values
            .filter { $0.task.id == taskID && $0.isExperimental }
            .sorted { $0.startedAt < $1.startedAt }
    }

    // MARK: Подключение

    /// Выбор транспорта: демон по handshake, иначе движок в приложении.
    func connect(document: PetableDocument) async {
        self.document = document
        if transport != nil { return }

        let xpc = XPCTransport()
        if let version = await xpc.handshake(), version == WireEnvelope.protocolVersion {
            transport = xpc
            mode = .daemon
        } else {
            var adapters: [any AgentAdapter] = []
            if let claude = CLIDiscovery.locate("claude") {
                adapters.append(CLIProcessAdapter.claude(executable: claude))
            }
            if let codex = CLIDiscovery.locate("codex") {
                adapters.append(CLIProcessAdapter.codex(
                    executable: codex, schemaPath: Self.writeVerdictSchema()
                ))
            }
            guard !adapters.isEmpty else {
                mode = .unavailable("Не найден ни один CLI (claude, codex) — установите и войдите")
                return
            }
            let store = EventStore(root: EventStore.defaultRoot())
            transport = InProcessTransport(
                core: DaemonCore(store: store, registry: AdapterRegistry(adapters))
            )
            mode = .inProcess
        }

        await transport?.subscribe { [weak self] data in
            Task { @MainActor in self?.receive(data) }
        }
        engineUpdateAvailable = mode == .daemon && DaemonManager.updateAvailable
        // Секреты — демону при коннекте (Безопасность дизайн-дока):
        // он держит их в памяти и разгружает очередь write-back.
        await ensureFreshJira()
        configureJira()
        restartOrchestrator()
        // Сводка 5A: пауза — снапшоты запусков долетают при подписке.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.awaySummary == nil else { return }
            let waiting = self.attentionRuns.count
            if waiting > 0 {
                self.awaySummary = "Пока вас не было: \(OrgUI.taskCount(waiting)) "
                    + (waiting == 1 ? "ждёт" : "ждут") + " вашего решения"
            }
        }
    }

    // MARK: Движок: установка и обновление из приложения (П0)

    /// Есть чем ставить: бинарь демона встроен в сборку приложения.
    var canInstallEngine: Bool { DaemonManager.bundledBinary != nil }

    /// Кнопка «Установить/Обновить движок»: при активных этапах — drain
    /// (новые этапы не начинаются, текущие дорабатывают), затем bootout →
    /// копия бинаря → bootstrap → реконнект. Свежий демон доводит
    /// прерванные запуски через recovery из event-log.
    func installOrUpdateEngine() async {
        guard canInstallEngine else {
            engineStatus = "В сборке приложения нет бинаря демона — пересобери make install"
            return
        }
        if mode == .daemon,
           runs.values.contains(where: { $0.status == .running || $0.status == .merging }) {
            engineStatus = "Жду завершения активных этапов (drain)…"
            send(.drain, 0)
            await withCheckedContinuation { continuation in
                drainContinuation = continuation
                Task { @MainActor in
                    // Страховка от вечного ожидания: этап длиннее 10 минут —
                    // recovery свежего демона перезапустит его с чистого worktree.
                    try? await Task.sleep(for: .seconds(600))
                    self.drainContinuation?.resume()
                    self.drainContinuation = nil
                }
            }
        }
        engineStatus = "Устанавливаю движок…"
        do {
            try await Task.detached { try DaemonManager.install() }.value
            transport = nil
            engineStatus = "Движок установлен и запущен"
            engineUpdateAvailable = false
            if let document { await connect(document: document) }
        } catch {
            engineStatus = "Установка движка: \(error.localizedDescription)"
        }
    }

    // MARK: Jira (слайс 7, П4″)

    /// Передаёт секреты движку (Jira + GitHub-токен для агентного
    /// создания репозиториев, №5) — при коннекте и после сохранения
    /// настроек. Демон держит их только в памяти.
    func configureJira() {
        let config = JiraSettingsStore.config()
        let token = GitHubSettingsStore.token
        guard config != nil || token != nil else { return }
        send(.configure, ConfigureCommand(jira: config, githubToken: token))
    }

    /// OAuth-коннектор (правка автора): браузер → «Согласен» → готово;
    /// сайт подтягивается сам из accessible-resources.
    @Published var jiraConnecting = false

    func connectJiraOAuth() async {
        jiraConnecting = true
        defer { jiraConnecting = false }
        do {
            let tokens = try await JiraOAuthFlow.connect()
            JiraOAuthTokenStore.save(tokens)
            jiraNeedsReauth = false
            configureJira()
            // Сразу пробуем импорт: статус либо покажет задачи, либо
            // подскажет следующий шаг (привязать проект к репозиторию).
            await importFromJira()
        } catch {
            jiraStatus = "Jira: \((error as? JiraOAuthFlow.OAuthError)?.message ?? error.localizedDescription)"
        }
    }

    func disconnectJiraOAuth() {
        JiraOAuthTokenStore.delete()
        jiraStatus = "Jira отключена"
    }

    /// Access-токен коннектора короткоживущий: освежаем с запасом 5 минут
    /// перед configure/импортом; демон между конфигурациями переживает
    /// истечение очередью write-back. Refresh rotating — сохраняем.
    func ensureFreshJira() async {
        guard let tokens = JiraOAuthTokenStore.load(),
              tokens.expiresAt < Date().addingTimeInterval(300)
        else { return }
        do {
            let fresh = try await JiraOAuthFlow.refresh(tokens)
            JiraOAuthTokenStore.save(fresh)
            configureJira()
        } catch {
            jiraNeedsReauth = true
            jiraStatus = "Jira: сессия истекла — подключи заново"
        }
    }

    /// Read-only импорт: JQL по привязанным проектам, маппинг типов и
    /// репозиториев — `JiraImporter`, идемпотентно по jiraKey.
    /// Возвращает добавленные задачи (оркестратору — для взятия в работу).
    @discardableResult
    func importFromJira() async -> [OrgTask] {
        guard let document, let organization = document.organization else { return [] }
        await ensureFreshJira()
        guard let config = JiraSettingsStore.config() else {
            jiraStatus = "Jira не настроена — Организация → Интеграции"
            jiraNeedsReauth = true
            return []
        }
        guard !organization.repos.isEmpty else {
            jiraStatus = "Реестр репозиториев пуст — добавь клон в Организации → Интеграциях, задачам нужно где-то ехать"
            return []
        }
        jiraImporting = true
        defer { jiraImporting = false }
        // Маппинг проект→репо не обязателен: привязок нет — тянем все
        // открытые задачи, репозиторий выберет агент на старте.
        let projects = Set(organization.repos.map(\.jiraProject).filter { !$0.isEmpty })
        let jql = (projects.isEmpty
            ? ""
            : "project in (\(projects.sorted().joined(separator: ","))) AND ")
            + "statusCategory != Done ORDER BY updated DESC"
        do {
            let issues = try await JiraClient().searchIssues(config, jql: jql)
            var existing = Set(organization.tasks.map(\.jiraKey))
            existing.formUnion(organization.runSummaries.map(\.jiraKey))
            existing.formUnion(runs.values.map(\.task.jiraKey))
            existing.remove("")
            let result = JiraImporter.map(
                issues: issues, organization: organization, existingKeys: existing
            )
            if !result.tasks.isEmpty {
                document.updateOrganization { $0.tasks.append(contentsOf: result.tasks) }
            }
            var parts = ["Импортировано: \(result.tasks.count)"]
            if !result.skipped.isEmpty {
                parts.append("пропущено \(result.skipped.count): \(result.skipped.joined(separator: "; "))")
            }
            jiraStatus = parts.joined(separator: " · ")
            jiraNeedsReauth = false
            configureJira() // токен демону — write-back при финале
            return result.tasks
        } catch let error as JiraError {
            jiraNeedsReauth = error.statusCode == 401
            jiraStatus = error.statusCode == 401
                ? "Jira: токен не подошёл — переавторизуйся"
                : "Jira: \(error.statusCode > 0 ? "HTTP \(error.statusCode) · " : "")\(error.message)"
        } catch {
            jiraStatus = "Jira: \(error.localizedDescription)"
        }
        return []
    }

    // MARK: GitHub (П7′, правка №5)

    func connectGitHub(token: String) async {
        do {
            let login = try await GitHubClient().viewerLogin(token: token)
            GitHubSettingsStore.setToken(token)
            GitHubSettingsStore.login = login
            githubLogin = login
            integrationStatus = "GitHub подключён: \(login)"
            configureJira() // токен движку — агентные репо (№5)
        } catch let error as GitHubError {
            integrationStatus = error.statusCode == 401
                ? "GitHub: токен не подошёл"
                : "GitHub: \(error.message)"
        } catch {
            integrationStatus = "GitHub: \(error.localizedDescription)"
        }
    }

    func disconnectGitHub() {
        GitHubSettingsStore.setToken("")
        githubLogin = ""
        integrationStatus = "GitHub отключён"
    }

    /// Клонирует по URL в хранилище (T3) и добавляет в реестр.
    func cloneRepository(url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var name = (trimmed as NSString).lastPathComponent
        if name.hasSuffix(".git") { name = String(name.dropLast(4)) }
        integrationStatus = "Клонирую \(name)…"
        do {
            let root = RepoProvisioner.defaultRoot()
            let path = try await Task.detached {
                try RepoProvisioner.clone(url: trimmed, into: root, name: name)
            }.value
            document?.updateOrganization {
                $0.repos.append(RepoRef(name: name, path: path))
            }
            integrationStatus = "Клонировано: \(name)"
        } catch {
            integrationStatus = "Клон \(name): \(shortError(error))"
        }
    }

    /// Создаёт приватный репозиторий в GitHub, клонирует, кладёт в реестр.
    func createRepository(name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard let token = GitHubSettingsStore.token else {
            integrationStatus = "Сначала подключи GitHub"
            return
        }
        integrationStatus = "Создаю \(trimmed)…"
        do {
            let cloneURL = try await GitHubClient().createRepo(token: token, name: trimmed)
            let root = RepoProvisioner.defaultRoot()
            let path = try await Task.detached {
                try RepoProvisioner.clone(url: cloneURL, into: root, name: trimmed)
            }.value
            document?.updateOrganization {
                $0.repos.append(RepoRef(name: trimmed, path: path))
            }
            integrationStatus = "Создано и клонировано: \(trimmed)"
        } catch {
            integrationStatus = "Создание \(trimmed): \(shortError(error))"
        }
    }

    private func shortError(_ error: Error) -> String {
        switch error {
        case let error as GitHubError: return error.message
        case let error as RepoProvisioner.ProvisionError: return error.message
        case let error as JiraError: return error.message
        default: return error.localizedDescription
        }
    }

    // MARK: Оркестратор (правки №8/№9)

    /// Дефолтный агент-оркестратор: по интервалу проверяет Jira — новые
    /// задачи стягивает (номер, название) и либо спрашивает нотификацией,
    /// либо берёт в работу сам (настройка №9); о зависших напоминает.
    func restartOrchestrator() {
        orchestratorTask?.cancel()
        orchestratorTask = nil
        guard OrchestratorSettings.enabled else { return }
        orchestratorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.orchestratorTick()
                let minutes = OrchestratorSettings.intervalMinutes
                try? await Task.sleep(for: .seconds(Double(minutes) * 60))
            }
        }
    }

    private func orchestratorTick() async {
        guard OrchestratorSettings.enabled,
              document?.organization != nil,
              JiraSettingsStore.config() != nil
        else { return }
        let imported = await importFromJira()
        for task in imported {
            if OrchestratorSettings.autoStart {
                start(task: task)
                notify(
                    id: "orchestrator-start-\(task.jiraKey)",
                    title: "Оркестратор взял в работу: \(task.jiraKey)",
                    body: task.title
                )
            } else {
                notify(
                    id: "orchestrator-new-\(task.jiraKey)",
                    title: "Новая задача \(task.jiraKey) — берём в работу?",
                    body: "\(task.title) · «Запустить» на конвейере"
                )
            }
        }
        // Зависшие: ждут человека — одно напоминание на состояние.
        // При включённом resolveStuck «требует внимания» сначала разбирает
        // оркестратор-LLM (правка №8); гейты — человеку всегда (П5).
        for run in attentionRuns where !stuckNotified.contains(run.id) {
            stuckNotified.insert(run.id)
            if OrchestratorSettings.resolveStuck, run.status == .needsAttention {
                await resolveStuckRun(run)
                continue
            }
            notify(
                id: "orchestrator-stuck-\(run.id)",
                title: "Задача ждёт вас: \(run.task.title)",
                body: run.status == .needsAttention
                    ? run.statusReason
                    : "ждёт решения на гейте «\(run.currentStage?.name ?? "")»"
            )
        }
    }

    /// Оркестратор-LLM (правка №8): смотрит на причину затыка и решает —
    /// retry (перезапустить этап с советом через чат П9), cancel
    /// (отменить) или wait (оставить человеку). Не распознали ответ —
    /// честная нотификация человеку.
    private func resolveStuckRun(_ run: OrganizationRun) async {
        var decision: String?
        if let claude = CLIDiscovery.locate("claude") {
            let adapter = CLIProcessAdapter.claude(executable: claude)
            let prompt = """
            Ты — оркестратор конвейера ИИ-сотрудников. Задача застряла, реши, что делать.

            Задача\(run.task.jiraKey.isEmpty ? "" : " [\(run.task.jiraKey)]"): «\(run.task.title)»
            Этап: «\(run.currentStage?.name ?? "?")»
            Причина остановки: \(run.statusReason)
            Возвратов уже: \(run.returnCount) из 3.

            Действия: retry — перезапустить этап, дав сотруднику конкретный совет,
            как обойти проблему; cancel — отменить задачу (проблема не решается
            автоматикой); wait — оставить человеку (нужно его решение).
            Ничего не делай с кодом. Ответь ТОЛЬКО JSON-блоком:
            {"status":"done","note":"<retry|cancel|wait>: <совет сотруднику или пояснение>"}
            """
            let root = EventStore.defaultRoot()
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for await event in adapter.run(AgentRequest(
                prompt: prompt, workingDirectory: root, config: AdapterConfig()
            )) {
                if case let .finished(verdict, _) = event { decision = verdict.note }
            }
        }
        let note = (decision ?? "").trimmingCharacters(in: .whitespaces)
        let lower = note.lowercased()
        let detail = note.drop(while: { $0 != ":" }).dropFirst()
            .trimmingCharacters(in: .whitespaces)
        if lower.hasPrefix("retry"), !detail.isEmpty {
            chat(run.id, text: detail)
            notify(
                id: "orchestrator-retry-\(run.id)",
                title: "Оркестратор перезапустил этап: \(run.task.title)",
                body: detail
            )
        } else if lower.hasPrefix("cancel") {
            cancel(run.id)
            notify(
                id: "orchestrator-cancel-\(run.id)",
                title: "Оркестратор отменил: \(run.task.title)",
                body: detail.isEmpty ? run.statusReason : detail
            )
        } else {
            notify(
                id: "orchestrator-stuck-\(run.id)",
                title: "Задача ждёт вас: \(run.task.title)",
                body: run.statusReason
            )
        }
    }

    private func notify(id: String, title: String, body: String) {
        requestNotificationAuthorizationOnce()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil)
        )
    }

    private func receive(_ data: Data) {
        guard let (type, envelope) = try? WireEnvelope.unpack(data) else { return }
        switch type {
        case .runState:
            guard let message = try? envelope.payload(as: RunStateMessage.self) else { return }
            let run = message.run
            let previous = runs[run.id]?.status
            runs[run.id] = run
            if run.status != .needsAttention, run.status != .waitingGate {
                stuckNotified.remove(run.id) // оркестратор напомнит про следующий затык
            }
            // Демон сам склонировал репозиторий (пустой реестр) —
            // подхватываем его в реестр документа.
            if document?.organization?.repos.contains(where: { $0.id == run.repo.id }) == false {
                document?.updateOrganization { org in
                    if !org.repos.contains(where: { $0.id == run.repo.id || $0.path == run.repo.path }) {
                        org.repos.append(run.repo)
                    }
                }
            }
            notifyIfNeeded(run, previous: previous)
            updateDockBadge()
            if run.status == .finished, let summary = run.summary {
                // Терминал: саммари в документ; задача уходит с борда
                // только по итогу primary — тень/форк её не снимают.
                document?.reconcileRunSummaries([summary])
                if !run.isExperimental {
                    document?.updateOrganization { org in
                        org.tasks.removeAll { $0.id == run.task.id }
                    }
                }
            }
        case .drained:
            // Демон дорасходовал активные этапы — можно заменять (П0).
            drainContinuation?.resume()
            drainContinuation = nil
        default:
            break
        }
    }

    // MARK: Зов конвейера (5A)

    /// Конвейер зовёт человека: нотификация на переход в состояние,
    /// требующее его, и на финал. Ограничение честное: при закрытом
    /// приложении баннеров нет (демон headless) — бейдж и сводка при
    /// следующем открытии.
    private func notifyIfNeeded(_ run: OrganizationRun, previous: RunStatus?) {
        guard run.status != previous, !run.isExperimental else { return }
        let title: String
        let body: String
        switch run.status {
        case .waitingGate:
            title = "Ждёт решения: \(run.task.title)"
            body = "Этап «\(run.currentStage?.name ?? "гейт")» — Принять или Вернуть"
        case .needsAttention:
            title = "Требует внимания: \(run.task.title)"
            body = run.statusReason
        case .finished where run.outcome == .merged:
            title = "Смёржено: \(run.task.title)"
            body = run.returnCount > 0 ? "Возвратов: \(run.returnCount)" : "Без возвратов"
        default:
            return
        }
        requestNotificationAuthorizationOnce()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "petable-run-\(run.id)-\(run.status.rawValue)",
            content: content,
            trigger: nil
        ))
    }

    /// Dock-бейдж = число запусков, ждущих человека (5A).
    private func updateDockBadge() {
        let count = attentionRuns.filter { $0.status != .finished }.count
        NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    private var authorizationRequested = false
    private func requestNotificationAuthorizationOnce() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    // MARK: Команды

    func start(task: OrgTask) {
        guard let organization = document?.organization else { return }
        Task { await startProvisioned(task: task, organization: organization) }
    }

    /// Реестр пуст — кандидаты из GitHub-аккаунта: агент в движке выберет
    /// подходящий по задаче и склонирует сам (правка автора: ничего не
    /// привязывать руками).
    private func startProvisioned(task: OrgTask, organization: Organization) async {
        var candidates: [RemoteRepoCandidate] = []
        if organization.repos.isEmpty {
            guard let token = GitHubSettingsStore.token else {
                jiraStatus = "Задаче некуда ехать: подключи GitHub (репозиторий выберется и склонируется сам) или добавь клон в Интеграциях"
                return
            }
            do {
                candidates = try await GitHubClient().listRepos(token: token).map {
                    RemoteRepoCandidate(name: $0.name, sshURL: $0.sshURL, httpsURL: $0.httpsURL)
                }
            } catch {
                jiraStatus = "GitHub: не смог получить список репозиториев — \(shortError(error))"
                return
            }
            guard !candidates.isEmpty else {
                jiraStatus = "В GitHub-аккаунте нет репозиториев — создай в Интеграциях"
                return
            }
        }
        send(.startRun, StartRunCommand(
            organization: organization,
            taskID: task.id,
            candidates: candidates.isEmpty ? nil : candidates
        ))
    }

    /// Теневой запуск (13): та же задача по экспериментальному флоу.
    func shadowRun(task: OrgTask, flowID: UUID) {
        guard let organization = document?.organization else { return }
        send(.shadowRun, ShadowRunCommand(
            organization: organization, taskID: task.id, flowID: flowID
        ))
    }

    /// Fork запуска с override модели (12, ⌥Enter).
    func forkRun(_ runID: UUID, model: String) {
        send(.forkRun, ForkRunCommand(runID: runID, model: model))
    }

    func approve(_ runID: UUID) { send(.approve, runID) }

    func reject(_ runID: UUID, comment: String) {
        send(.reject, ChatCommand(runID: runID, text: comment))
    }

    func chat(_ runID: UUID, text: String) {
        send(.chat, ChatCommand(runID: runID, text: text))
    }

    func cancel(_ runID: UUID) { send(.cancel, runID) }

    private func send<T: Codable>(_ type: WireType, _ payload: T) {
        guard let transport else { return }
        Task {
            do {
                try await transport.send(try WireEnvelope.pack(type, payload))
            } catch {
                // Ошибка транспорта — «требует внимания» на уровне режима.
                await MainActor.run {
                    self.mode = .unavailable("Движок недоступен: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Схема вердикта для codex (T5) — рядом с хранилищем.
    private static func writeVerdictSchema() -> String? {
        let root = EventStore.defaultRoot()
        let url = root.appendingPathComponent("verdict-schema.json")
        let schema = """
        {"type":"object","properties":{"status":{"type":"string","enum":["done","changesRequested","cannotComplete"]},"note":{"type":"string"}},"required":["status","note"],"additionalProperties":false}
        """
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? schema.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}
