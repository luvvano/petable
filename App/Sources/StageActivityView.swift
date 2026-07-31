import SwiftUI
import GraphCore
import OrgEngine

/// Окно этапа (правка автора 2026-07-31, референс — Codex/Claude Code):
/// клик по этапу задачи открывает живую панель — шапка с сотрудником и
/// статусом, ссылки из работы агента (PR, коммиты), лог агента
/// (моноширинный, автоскролл) и чат со всей перепиской. Переписка —
/// события журнала, переживает рестарты (П9).
struct StageActivityView: View {
    let run: OrganizationRun
    let stage: OrgStage
    @ObservedObject var controller: OrganizationController

    @State private var events: [RunEvent] = []
    @State private var draft = ""
    /// Свёрнут ли лог (по умолчанию виден хвост).
    @State private var logExpanded = false

    private let store = EventStore(root: EventStore.defaultRoot())

    private var isCurrent: Bool {
        run.currentStageID == stage.id && run.status != .finished
    }

    private var isPassed: Bool {
        run.path.contains(stage.id) && run.currentStageID != stage.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if run.status == .needsAttention, isCurrent {
                Text(run.statusReason)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                if let plan = OrgUI.remediation(for: run.statusReason) {
                    RemediationView(plan: plan, runID: run.id, controller: controller)
                }
            }
            if !links.isEmpty {
                linkChips
            }
            if !artifacts.isEmpty {
                artifactSection
            }
            if !logLines.isEmpty {
                logSection
            }
            chatSection
            inputBar
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
        .task(id: refreshKey) { loadEvents() }
        .onReceive(
            Timer.publish(every: 2, on: .main, in: .common).autoconnect()
        ) { _ in
            // Живой лог: панель открыта — дочитываем журнал (полный лог
            // из файла по запросу, решение 6A).
            if isCurrent, run.status == .running { loadEvents() }
        }
    }

    /// Перечитать журнал при смене этапа/статуса.
    private var refreshKey: String {
        "\(run.id)-\(stage.id)-\(run.status.rawValue)-\(run.lastEventAt?.timeIntervalSince1970 ?? 0)"
    }

    // MARK: Шапка

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: OrgUI.stageIcon(stage.kind))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(stage.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(employeeLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            stageStateBadge
        }
    }

    private var employeeLine: String {
        guard let employee = run.employee(for: stage) else {
            return OrgUI.stageSubtitle(stage, employees: run.employees)
        }
        var parts = [employee.name, employee.adapter.cli]
        if !employee.adapter.model.isEmpty { parts.append(employee.adapter.model) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var stageStateBadge: some View {
        if isCurrent {
            HStack(spacing: 6) {
                if run.status == .running {
                    ProgressView().controlSize(.mini)
                }
                Text(OrgUI.statusText(run))
                    .font(.system(size: 10))
                    .foregroundStyle(OrgUI.taskColor(run.status))
            }
        } else {
            Text(isPassed ? "пройден" : "впереди")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Ссылки из работы агента (PR, коммиты)

    private struct WorkLink: Identifiable {
        var id: String { url.absoluteString }
        var title: String
        var url: URL
    }

    /// URL из лога и вердиктов этапа + PR рабочей ветки + коммит merge:
    /// агент создал PR — ссылка всплывает чипом, не теряется в логе.
    private var links: [WorkLink] {
        var found: [WorkLink] = []
        var seen = Set<String>()
        let texts = [run.prURL, run.commitURL].compactMap { $0 }
            + stageEvents.compactMap(\.text)
        for text in texts {
            for match in Self.urlPattern.matches(
                in: text, range: NSRange(text.startIndex..., in: text)
            ) {
                guard let range = Range(match.range, in: text) else { continue }
                let raw = String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;)»”"))
                guard seen.insert(raw).inserted, let url = URL(string: raw) else { continue }
                found.append(WorkLink(title: Self.linkTitle(raw), url: url))
            }
        }
        return Array(found.prefix(8))
    }

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"https?://[^\s"'()<>\]]+"#
    )

    static func linkTitle(_ url: String) -> String {
        if let match = url.range(of: #"/pull/(\d+)"#, options: .regularExpression) {
            return "PR #\(url[match].split(separator: "/").last ?? "")"
        }
        if let match = url.range(of: #"/commit/([0-9a-f]{7,40})"#, options: .regularExpression) {
            let sha = url[match].split(separator: "/").last ?? ""
            return "коммит \(sha.prefix(7))"
        }
        return URL(string: url)?.host ?? url
    }

    private var linkChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(links) { link in
                    Link(destination: link.url) {
                        Label(link.title, systemImage: "link")
                            .font(.system(size: 10))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    }
                    .help(link.url.absoluteString)
                }
            }
        }
    }

    // MARK: Артефакты этапа

    private struct StageArtifact: Identifiable {
        var id: Int
        var label: String
        var sha: String?
    }

    /// Что этап произвёл: коммиты (sha) и файлы из artifact-событий.
    private var artifacts: [StageArtifact] {
        stageEvents.enumerated().compactMap { index, event in
            guard event.kindValue == .artifact else { return nil }
            if let sha = event.sha {
                return StageArtifact(id: index, label: "коммит \(sha.prefix(7))", sha: sha)
            }
            let path = event.text ?? ""
            guard !path.isEmpty else { return nil }
            let name = (path as NSString).lastPathComponent
            return StageArtifact(id: index, label: "\(event.status ?? "файл"): \(name)", sha: nil)
        }
    }

    private var artifactSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("АРТЕФАКТЫ ЭТАПА")
                .font(.system(size: 9, weight: .medium))
                .kerning(1)
                .foregroundStyle(.tertiary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(artifacts) { artifact in
                        Label(artifact.label, systemImage: artifact.sha != nil ? "checkmark.seal" : "doc")
                            .font(.system(size: 10, design: artifact.sha != nil ? .monospaced : .default))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.green.opacity(0.10)))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Лог агента

    private var stageEvents: [RunEvent] {
        events.filter { $0.stageID == stage.id }
    }

    private var logLines: [(id: Int, text: String)] {
        let lines = stageEvents
            .filter {
                let kind = $0.kindValue
                return kind == .log || kind == .stageStarted || kind == .stageFailed
                    || kind == .artifact || kind == .testFailed || kind == .testPassed
            }
            .flatMap { event -> [String] in
                switch event.kindValue {
                case .stageStarted: return ["— этап начат —"]
                case .artifact: return ["артефакт: \(event.text ?? "")"]
                default: return (event.text ?? "").split(separator: "\n").map(String.init)
                }
            }
        return lines.suffix(logExpanded ? 400 : 80).enumerated().map { ($0.offset, $0.element) }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("ЛОГ АГЕНТА")
                    .font(.system(size: 9, weight: .medium))
                    .kerning(1)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(logExpanded ? "Свернуть" : "Развернуть") {
                    logExpanded.toggle()
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(logLines, id: \.id) { line in
                            Text(line.text)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                }
                .frame(height: logExpanded ? 320 : 140)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .underPageBackgroundColor))
                )
                .onChange(of: logLines.count) { _, _ in
                    if let last = logLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onAppear {
                    if let last = logLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: Чат — вся переписка этапа

    private struct ChatEntry: Identifiable {
        var id: Int
        var fromHuman: Bool
        var text: String
        var date: Date
    }

    /// Хронология: сообщения человека (chatMessage, включая комментарии
    /// «Вернуть»), вопросы агента (needsInput) и его ответы-вердикты
    /// (stageFinished note).
    private var chat: [ChatEntry] {
        stageEvents.enumerated().compactMap { index, event in
            switch event.kindValue {
            case .chatMessage:
                return ChatEntry(id: index, fromHuman: true, text: event.text ?? "", date: event.date)
            case .needsInput:
                return ChatEntry(
                    id: index, fromHuman: false,
                    text: event.text ?? "", date: event.date
                )
            case .stageFinished:
                guard let note = event.text, !note.isEmpty else { return nil }
                return ChatEntry(id: index, fromHuman: false, text: note, date: event.date)
            default:
                return nil
            }
        }
    }

    @ViewBuilder
    private var chatSection: some View {
        if !chat.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("ПЕРЕПИСКА")
                    .font(.system(size: 9, weight: .medium))
                    .kerning(1)
                    .foregroundStyle(.tertiary)
                ForEach(chat) { entry in
                    chatBubble(entry)
                }
            }
        }
    }

    private func chatBubble(_ entry: ChatEntry) -> some View {
        HStack {
            if entry.fromHuman { Spacer(minLength: 40) }
            VStack(alignment: entry.fromHuman ? .trailing : .leading, spacing: 2) {
                Text(entry.text)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(entry.fromHuman
                                ? Color.accentColor.opacity(0.18)
                                : Color.secondary.opacity(0.12))
                    )
                Text("\(entry.fromHuman ? "вы" : "сотрудник") · \(entry.date.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if !entry.fromHuman { Spacer(minLength: 40) }
        }
    }

    // MARK: Ввод — воздействие на агента (границы П9)

    @ViewBuilder
    private var inputBar: some View {
        if isCurrent {
            switch run.status {
            case .waitingGate, .needsAttention:
                HStack(spacing: 8) {
                    if run.status == .waitingGate {
                        Button(stage.kind == .merge && run.isExperimental ? "Завершить" : "Принять") {
                            controller.approve(run.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        Button("Вернуть") {
                            controller.reject(run.id, comment: draft)
                            draft = ""
                        }
                        .controlSize(.small)
                    }
                    TextField(
                        run.status == .needsAttention
                            ? "Ответить сотруднику… (⏎)"
                            : "Замечание или правка — этап перезапустится с ним… (⏎)",
                        text: $draft
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit(sendDraft)
                    Button("Отправить", action: sendDraft)
                        .controlSize(.small)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            case .running:
                Label("Сотрудник работает — чат откроется на гейте или при вопросе (П9)",
                      systemImage: "hourglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            case .merging:
                Label("rebase → повторные тесты → merge…", systemImage: "arrow.triangle.pull")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            default:
                EmptyView()
            }
        } else if isPassed {
            Label("Этап пройден — переписка read-only: артефакт уже потреблён дальше (П9)",
                  systemImage: "lock")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        } else {
            Label("Этап впереди — токен ещё не дошёл", systemImage: "circle.dashed")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        controller.chat(run.id, text: text)
        draft = ""
        // Оптимистично дочитаем журнал чуть позже — сообщение уже там.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            loadEvents()
        }
    }

    // MARK: Данные

    private func loadEvents() {
        if case let .events(loaded) = store.load(orgID: run.orgID, runID: run.id) {
            events = loaded
        }
    }
}
