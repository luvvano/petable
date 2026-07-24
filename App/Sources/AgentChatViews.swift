import SwiftUI
import UniformTypeIdentifiers
import GraphCore

// MARK: - Сессия чата

/// Одна вкладка чата с агентом: своя лента, свой черновик и вложения.
/// История сессий не персистится — живёт, пока открыто окно проекта.
@MainActor
final class AgentChatSession: ObservableObject, Identifiable {
    struct Message: Identifiable, Equatable {
        enum Role {
            case user
            case assistant
        }

        let id = UUID()
        var role: Role
        var text: String
        var attachments: [AgentAttachment] = []
        /// Результаты применённых команд («Создан граф …») под сообщением.
        var actionResults: [String] = []
    }

    let id = UUID()
    @Published var title: String
    @Published private(set) var messages: [Message] = []
    @Published private(set) var running = false
    @Published var errorMessage: String?
    @Published var draft = ""
    @Published var pendingAttachments: [AgentAttachment] = []

    init(title: String) {
        self.title = title
    }

    func clear() {
        messages = []
        errorMessage = nil
        pendingAttachments = []
    }

    /// Добавляет файлы к следующему сообщению; ошибки загрузки — в ленту.
    func attach(urls: [URL]) {
        var failures: [String] = []
        for url in urls {
            do {
                pendingAttachments.append(try AgentAttachment.load(from: url))
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        errorMessage = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func removeAttachment(_ id: AgentAttachment.ID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// Отправка хода: история + контекст проекта → провайдер → разбор
    /// команд → применение к документу.
    func send(document: PetableDocument, config: AgentTaskConfig) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        errorMessage = nil
        messages.append(Message(role: .user, text: text, attachments: pendingAttachments))
        draft = ""
        pendingAttachments = []
        if title.hasPrefix("Чат ") {
            title = String(text.prefix(24))
        }

        let turns = messages.map { message in
            AgentChatTurn(
                role: message.role == .user ? .user : .assistant,
                text: message.text,
                attachments: message.attachments
            )
        }
        let context = AgentChatContext.describe(
            graphs: document.graphStages,
            research: document.research,
            segments: document.segmentation.segments
        )

        running = true
        Task {
            do {
                let raw = try await AgentService.runChat(
                    turns: turns,
                    projectContext: context,
                    config: config
                )
                let reply = AgentChatReply.parse(from: raw)
                var results = document.applyChatActions(reply.actions)
                if reply.invalidActionCount > 0 {
                    results.append("⚠️ Команд не разобрано: \(reply.invalidActionCount)")
                }
                messages.append(Message(
                    role: .assistant,
                    text: reply.text.isEmpty ? "Готово." : reply.text,
                    actionResults: results
                ))
            } catch {
                errorMessage = error.localizedDescription
            }
            running = false
        }
    }
}

// MARK: - Контроллер вкладок

/// Вкладки чата одного окна проекта: список сессий + выбранная.
@MainActor
final class AgentChatController: ObservableObject {
    @Published private(set) var sessions: [AgentChatSession]
    @Published var selectedID: UUID

    private var createdCount = 1

    init() {
        let first = AgentChatSession(title: "Чат 1")
        sessions = [first]
        selectedID = first.id
    }

    var selectedSession: AgentChatSession {
        sessions.first { $0.id == selectedID } ?? sessions[0]
    }

    func addSession() {
        createdCount += 1
        let session = AgentChatSession(title: "Чат \(createdCount)")
        sessions.append(session)
        selectedID = session.id
    }

    /// Закрывает вкладку. true — закрыта последняя: панель стоит скрыть
    /// (контроллер при этом сбрасывается к одной пустой сессии).
    func closeSession(_ id: UUID) -> Bool {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
        sessions.remove(at: index)
        if sessions.isEmpty {
            createdCount = 1
            let fresh = AgentChatSession(title: "Чат 1")
            sessions = [fresh]
            selectedID = fresh.id
            return true
        }
        if selectedID == id {
            selectedID = sessions[min(index, sessions.count - 1)].id
        }
        return false
    }
}

// MARK: - Панель чата

/// Панель «Агент» справа от контента окна: вкладки сессий, вопросы по
/// методологии AJTBD и команды над артефактами. Немодальная — канвас
/// и формы остаются видимыми, правки агента появляются сразу.
struct AgentChatPanel: View {
    @ObservedObject var document: PetableDocument
    @ObservedObject var controller: AgentChatController
    var onClose: () -> Void

    @AppStorage("agent.defaultProvider") private var defaultProviderRaw = AgentProvider.claude.rawValue
    @AppStorage("agent.claudeModel") private var claudeModel = AgentProvider.claude.defaultModel
    @AppStorage("agent.codexModel") private var codexModel = AgentProvider.codex.defaultModel
    @AppStorage("agent.effort") private var effortRaw = AgentEffort.high.rawValue
    @AppStorage("agent.claude.authMode") private var claudeAuthModeRaw = AgentAuthMode.apiToken.rawValue
    @AppStorage("agent.codex.authMode") private var codexAuthModeRaw = AgentAuthMode.apiToken.rawValue

    private func authMode(for provider: AgentProvider) -> AgentAuthMode {
        let raw = provider == .claude ? claudeAuthModeRaw : codexAuthModeRaw
        return AgentAuthMode(rawValue: raw) ?? .apiToken
    }

    /// Провайдер доступен: токен задан (режим API) либо CLI установлен.
    private var availableProviders: [AgentProvider] {
        AgentProvider.allCases.filter { provider in
            switch authMode(for: provider) {
            case .apiToken: return AgentTokenStore.hasToken(for: provider)
            case .subscription: return AgentCLI.isAvailable(provider)
            }
        }
    }

    private var provider: AgentProvider {
        let stored = AgentProvider(rawValue: defaultProviderRaw) ?? .claude
        return availableProviders.contains(stored) ? stored : (availableProviders.first ?? .claude)
    }

    private var config: AgentTaskConfig {
        AgentTaskConfig(
            provider: provider,
            authMode: authMode(for: provider),
            model: provider == .claude ? claudeModel : codexModel,
            effort: AgentEffort(rawValue: effortRaw) ?? .high
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            tabBar
            Divider()
            if availableProviders.isEmpty {
                ContentUnavailableView {
                    Label("Нет доступа к агентам", systemImage: "key.slash")
                } description: {
                    Text("В настройках (⌘,) добавьте API-токен Claude/Codex или включите режим «Подписка (CLI)».")
                }
            } else {
                AgentChatSessionView(
                    document: document,
                    session: controller.selectedSession,
                    config: config
                )
                .id(controller.selectedID)
            }
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Агент", systemImage: "sparkles")
                .font(.system(size: 13, weight: .semibold))
            if !availableProviders.isEmpty {
                Text("\(provider.title) · \(config.model)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help("Провайдер и модель — из настроек (⌘,)")
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("Закрыть панель агента")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// Полоса вкладок: сессии + «новая вкладка».
    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(controller.sessions) { session in
                        tab(session)
                    }
                }
            }
            Button {
                controller.addSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("Новая вкладка — отдельная сессия агента")
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }

    private func tab(_ session: AgentChatSession) -> some View {
        let selected = session.id == controller.selectedID
        return HStack(spacing: 4) {
            SessionTabTitle(session: session)
            Button {
                if controller.closeSession(session.id) { onClose() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Закрыть вкладку")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
        )
        .contentShape(Rectangle())
        .onTapGesture { controller.selectedID = session.id }
    }
}

/// Заголовок вкладки — отдельная вью, чтобы наблюдать @Published title
/// сессии (переименовывается по первому сообщению).
private struct SessionTabTitle: View {
    @ObservedObject var session: AgentChatSession

    var body: some View {
        HStack(spacing: 4) {
            Text(session.title)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
            if session.running {
                ProgressView().controlSize(.mini)
            }
        }
    }
}

// MARK: - Содержимое одной сессии

struct AgentChatSessionView: View {
    @ObservedObject var document: PetableDocument
    @ObservedObject var session: AgentChatSession
    var config: AgentTaskConfig

    @State private var importerShown = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            if !session.pendingAttachments.isEmpty {
                pendingAttachmentsBar
                Divider()
            }
            inputBar
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.messages.isEmpty {
                        emptyHint
                    }
                    ForEach(session.messages) { message in
                        messageBubble(message)
                            .id(message.id)
                    }
                    if session.running {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Агент думает…")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .id("running")
                    }
                    if let errorMessage = session.errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .id("error")
                    }
                }
                .padding(12)
            }
            .onChange(of: session.messages) { _, messages in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: session.running) { _, running in
                if running {
                    withAnimation { proxy.scrollTo("running", anchor: .bottom) }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedFiles(providers)
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Спросите про методологию AJTBD или попросите поработать с артефактами проекта.")
            Text("Например: «чем работа отличается от потребности?», «добавь в граф уровень микро-работ», «заполни критерии успеха в интервью».")
                .foregroundStyle(.secondary)
            Text("Файлы (скриншоты, PDF, заметки) можно приложить скрепкой или перетащить сюда.")
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11.5))
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func messageBubble(_ message: AgentChatSession.Message) -> some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
            if !message.attachments.isEmpty {
                ForEach(message.attachments) { attachment in
                    attachmentChip(attachment, removable: false)
                }
            }
            Text(message.text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(message.role == .user
                            ? Color.accentColor.opacity(0.16)
                            : Color.primary.opacity(0.05))
                )
            ForEach(message.actionResults, id: \.self) { result in
                Label(result, systemImage: result.hasPrefix("⚠️")
                    ? "exclamationmark.triangle"
                    : "checkmark.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(result.hasPrefix("⚠️") ? Color.orange : Color.purple)
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: message.role == .user ? .trailing : .leading
        )
    }

    /// Чип вложения: превью картинки или иконка + имя (+ удаление
    /// для ещё не отправленных).
    private func attachmentChip(_ attachment: AgentAttachment, removable: Bool) -> some View {
        HStack(spacing: 6) {
            if attachment.isImage, let image = NSImage(data: attachment.data) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                Image(systemName: attachment.isImage ? "photo" : "doc.text")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Text(attachment.fileName)
                .font(.system(size: 10.5))
                .lineLimit(1)
                .truncationMode(.middle)
            if removable {
                Button {
                    session.removeAttachment(attachment.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Убрать вложение")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .frame(maxWidth: 220, alignment: .leading)
    }

    /// Вложения, ожидающие отправки со следующим сообщением.
    private var pendingAttachmentsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(session.pendingAttachments) { attachment in
                    attachmentChip(attachment, removable: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                importerShown = true
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 13))
            }
            .buttonStyle(.borderless)
            .disabled(session.running)
            .help("Приложить файлы: картинки, PDF, текст")
            TextField("Вопрос агенту…", text: $session.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 18))
            }
            .buttonStyle(.borderless)
            .disabled(
                session.running
                    || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .help("Отправить (Return)")
        }
        .padding(10)
        .onAppear { inputFocused = true }
        .fileImporter(
            isPresented: $importerShown,
            allowedContentTypes: [.image, .pdf, .text, .json, .commaSeparatedText, .data],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                session.attach(urls: urls)
            }
        }
    }

    private func send() {
        session.send(document: document, config: config)
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        let urlProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !urlProviders.isEmpty else { return false }
        for provider in urlProviders {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    session.attach(urls: [url])
                }
            }
        }
        return true
    }
}
