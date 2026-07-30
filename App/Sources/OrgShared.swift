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

    /// Причина, по которой «Запустить» недоступна; nil — можно (12A).
    static func startBlockReason(_ task: OrgTask, organization: Organization) -> String? {
        guard let typeID = task.taskTypeID,
              organization.taskTypes.contains(where: { $0.id == typeID })
        else { return "у задачи нет типа" }
        guard let flow = organization.flow(for: typeID) else {
            let typeName = organization.taskTypes.first(where: { $0.id == typeID })?.name ?? "?"
            return "тип «\(typeName)» не смаршрутизирован на флоу"
        }
        let issues = flow.validate()
        if !issues.isEmpty {
            return "флоу «\(flow.name)»: \(issues.count) \(issues.count == 1 ? "ошибка" : "ошибки") — Организация → Конвейер"
        }
        // Репозиторий не выбран — не блок: возьмётся из реестра или
        // GitHub-аккаунта агентом на старте (правка автора). Блок только
        // когда взять неоткуда совсем.
        if organization.repos.isEmpty, GitHubSettingsStore.token == nil {
            return "подключи GitHub или добавь репозиторий — задаче некуда ехать"
        }
        return nil
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
