import SwiftUI
import GraphCore
import OrgEngine

/// Конвейер (правки автора №1–№3): открывается СПИСКОМ задач по статусам;
/// клик по задаче — флоу-диаграмма её пути (пройденные этапы, текущий);
/// клик по этапу — панель этапа с чатом агенту (изменить поведение —
/// в границах П9: чат активен в {ждёт гейта, требует внимания}).
struct PipelineView: View {
    @ObservedObject var document: PetableDocument
    @ObservedObject var controller: OrganizationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager

    /// Открытая задача; nil — список.
    @State private var selectedTaskID: UUID?
    /// Выбранный этап в детали задачи.
    @State private var selectedStageID: UUID?
    @State private var newTaskTitle = ""
    @State private var chatDrafts: [UUID: String] = [:]
    /// Двухшаговый ⌘Enter на финальном гейте (11A).
    @State private var armedApproveRunID: UUID?
    /// Память позиций токенов — распознаёт возврат (9A).
    @State private var stageMemo: [UUID: Int] = [:]
    @State private var flashedStages: Set<UUID> = []
    /// Тихий пульс токена: реакция на событие этапа, не вечная анимация (6A).
    @State private var lastEventMemo: [UUID: Date] = [:]
    @State private var pulsingRuns: Set<UUID> = []
    /// Фильтры списка (правка автора): поиск по имени/ключу, статус
    /// конвейера, статус Jira.
    @State private var searchText = ""
    @State private var statusFilter: StatusFilter = .all
    @State private var jiraStatusFilter = "Все"

    enum StatusFilter: String, CaseIterable {
        case all = "Все"
        case attention = "Требует внимания"
        case waiting = "Ждёт решения"
        case working = "В работе"
        case queued = "В очереди"
        case finished = "Завершённые"
    }

    var body: some View {
        Group {
            if let organization = document.organization {
                content(organization)
            } else {
                emptyOrganization
            }
        }
        .task { await controller.connect(document: document) }
        .onChange(of: controller.runs) { _, newRuns in trackReturns(newRuns) }
        // Undo-менеджер окна: без него правки организации не помечают
        // документ изменённым — и автосейв их не пишет.
        .onAppear { document.attach(undoManager) }
        .onChange(of: undoManager) { _, newValue in document.attach(newValue) }
    }

    private var emptyOrganization: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.gobackward")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Организации ещё нет")
                .font(.title3.weight(.semibold))
            Text("ИИ-сотрудники берут задачи и ведут их по флоу:\nразработка → ревью → тесты → merge.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Создать организацию") {
                document.createOrganizationIfNeeded()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ organization: Organization) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                EngineBannerView(controller: controller)
                if let away = controller.awaySummary {
                    HStack(spacing: 8) {
                        Label(away, systemImage: "moon.zzz")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button("Понятно") { controller.awaySummary = nil }
                            .font(.system(size: 11))
                    }
                }
                if let selected = selectedItem(organization) {
                    taskDetail(selected.task, run: selected.run, organization: organization)
                } else {
                    taskList(organization)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress { press in handleKey(press) }
    }

    /// Открытая задача: с борда или (после финала) из runtime-запуска.
    private func selectedItem(_ organization: Organization) -> (task: OrgTask, run: OrganizationRun?)? {
        guard let id = selectedTaskID else { return nil }
        if let task = organization.tasks.first(where: { $0.id == id }) {
            return (task, controller.run(forTask: id))
        }
        if let run = controller.run(forTask: id) {
            return (run.task, run)
        }
        return nil
    }

    // MARK: Список задач по статусам (правка №1)

    private func taskList(_ organization: Organization) -> some View {
        let items = organization.tasks
            .map { task in (task: task, run: controller.run(forTask: task.id)) }
            .filter { matchesFilters($0.task, run: $0.run) }
        return VStack(alignment: .leading, spacing: 20) {
            if let status = controller.jiraStatus {
                HStack(spacing: 8) {
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(controller.jiraNeedsReauth ? Color.orange : Color.secondary)
                }
            }
            filterBar(organization)
            section("ТРЕБУЕТ ВНИМАНИЯ", items.filter { $0.run?.status == .needsAttention },
                    organization: organization)
            section("ЖДЁТ РЕШЕНИЯ", items.filter { $0.run?.status == .waitingGate },
                    organization: organization)
            section("В РАБОТЕ", items.filter {
                switch $0.run?.status {
                case .running, .merging, .waitingChildren: return true
                default: return false
                }
            }, organization: organization)
            if statusFilter == .all || statusFilter == .queued {
                queueSection(items.filter { $0.run == nil || $0.run?.status == .finished },
                             organization: organization)
            }
            if !organization.runSummaries.isEmpty,
               statusFilter == .all || statusFilter == .finished {
                historySection(organization)
            }
        }
    }

    // MARK: Фильтры и поиск (правка автора)

    private func filterBar(_ organization: Organization) -> some View {
        let jiraStatuses = Set(organization.tasks.compactMap(\.jiraStatus))
            .filter { !$0.isEmpty }
            .sorted()
        return HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Поиск по имени или ключу…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(maxWidth: 240)
            Picker("Статус", selection: $statusFilter) {
                ForEach(StatusFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .fixedSize()
            .font(.system(size: 11))
            if !jiraStatuses.isEmpty {
                Picker("Jira", selection: $jiraStatusFilter) {
                    Text("Все").tag("Все")
                    ForEach(jiraStatuses, id: \.self) { status in
                        Text(status).tag(status)
                    }
                }
                .fixedSize()
                .font(.system(size: 11))
            }
            if !searchText.isEmpty || statusFilter != .all || jiraStatusFilter != "Все" {
                Button("Сбросить") {
                    searchText = ""
                    statusFilter = .all
                    jiraStatusFilter = "Все"
                }
                .font(.system(size: 11))
            }
            Spacer()
        }
    }

    private func matchesFilters(_ task: OrgTask, run: OrganizationRun?) -> Bool {
        if !searchText.isEmpty,
           !task.title.localizedCaseInsensitiveContains(searchText),
           !task.jiraKey.localizedCaseInsensitiveContains(searchText) {
            return false
        }
        if jiraStatusFilter != "Все", (task.jiraStatus ?? "") != jiraStatusFilter {
            return false
        }
        switch statusFilter {
        case .all: return true
        case .attention: return run?.status == .needsAttention
        case .waiting: return run?.status == .waitingGate
        case .working:
            switch run?.status {
            case .running, .merging, .waitingChildren: return true
            default: return false
            }
        case .queued: return run == nil || run?.status == .finished
        case .finished: return false // борд не хранит завершённые — они в истории
        }
    }

    @ViewBuilder
    private func section(
        _ title: String,
        _ items: [(task: OrgTask, run: OrganizationRun?)],
        organization: Organization
    ) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader(title)
                ForEach(items, id: \.task.id) { item in
                    taskRow(item.task, run: item.run, organization: organization)
                }
            }
        }
    }

    private func queueSection(
        _ items: [(task: OrgTask, run: OrganizationRun?)],
        organization: Organization
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                sectionHeader("В ОЧЕРЕДИ")
                Spacer()
                if controller.jiraImporting {
                    ProgressView().controlSize(.small)
                }
                Button("Импорт из Jira") {
                    Task { await controller.importFromJira() }
                }
                .font(.system(size: 11))
                .disabled(controller.jiraImporting)
            }
            if items.isEmpty {
                Text("Задач нет — импортируй из Jira или создай (⏎).")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }
            ForEach(items, id: \.task.id) { item in
                taskRow(item.task, run: item.run, organization: organization)
            }
            HStack {
                TextField("Новая задача… (⏎)", text: $newTaskTitle)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .onSubmit(addTask)
                Button("Добавить", action: addTask)
                    .disabled(newTaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .kerning(1.2)
            .foregroundStyle(.tertiary)
    }

    /// Строка списка: клик открывает флоу задачи (правка №2).
    private func taskRow(
        _ task: OrgTask, run: OrganizationRun?, organization: Organization
    ) -> some View {
        let blockReason = run == nil ? OrgUI.startBlockReason(task, organization: organization) : nil
        return HStack(spacing: 8) {
            Circle()
                .fill(OrgUI.taskColor(run?.status))
                .frame(width: 8, height: 8)
            Text(task.jiraKey.isEmpty ? task.title : "\(task.jiraKey) · \(task.title)")
                .font(.system(size: 12, weight: run?.status == .needsAttention ? .semibold : .regular))
            jiraBadge(task)
            Spacer()
            Text(blockReason ?? OrgUI.statusText(run))
                .font(.system(size: 10))
                .foregroundStyle(
                    run?.status == .needsAttention
                        ? Color.red
                        : blockReason != nil ? Color.orange : Color.secondary
                )
            if run == nil {
                Button("Запустить") { controller.start(task: task) }
                    .font(.system(size: 11))
                    .disabled(controller.mode.isUnavailable || blockReason != nil)
                    .help(blockReason ?? "")
            } else if let run, run.status != .finished {
                Button("Отменить") { controller.cancel(run.id) }
                    .font(.system(size: 11))
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { open(taskID: task.id, run: run) }
        .accessibilityAddTraits(.isButton)
    }

    private func open(taskID: UUID, run: OrganizationRun?) {
        selectedTaskID = taskID
        selectedStageID = run?.currentStageID
        controller.awaySummary = nil // человек вернулся к списку (5A)
    }

    private func addTask() {
        let title = newTaskTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        document.updateOrganization { org in
            org.tasks.append(OrgTask(
                title: title,
                taskTypeID: org.taskTypes.first?.id,
                repoID: org.repos.first?.id
            ))
        }
        newTaskTitle = ""
    }

    // MARK: История

    private func historySection(_ organization: Organization) -> some View {
        let summaries = organization.runSummaries.reversed().filter { summary in
            searchText.isEmpty
                || summary.taskTitle.localizedCaseInsensitiveContains(searchText)
                || summary.jiraKey.localizedCaseInsensitiveContains(searchText)
        }
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader("ЗАВЕРШЁННЫЕ")
            ForEach(summaries) { summary in
                HStack(spacing: 8) {
                    Image(systemName: outcomeIcon(summary.outcome))
                        .foregroundStyle(outcomeColor(summary.outcome))
                        .font(.system(size: 11))
                    Text(summary.jiraKey.isEmpty ? summary.taskTitle : "\(summary.jiraKey) · \(summary.taskTitle)")
                        .font(.system(size: 12))
                    Spacer()
                    if summary.returnCount > 0 {
                        Text("возвратов: \(summary.returnCount)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    if summary.costEstimate > 0 {
                        Text("≈$\(summary.costEstimate, specifier: "%.2f")")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    if let commitURL = summary.commitURL, let url = URL(string: commitURL) {
                        Link("коммит", destination: url)
                            .font(.system(size: 10))
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func outcomeIcon(_ outcome: RunOutcome) -> String {
        switch outcome {
        case .merged: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        case .closed: return "minus.circle"
        case .broken: return "exclamationmark.triangle.fill"
        }
    }

    private func outcomeColor(_ outcome: RunOutcome) -> Color {
        switch outcome {
        case .merged: return .green
        case .cancelled, .closed: return .secondary
        case .broken: return .red
        }
    }

    // MARK: Деталь задачи: флоу-диаграмма пути (правка №2)

    @ViewBuilder
    private func taskDetail(
        _ task: OrgTask, run: OrganizationRun?, organization: Organization
    ) -> some View {
        let flow = run?.flow ?? task.taskTypeID.flatMap { organization.flow(for: $0) }
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Button {
                    closeDetail()
                } label: {
                    Label("Задачи", systemImage: "chevron.left")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Esc — назад к списку")
                Text(task.jiraKey.isEmpty ? task.title : "\(task.jiraKey) · \(task.title)")
                    .font(.system(size: 13, weight: .semibold))
                jiraBadge(task)
                Spacer()
                if let run, run.status != .finished {
                    Menu("Тень") {
                        ForEach(organization.flows) { flow in
                            Button(flow.name) {
                                controller.shadowRun(task: task, flowID: flow.id)
                            }
                        }
                    }
                    .font(.system(size: 11))
                    .fixedSize()
                    .help("Теневой запуск той же задачи по экспериментальному флоу: Jira/push/merge выключены, результат — в дебаггере (13)")
                    Button("Отменить") { controller.cancel(run.id) }
                        .font(.system(size: 11))
                } else if run == nil {
                    let reason = OrgUI.startBlockReason(task, organization: organization)
                    Button("Запустить") { controller.start(task: task) }
                        .font(.system(size: 11))
                        .disabled(controller.mode.isUnavailable || reason != nil)
                        .help(reason ?? "")
                }
            }
            // Тени и форки задачи — полупрозрачные, с пунктирной меткой (13).
            ForEach(controller.experimentalRuns(forTask: task.id)) { shadow in
                HStack(spacing: 8) {
                    Text("эксп.")
                        .font(.system(size: 9))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(
                            Capsule().strokeBorder(
                                Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                            )
                        )
                    Text("\(shadow.flow.name) · \(OrgUI.statusText(shadow))")
                        .font(.system(size: 11))
                    Spacer()
                    if shadow.status == .waitingGate {
                        Button("Завершить") { controller.approve(shadow.id) }
                            .font(.system(size: 10))
                            .help("Experimental терминален до merge: закрывается итогом для сравнения")
                    }
                    if shadow.status != .finished {
                        Button("Отменить") { controller.cancel(shadow.id) }
                            .font(.system(size: 10))
                    }
                }
                .foregroundStyle(.secondary)
                .opacity(0.8)
            }
            HStack(spacing: 12) {
                Circle()
                    .fill(OrgUI.taskColor(run?.status))
                    .frame(width: 8, height: 8)
                Text(OrgUI.statusText(run))
                    .font(.system(size: 12))
                    .foregroundStyle(run?.status == .needsAttention ? Color.red : Color.primary)
                if let run, run.status == .running {
                    // «Последнее событие N сек назад»; застой дольше двух
                    // минут — янтарный оттенок (6A).
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        if let text = OrgUI.lastEventText(run, now: context.date) {
                            Text(text)
                                .font(.system(size: 10))
                                .foregroundStyle(staleColor(run, now: context.date))
                        }
                    }
                }
                Spacer()
                if let run, run.costEstimate > 0 {
                    Text("≈$\(run.costEstimate, specifier: "%.2f")")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            // Бейдж расхождения версий (2A): запуск едет по снапшоту.
            if let run, run.status != .finished, let pinned = run.flowVersion,
               let current = organization.flows.first(where: { $0.id == run.flow.id }),
               current.version != pinned {
                Text("Запуск идёт по v\(pinned) · текущий флоу v\(current.version)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.1)))
            }
            if let run, run.status == .finished {
                terminalCard(run)
            }
            if let flow {
                flowDiagram(flow, run: run)
                if let stageID = selectedStageID ?? run?.currentStageID,
                   let stage = flow.stage(stageID) {
                    if let run {
                        // Окно этапа: лог агента + переписка + ссылки
                        // (правка автора, референс Codex/Claude Code).
                        StageActivityView(run: run, stage: stage, controller: controller)
                    } else {
                        stagePanel(stage, flow: flow, run: nil)
                    }
                }
            } else {
                Text("Тип задачи не смаршрутизирован на флоу — Организация → Типы задач.")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
            }
            if armedApproveRunID != nil, armedApproveRunID == run?.id {
                Text("Финальный гейт: ⌘Enter ещё раз — Принять и merge")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Диаграмма пути: пройденные этапы — галки, текущий — токен,
    /// впереди — приглушены. Клик по этапу — панель с чатом (правка №3).
    private func flowDiagram(_ flow: OrgFlow, run: OrganizationRun?) -> some View {
        let stages = OrgUI.orderedStages(flow)
        let currentIndex = run.map { r in
            stages.firstIndex(where: { $0.id == r.currentStageID }) ?? 0
        }
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    StageNodeView(
                        stage: stage,
                        subtitle: OrgUI.stageSubtitle(stage, employees: run?.employees ?? []),
                        emphasis: emphasis(for: stage, index: index, currentIndex: currentIndex)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedStageID = selectedStageID == stage.id ? nil : stage.id
                    }
                    // Drag-and-drop токена: бросил на этап — задача едет
                    // туда (движок пускает из {ждёт гейта, требует
                    // внимания}; счётчик возвратов не трогается).
                    .dropDestination(for: String.self) { items, _ in
                        guard let run, items.contains(run.id.uuidString) else { return false }
                        controller.moveRun(run.id, to: stage.id)
                        return true
                    }
                    if stage.id != stages.last?.id {
                        EdgeArrowView()
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, run == nil ? 0 : 26)
            if let run, run.status != .finished, let currentIndex {
                runToken(run, index: currentIndex)
            }
        }
    }

    private func emphasis(for stage: OrgStage, index: Int, currentIndex: Int?) -> StageEmphasis {
        if flashedStages.contains(stage.id) { return .flashed }
        if selectedStageID == stage.id { return .selected }
        guard let currentIndex else { return .idle }
        if index < currentIndex { return .passed }
        if index == currentIndex { return .current }
        return .dimmed
    }

    /// Переход токена — единственная крупная анимация: ease-out 220 мс,
    /// Reduce Motion — мгновенно (9A). Тихий пульс — короткий отклик
    /// на событие этапа (6A), не вечная пульсация.
    private func runToken(_ run: OrganizationRun, index: Int) -> some View {
        Text(run.task.jiraKey.isEmpty ? String(run.task.title.prefix(12)) : run.task.jiraKey)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(OrgUI.taskColor(run.status).opacity(0.16)))
            .overlay(Capsule().strokeBorder(OrgUI.taskColor(run.status), lineWidth: 1))
            .scaleEffect(pulsingRuns.contains(run.id) ? 1.12 : 1)
            .draggable(run.id.uuidString) // dnd: бросить на этап (движение руками)
            .help(run.status == .waitingGate || run.status == .needsAttention
                ? "Перетащи на этап, чтобы двинуть задачу руками"
                : "")
            .position(x: CGFloat(index) * 124 + 48, y: 10)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: index)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.18),
                value: pulsingRuns.contains(run.id)
            )
            .accessibilityLabel("\(run.task.title): \(OrgUI.statusText(run))")
    }

    /// Терминальная карточка запуска (6A): итог, время, стоимость,
    /// возвраты, дифф-стат, ссылки; здесь же виден отказ push.
    private func terminalCard(_ run: OrganizationRun) -> some View {
        let outcome = run.outcome ?? .closed
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: outcomeIcon(outcome))
                    .foregroundStyle(outcomeColor(outcome))
                Text(outcomeTitle(outcome))
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let finished = run.finishedAt {
                    Text(durationText(from: run.startedAt, to: finished))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 12) {
                Text(run.returnCount > 0 ? "возврат \(run.returnCount) из 3" : "без возвратов")
                if run.costEstimate > 0 {
                    Text("≈$\(run.costEstimate, specifier: "%.2f")")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            if let diffStat = run.diffStat,
               !diffStat.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(diffStat.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if let prURL = run.prURL, let url = URL(string: prURL) {
                    Link("Pull request", destination: url)
                        .font(.system(size: 11))
                }
                if let commitURL = run.commitURL, let url = URL(string: commitURL) {
                    Link("Коммит в origin", destination: url)
                        .font(.system(size: 11))
                } else if run.pushFailed == true, let sha = run.mergeSHA {
                    Label(
                        "push не прошёл — коммит \(String(sha.prefix(10))) локально",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                }
                if !run.task.jiraKey.isEmpty, let url = jiraBrowseURL(run.task.jiraKey) {
                    Link(run.task.jiraKey, destination: url)
                        .font(.system(size: 11))
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(outcomeColor(outcome).opacity(0.07)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func outcomeTitle(_ outcome: RunOutcome) -> String {
        switch outcome {
        case .merged: return "Смёржено"
        case .cancelled: return "Отменено"
        case .closed: return "Закрыто"
        case .broken: return "Запуск повреждён"
        }
    }

    private func durationText(from: Date, to: Date) -> String {
        let seconds = max(0, Int(to.timeIntervalSince(from)))
        if seconds < 60 { return "\(seconds) сек" }
        if seconds < 3600 { return "\(seconds / 60) мин" }
        return "\(seconds / 3600) ч \((seconds % 3600) / 60) мин"
    }

    private func staleColor(_ run: OrganizationRun, now: Date) -> Color {
        guard let last = run.lastEventAt else { return Color.secondary }
        return now.timeIntervalSince(last) > 120 ? .orange : Color.secondary
    }

    private func jiraBrowseURL(_ key: String) -> URL? {
        guard let site = JiraSettingsStore.connectedSiteDisplay else { return nil }
        let base = site.hasPrefix("http") ? site : "https://\(site)"
        return URL(string: "\(base)/browse/\(key)")
    }

    /// Jira-задача: статус из Jira (капсула) + ссылка на задачу.
    @ViewBuilder
    private func jiraBadge(_ task: OrgTask) -> some View {
        if !task.jiraKey.isEmpty {
            HStack(spacing: 6) {
                if let status = task.jiraStatus, !status.isEmpty {
                    Text(status)
                        .font(.system(size: 9))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        .foregroundStyle(.secondary)
                        .help("Статус в Jira на момент последнего импорта")
                }
                if let url = jiraBrowseURL(task.jiraKey) {
                    Link(destination: url) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10))
                    }
                    .help("Открыть \(task.jiraKey) в Jira")
                }
            }
        }
    }

    // MARK: Панель этапа + чат агенту (правка №3, границы П9)

    @ViewBuilder
    private func stagePanel(_ stage: OrgStage, flow: OrgFlow, run: OrganizationRun?) -> some View {
        let isCurrent = run != nil && run?.currentStageID == stage.id && run?.status != .finished
        let isPassed = run.map { $0.path.contains(stage.id) && $0.currentStageID != stage.id } ?? false
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: OrgUI.stageIcon(stage.kind))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(stage.name)
                    .font(.system(size: 12, weight: .semibold))
                Text(OrgUI.stageSubtitle(stage, employees: run?.employees ?? []))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(isCurrent ? "текущий этап" : isPassed ? "пройден" : run == nil ? "" : "впереди")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if let run, isCurrent {
                currentStageControls(run)
            } else if isPassed {
                Text("Этап пройден — переписка по нему read-only (П9).")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else if run == nil {
                Text("Задача не запущена — этап ждёт токена.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Text("Этап впереди — токен ещё не дошёл.")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    /// Чат текущего этапа: активен в {ждёт гейта, требует внимания} —
    /// сообщение перезапускает этап с контекстом и меняет поведение
    /// сотрудника; в работе — заблокирован с причиной (7A).
    @ViewBuilder
    private func currentStageControls(_ run: OrganizationRun) -> some View {
        switch run.status {
        case .waitingGate, .needsAttention:
            if run.status == .needsAttention {
                Text(run.statusReason)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                // Понятный план устранения (правка автора): что делать —
                // шагами, с кнопками, не голая причина.
                if let plan = OrgUI.remediation(for: run.statusReason) {
                    RemediationView(plan: plan, runID: run.id, controller: controller)
                }
            }
            HStack(spacing: 8) {
                if run.status == .waitingGate {
                    Button("Принять") { controller.approve(run.id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Вернуть") {
                        controller.reject(run.id, comment: chatDrafts[run.id] ?? "")
                        chatDrafts[run.id] = nil
                    }
                    .controlSize(.small)
                }
                TextField(
                    run.status == .needsAttention
                        ? "Ответить сотруднику… (⏎)"
                        : "Комментарий или правка поведения… (⏎)",
                    text: Binding(
                        get: { chatDrafts[run.id] ?? "" },
                        set: { chatDrafts[run.id] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .onSubmit {
                    let text = (chatDrafts[run.id] ?? "").trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return }
                    controller.chat(run.id, text: text)
                    chatDrafts[run.id] = nil
                }
            }
        case .running:
            Text("Сотрудник работает — чат откроется на гейте или при вопросе.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        case .merging:
            Text("rebase → повторные тесты → merge…")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        default:
            EmptyView()
        }
    }

    // MARK: Клавиатура (11A) и возвраты (9A)

    private func closeDetail() {
        selectedTaskID = nil
        selectedStageID = nil
        armedApproveRunID = nil
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .escape where selectedTaskID != nil:
            closeDetail()
            return .handled
        case KeyEquivalent("n") where press.modifiers.isEmpty:
            return focusAttention(offset: 1)
        case KeyEquivalent("p") where press.modifiers.isEmpty:
            return focusAttention(offset: -1)
        case .return where press.modifiers == .command:
            return approveFocusedGate()
        default:
            return .ignored
        }
    }

    /// N/P — очередь внимания: открывает деталь следующего/предыдущего.
    private func focusAttention(offset: Int) -> KeyPress.Result {
        let queue = controller.attentionRuns
        guard !queue.isEmpty else { return .ignored }
        let current = queue.firstIndex(where: { $0.task.id == selectedTaskID })
        let next: Int
        if let current {
            next = (current + offset + queue.count) % queue.count
        } else {
            next = offset > 0 ? 0 : queue.count - 1
        }
        open(taskID: queue[next].task.id, run: queue[next])
        armedApproveRunID = nil
        return .handled
    }

    /// ⌘Enter — Принять только на открытом гейте; финальный гейт —
    /// двухшаговое подтверждение (11A).
    private func approveFocusedGate() -> KeyPress.Result {
        guard let id = selectedTaskID, let run = controller.run(forTask: id),
              run.status == .waitingGate
        else { return .ignored }
        if armedApproveRunID == run.id {
            armedApproveRunID = nil
            controller.approve(run.id)
        } else {
            armedApproveRunID = run.id
            Task {
                try? await Task.sleep(for: .seconds(3))
                if armedApproveRunID == run.id { armedApproveRunID = nil }
            }
        }
        return .handled
    }

    /// Токен поехал назад — возврат: янтарная вспышка узла-получателя (9A).
    /// Здесь же тихий пульс: свежий lastEventAt — короткий отклик токена (6A).
    private func trackReturns(_ newRuns: [UUID: OrganizationRun]) {
        for run in newRuns.values {
            let index = OrgUI.orderedStages(run.flow)
                .firstIndex(where: { $0.id == run.currentStageID }) ?? 0
            defer { stageMemo[run.id] = index }
            if let stamp = run.lastEventAt, lastEventMemo[run.id] != stamp {
                lastEventMemo[run.id] = stamp
                if run.status == .running {
                    pulsingRuns.insert(run.id)
                    Task {
                        try? await Task.sleep(for: .milliseconds(250))
                        _ = pulsingRuns.remove(run.id)
                    }
                }
            }
            guard let previous = stageMemo[run.id], index < previous else { continue }
            let stageID = run.currentStageID
            flashedStages.insert(stageID)
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                _ = flashedStages.remove(stageID)
            }
        }
    }
}
