import SwiftUI
import GraphCore
import OrgEngine

/// Общий словарь и геометрия конвейера/организации (словарь 8A):
/// используется PipelineView (наблюдение) и OrganizationView (настройки).
enum OrgUI {
    /// Этапы в порядке пути от стартового (линейные флоу v1).
    static func orderedStages(_ flow: OrgFlow) -> [OrgStage] {
        var result: [OrgStage] = []
        var current = flow.startStage
        var guardCount = 0
        while let stage = current, guardCount < flow.stages.count {
            result.append(stage)
            current = stage.next.first.flatMap { flow.stage($0) }
            guardCount += 1
        }
        return result.isEmpty ? flow.stages : result
    }

    static func stageIcon(_ kind: StageKind) -> String {
        switch kind {
        case .work: return "hammer"
        case .review: return "eye"
        case .decompose: return "arrow.triangle.branch"
        case .join: return "arrow.triangle.merge"
        case .test: return "checkmark.seal"
        case .merge: return "arrow.triangle.pull"
        }
    }

    static func kindLabel(_ kind: StageKind) -> String {
        switch kind {
        case .work: return "Разработка"
        case .review: return "Ревью"
        case .decompose: return "Декомпозиция"
        case .join: return "Слияние веток"
        case .test: return "Тесты"
        case .merge: return "Merge"
        }
    }

    /// Подпись этапа: сотрудник или роль без LLM.
    static func stageSubtitle(_ stage: OrgStage, employees: [Employee]) -> String {
        if let id = stage.employeeID,
           let employee = employees.first(where: { $0.id == id }) {
            return employee.name
        }
        switch stage.kind {
        case .test: return "тесты репозитория"
        case .merge: return "гейт · человек"
        case .join: return "слияние веток"
        default: return "—"
        }
    }

    static func taskColor(_ status: RunStatus?) -> Color {
        switch status {
        case nil: return Color.secondary.opacity(0.4)
        case .running: return .blue
        case .waitingGate: return .orange
        case .needsAttention: return .red
        case .merging, .waitingChildren: return .blue
        case .finished: return .green
        }
    }

    /// Словарь 8A: человеческие статусы, один язык.
    static func statusText(_ run: OrganizationRun?) -> String {
        guard let run else { return "в очереди" }
        let returns = run.returnCount > 0 ? " · возврат \(run.returnCount) из 3" : ""
        switch run.status {
        case .running:
            return "\(run.currentStage?.name ?? "…")\(returns)"
        case .waitingGate:
            return "ждёт решения: \(run.currentStage?.name ?? "гейт")\(returns)"
        case .needsAttention:
            return "требует внимания: \(run.statusReason)"
        case .merging:
            return "rebase → тесты → merge"
        case .waitingChildren:
            return "ждёт подзадачи (\(run.childRunIDs?.count ?? 0))"
        case .finished:
            return run.outcome == .merged ? "смёржено" : "закрыто"
        }
    }

    /// «1 задача / 2 задачи / 5 задач» — русская плюрализация.
    static func taskCount(_ count: Int) -> String {
        let mod10 = count % 10
        let mod100 = count % 100
        let word: String
        if mod10 == 1, mod100 != 11 {
            word = "задача"
        } else if (2...4).contains(mod10), !(12...14).contains(mod100) {
            word = "задачи"
        } else {
            word = "задач"
        }
        return "\(count) \(word)"
    }

    /// «последнее событие N сек назад» (6A); nil — штампа нет.
    static func lastEventText(_ run: OrganizationRun, now: Date) -> String? {
        guard run.status == .running, let last = run.lastEventAt else { return nil }
        let seconds = max(0, Int(now.timeIntervalSince(last)))
        if seconds < 5 { return "последнее событие только что" }
        if seconds < 120 { return "последнее событие \(seconds) сек назад" }
        return "последнее событие \(seconds / 60) мин назад"
    }

    /// Причина, по которой «Запустить» недоступна; nil — можно (12A).
    /// Правка автора: запустить можно ЛЮБУЮ задачу — тип, маршрут и
    /// невалидный флоу чинит оркестратор на старте (таблица маршрутов →
    /// LLM-выбор → линейная запаска). Единственный честный блок —
    /// задаче совсем некуда ехать.
    static func startBlockReason(_ task: OrgTask, organization: Organization) -> String? {
        if organization.repos.isEmpty, GitHubSettingsStore.token == nil {
            return "подключи GitHub или добавь репозиторий — задаче некуда ехать"
        }
        return nil
    }
}

/// План устранения ошибки (правка автора: «когда появляется ошибка,
/// предлагай понятный план»): по причине «требует внимания» — заголовок,
/// нумерованные шаги и уместные действия-кнопки.
struct RemediationPlan {
    var title: String
    var steps: [String]
    /// Кнопка «Перезапустить движок» (переискать CLI).
    var offersEngineRestart = false
    /// Подсказка, что написать в чат для перезапуска этапа.
    var retryHint: String?
}

extension OrgUI {
    /// Понятный план по известным причинам; nil — универсальной беды нет,
    /// хватает чата и «Отменить».
    static func remediation(for reason: String) -> RemediationPlan? {
        let lower = reason.lowercased()
        if lower.contains("не установлен") {
            let cli = reason.contains("«codex»") ? "codex" : "claude"
            let install = cli == "codex"
                ? "npm install -g @openai/codex  (или brew install codex)"
                : "npm install -g @anthropic-ai/claude-code"
            return RemediationPlan(
                title: "Движок не нашёл CLI «\(cli)»",
                steps: [
                    "Чаще всего движок просто стартовал раньше, чем CLI появился: нажми «Перезапустить движок», затем «Повторить этап».",
                    "Не помогло — проверь путь: Организация → Движок → Исполнители (зелёный путь у «\(cli)»?); нет — впиши путь руками (например ~/.local/bin/\(cli)).",
                    "CLI вообще нет — установи и войди: \(install), затем \(cli) login; после установки — «Перезапустить движок».",
                ],
                offersEngineRestart: true,
                retryHint: "продолжай"
            )
        }
        if lower.contains("конфликт rebase") {
            return RemediationPlan(
                title: "Ветка запуска разошлась с main",
                steps: [
                    "Открой репозиторий и посмотри конфликт: git status в ветке запуска.",
                    "Проще всего вернуть задачу сотруднику: напиши в чат «перенеси изменения поверх свежего main» — этап перезапустится с чистого worktree от актуальной базы.",
                    "После доработки понадобится новый «Принять».",
                ],
                retryHint: "перенеси изменения поверх свежего main"
            )
        }
        if lower.contains("лимит возвратов") {
            return RemediationPlan(
                title: "Задача ходит по кругу (3 возврата)",
                steps: [
                    "Прочитай последнюю причину возврата выше — сотрудник не понимает, чего не хватает.",
                    "Дай в чате ОДНО конкретное указание, что именно исправить.",
                    "Не помогает — «Отменить» и разбей задачу на меньшие.",
                ]
            )
        }
        if lower.contains("вопрос сотрудника") {
            return RemediationPlan(
                title: "Сотрудник ждёт ответа",
                steps: ["Ответь в поле чата — этап продолжится с твоим ответом."]
            )
        }
        if lower.contains("без вердикта") {
            return RemediationPlan(
                title: "Процесс исполнителя упал, не дав ответа",
                steps: [
                    "Причина — в хвосте сообщения выше (stderr процесса) и в логе этапа.",
                    "Чаще всего помогает «Повторить этап» — процесс перезапустится с чистого worktree.",
                    "Повторяется — проверь логин CLI в терминале (claude login / codex login) и модель сотрудника.",
                ],
                retryHint: "продолжай"
            )
        }
        if lower.contains("git:") {
            return RemediationPlan(
                title: "Git-операция не прошла",
                steps: [
                    "Проверь путь репозитория: Организация → Интеграции → Репозитории.",
                    "Убедись, что каталог существует и это git-клон (внутри есть .git).",
                    "Почини путь и напиши в чат «продолжай» — этап перезапустится.",
                ],
                retryHint: "продолжай"
            )
        }
        if lower.contains("декомпозиция без подзадач") || lower.contains("не нашёлся тип") {
            return RemediationPlan(
                title: "Декомпозиция не разобрала задачу",
                steps: [
                    "Уточни постановку: напиши в чат, на какие подзадачи (и в какие репозитории) делить.",
                    "Проверь «Типы задач» — имена типов должны совпадать с теми, что называет архитектор.",
                ]
            )
        }
        return nil
    }
}

/// Карточка плана устранения: шаги + действия. Живёт под причиной
/// «требует внимания» в панели этапа.
struct RemediationView: View {
    let plan: RemediationPlan
    let runID: UUID
    @ObservedObject var controller: OrganizationController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(plan.title, systemImage: "lifepreserver")
                .font(.system(size: 11, weight: .semibold))
            ForEach(Array(plan.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(index + 1).")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(step)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            HStack(spacing: 8) {
                if plan.offersEngineRestart {
                    Button("Перезапустить движок") {
                        Task { await controller.restartEngine() }
                    }
                    .controlSize(.small)
                }
                if let hint = plan.retryHint {
                    Button("Повторить этап") {
                        controller.chat(runID, text: hint)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("Перезапускает этап с чистого worktree")
                }
            }
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.07)))
    }
}

/// Как рисовать узел этапа — акценты обоих экранов.
enum StageEmphasis {
    case idle
    /// Токен здесь (текущий этап запуска).
    case current
    /// Этап пройден токеном.
    case passed
    /// Выбран в редакторе/детали.
    case selected
    /// Янтарная подсветка: вспышка возврата или issues-навигатор.
    case flashed
    /// Впереди по пути — приглушён.
    case dimmed
}

/// Узел этапа — общий вид для наблюдения и редактора (структура —
/// приглушённая, события — громче, решение 3A).
struct StageNodeView: View {
    let stage: OrgStage
    let subtitle: String
    var emphasis: StageEmphasis = .idle

    var body: some View {
        VStack(spacing: 6) {
            Circle()
                .strokeBorder(ringColor, lineWidth: ringWidth)
                .frame(width: 44, height: 44)
                .background {
                    if emphasis == .passed {
                        Circle().fill(Color.green.opacity(0.08))
                    }
                }
                .overlay {
                    Image(systemName: emphasis == .passed ? "checkmark" : OrgUI.stageIcon(stage.kind))
                        .font(.system(size: 15, weight: .light))
                        .foregroundStyle(emphasis == .passed ? Color.green : Color.secondary)
                }
            Text(stage.name)
                .font(.system(size: 11))
                .foregroundStyle(emphasis == .dimmed ? Color.secondary : Color.primary)
            Text(subtitle)
                .font(.system(size: 9))
                .kerning(0.5)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 96)
        .opacity(emphasis == .dimmed ? 0.55 : 1)
        .accessibilityLabel("\(stage.name), \(subtitle)")
    }

    private var ringColor: Color {
        switch emphasis {
        case .flashed: return .orange
        case .selected, .current: return .accentColor
        case .passed: return Color.green.opacity(0.6)
        case .idle, .dimmed:
            return stage.kind == .merge
                ? Color.accentColor.opacity(0.7)
                : Color.secondary.opacity(0.45)
        }
    }

    private var ringWidth: CGFloat {
        emphasis == .selected || emphasis == .current ? 2.5 : 2
    }
}

/// Баннер состояния движка (матрица 4A): режим in-process — кнопка
/// «Установить движок»; версии разошлись — «Обновить движок» (drain П0);
/// строка статуса установки. Общий для конвейера и настроек.
struct EngineBannerView: View {
    @ObservedObject var controller: OrganizationController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let banner = controller.mode.banner {
                HStack(spacing: 8) {
                    Label(banner, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    if case .inProcess = controller.mode, controller.canInstallEngine {
                        Button("Установить движок") {
                            Task { await controller.installOrUpdateEngine() }
                        }
                        .font(.system(size: 11))
                    }
                }
            }
            if controller.engineUpdateAvailable {
                HStack(spacing: 8) {
                    Label("Движок отличается от версии приложения", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Button("Обновить движок") {
                        Task { await controller.installOrUpdateEngine() }
                    }
                    .font(.system(size: 11))
                }
            }
            if let status = controller.engineStatus {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Стрелка ребра между узлами; фиксированная ширина держит строчную
/// геометрию токенов (центр этапа i = i·124+48).
struct EdgeArrowView: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 11, weight: .light))
            .foregroundStyle(Color.secondary.opacity(0.4))
            .frame(width: 28)
    }
}
