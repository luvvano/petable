import SwiftUI
import GraphCore
import OrgEngine

/// Дебаггер запусков (слайс 12, 12A): три зоны — список запусков,
/// снапшот графа выбранного на позиции scrubber'а, таймлайн событий.
/// Replay = детерминированное воспроизведение записанных событий в UI
/// (без запуска CLI; повторное исполнение — это fork). Тени и форки —
/// пунктир + метка «экспериментальный» (13).
struct DebuggerView: View {
    @ObservedObject var document: PetableDocument
    @ObservedObject var controller: OrganizationController

    @State private var selectedRunID: UUID?
    @State private var compareRunID: UUID?
    /// Позиция scrubber'а — индекс события в журнале выбранного запуска.
    @State private var scrub: Double = 0
    @State private var events: [RunEvent] = []
    @State private var loadError: String?
    @State private var forkModel = ""

    private let store = EventStore(root: EventStore.defaultRoot())

    var body: some View {
        Group {
            if let organization = document.organization {
                content(organization)
            } else {
                Text("Организации ещё нет — Конвейер → Создать организацию.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await controller.connect(document: document) }
    }

    private func content(_ organization: Organization) -> some View {
        let items = runItems(organization)
        return HSplitView {
            runList(items)
                .frame(minWidth: 230, maxWidth: 320)
            detail(items, organization: organization)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Зона 1 — список запусков

    private struct RunItem: Identifiable {
        var id: UUID
        var title: String
        var live: OrganizationRun?
        var summary: RunSummary?
        var experimental: Bool
        var startedAt: Date
    }

    private func runItems(_ organization: Organization) -> [RunItem] {
        var seen = Set<UUID>()
        var items: [RunItem] = []
        for run in controller.runs.values.sorted(by: { $0.startedAt > $1.startedAt }) {
            seen.insert(run.id)
            items.append(RunItem(
                id: run.id,
                title: run.task.jiraKey.isEmpty ? run.task.title : "\(run.task.jiraKey) · \(run.task.title)",
                live: run,
                summary: nil,
                experimental: run.isExperimental,
                startedAt: run.startedAt
            ))
        }
        for summary in organization.runSummaries.reversed() where !seen.contains(summary.runID) {
            items.append(RunItem(
                id: summary.runID,
                title: summary.jiraKey.isEmpty ? summary.taskTitle : "\(summary.jiraKey) · \(summary.taskTitle)",
                live: nil,
                summary: summary,
                experimental: summary.experimental == true,
                startedAt: summary.startedAt
            ))
        }
        return items
    }

    private func runList(_ items: [RunItem]) -> some View {
        List(selection: $selectedRunID) {
            Section("ЗАПУСКИ") {
                ForEach(items) { item in
                    runRow(item).tag(item.id)
                }
            }
        }
        .listStyle(.inset)
        .onChange(of: selectedRunID) { _, newValue in
            loadEvents(newValue)
        }
        .onAppear {
            if selectedRunID == nil { selectedRunID = items.first?.id }
        }
    }

    private func runRow(_ item: RunItem) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(OrgUI.taskColor(item.live?.status ?? .finished))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(item.live.map(OrgUI.statusText)
                     ?? item.summary.map { outcomeText($0.outcome) } ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if item.experimental {
                Text("эксп.")
                    .font(.system(size: 9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(
                        Capsule().strokeBorder(
                            Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                        )
                    )
                    .foregroundStyle(.secondary)
                    .help("Экспериментальный запуск: Jira/push/merge выключены")
            }
        }
        .opacity(item.experimental ? 0.7 : 1)
        .padding(.vertical, 1)
    }

    // MARK: Зоны 2–3 — снапшот графа + таймлайн

    @ViewBuilder
    private func detail(_ items: [RunItem], organization: Organization) -> some View {
        if let id = selectedRunID, let item = items.first(where: { $0.id == id }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(item)
                    if let error = loadError {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                    if let snapshot = snapshotRun {
                        flowSnapshot(snapshot)
                        timeline
                        eventDetail
                    } else if events.isEmpty {
                        Text("Журнал запуска недоступен: события не найдены в хранилище.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let compareID = compareRunID, compareID != id {
                        compareSection(items, selected: item, compareID: compareID)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            Text("Выбери запуск слева — replay по его событиям.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ item: RunItem) -> some View {
        HStack(spacing: 10) {
            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
            if item.experimental {
                Text("экспериментальный · Jira/push/merge выключены")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if item.live != nil {
                TextField("модель для fork", text: $forkModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .frame(width: 150)
                Button("Fork") {
                    controller.forkRun(item.id, model: forkModel.trimmingCharacters(in: .whitespaces))
                }
                .font(.system(size: 11))
                .help("Повторное исполнение с текущего этапа от точки форка; модель — override для всех сотрудников (⌥Enter)")
            }
            Picker("Сравнить с", selection: Binding(
                get: { compareRunID },
                set: { compareRunID = $0 }
            )) {
                Text("—").tag(nil as UUID?)
                ForEach(runItems(document.organization ?? Organization())) { other in
                    if other.id != item.id {
                        Text(other.title).tag(other.id as UUID?)
                    }
                }
            }
            .fixedSize()
            .font(.system(size: 11))
        }
    }

    /// Состояние запуска на позиции scrubber'а: последний слепок ≤ позиции.
    private var snapshotRun: OrganizationRun? {
        let position = min(Int(scrub), max(0, events.count - 1))
        guard position >= 0, !events.isEmpty else { return nil }
        return events.prefix(through: position)
            .reversed()
            .first(where: { $0.kindValue == .snapshot })?.run
            ?? events.compactMap(\.run).first
    }

    private func flowSnapshot(_ run: OrganizationRun) -> some View {
        let stages = OrgUI.orderedStages(run.flow)
        let currentIndex = stages.firstIndex(where: { $0.id == run.currentStageID })
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                    StageNodeView(
                        stage: stage,
                        subtitle: OrgUI.stageSubtitle(stage, employees: run.employees),
                        emphasis: emphasis(stage, index: index, currentIndex: currentIndex, run: run)
                    )
                    if stage.id != stages.last?.id {
                        EdgeArrowView()
                    }
                }
            }
        }
    }

    private func emphasis(
        _ stage: OrgStage, index: Int, currentIndex: Int?, run: OrganizationRun
    ) -> StageEmphasis {
        guard let currentIndex else { return .idle }
        if index < currentIndex { return .passed }
        if index == currentIndex { return .current }
        return .dimmed
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("СОБЫТИЯ")
                    .font(.system(size: 9, weight: .medium))
                    .kerning(1)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(min(Int(scrub) + 1, events.count)) из \(events.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Slider(
                value: $scrub,
                in: 0...Double(max(events.count - 1, 0)),
                step: 1
            )
            .disabled(events.count < 2)
        }
    }

    @ViewBuilder
    private var eventDetail: some View {
        let position = min(Int(scrub), max(0, events.count - 1))
        if position >= 0, position < events.count {
            let event = events[position]
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(eventLabel(event))
                        .font(.system(size: 11, weight: .semibold))
                    Text(event.date.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if let text = event.text, !text.isEmpty {
                    Text(text.prefix(600))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        }
    }

    /// Словарь 8A: события журнала — человеческим языком.
    private func eventLabel(_ event: RunEvent) -> String {
        switch event.kindValue {
        case .runStarted: return "Запуск начат"
        case .snapshot: return "Слепок состояния"
        case .stageStarted: return "Этап начат"
        case .log: return "Лог"
        case .artifact: return "Артефакт"
        case .needsInput: return "Вопрос сотрудника"
        case .stageFinished: return "Этап завершён"
        case .stageFailed: return "Этап упал"
        case .gateApproved: return "Принято"
        case .gateRejected: return "Возвращено"
        case .returned: return "Возврат"
        case .needsAttention: return "Требует внимания"
        case .testPassed: return "Тесты прошли"
        case .testFailed: return "Тесты упали"
        case .intent: return "Намерение (эффект вовне)"
        case .effectConfirmed: return "Эффект подтверждён"
        case .processSpawned: return "Процесс порождён"
        case .runFinished: return "Запуск завершён"
        case nil: return event.kind
        }
    }

    // MARK: Сравнение (12A)

    private func compareSection(
        _ items: [RunItem], selected: RunItem, compareID: UUID
    ) -> some View {
        let other = items.first(where: { $0.id == compareID })
        return VStack(alignment: .leading, spacing: 6) {
            Text("СРАВНЕНИЕ")
                .font(.system(size: 9, weight: .medium))
                .kerning(1)
                .foregroundStyle(.tertiary)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 4) {
                GridRow {
                    Text("")
                    Text(selected.title).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    Text(other?.title ?? "").font(.system(size: 10, weight: .semibold)).lineLimit(1)
                }
                compareRow("Статус", metric(selected, \.statusMetric), other.map { metric($0, \.statusMetric) } ?? "")
                compareRow("Время", metric(selected, \.durationMetric), other.map { metric($0, \.durationMetric) } ?? "")
                compareRow("Возвраты", metric(selected, \.returnsMetric), other.map { metric($0, \.returnsMetric) } ?? "")
                compareRow("≈Стоимость", metric(selected, \.costMetric), other.map { metric($0, \.costMetric) } ?? "")
            }
            .font(.system(size: 11))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func compareRow(_ label: String, _ left: String, _ right: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(left)
            Text(right)
        }
    }

    private func metric(_ item: RunItem, _ keyPath: KeyPath<RunMetrics, String>) -> String {
        RunMetrics(item: item)[keyPath: keyPath]
    }

    private struct RunMetrics {
        let item: RunItem

        var statusMetric: String {
            if let live = item.live { return OrgUI.statusText(live) }
            if let summary = item.summary {
                switch summary.outcome {
                case .merged: return "смёржено"
                case .cancelled: return "отменено"
                case .closed: return "закрыто"
                case .broken: return "повреждён"
                }
            }
            return ""
        }

        var durationMetric: String {
            let start = item.startedAt
            let end = item.live?.finishedAt ?? item.summary?.finishedAt ?? Date()
            let seconds = max(0, Int(end.timeIntervalSince(start)))
            if seconds < 60 { return "\(seconds) сек" }
            if seconds < 3600 { return "\(seconds / 60) мин" }
            return "\(seconds / 3600) ч \((seconds % 3600) / 60) мин"
        }

        var returnsMetric: String {
            "\(item.live?.returnCount ?? item.summary?.returnCount ?? 0) из 3"
        }

        var costMetric: String {
            let cost = item.live?.costEstimate ?? item.summary?.costEstimate ?? 0
            return cost > 0 ? String(format: "≈$%.2f", cost) : "—"
        }
    }

    // MARK: Данные

    private func loadEvents(_ runID: UUID?) {
        events = []
        loadError = nil
        scrub = 0
        guard let runID, let orgID = document.organization?.orgID else { return }
        switch store.load(orgID: orgID, runID: runID) {
        case let .events(loaded):
            events = loaded
            scrub = Double(max(loaded.count - 1, 0)) // финал по умолчанию
        case let .broken(reason):
            loadError = "Журнал повреждён: \(reason)"
        }
    }

    private func outcomeText(_ outcome: RunOutcome) -> String {
        switch outcome {
        case .merged: return "смёржено"
        case .cancelled: return "отменено"
        case .closed: return "закрыто"
        case .broken: return "повреждён"
        }
    }
}
