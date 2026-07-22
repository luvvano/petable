import SwiftUI
import GraphCore

// MARK: - Настройки агента (окно Settings, ⌘,)

/// Настройки ИИ-агента: токены Claude/Codex (Keychain) + значения
/// по умолчанию для задач (источник, модель, effort).
struct AgentSettingsView: View {
    @State private var claudeToken = AgentTokenStore.token(for: .claude) ?? ""
    @State private var codexToken = AgentTokenStore.token(for: .codex) ?? ""
    @State private var tokenGuideShown = false

    @AppStorage("agent.defaultProvider") private var defaultProvider = AgentProvider.claude.rawValue
    @AppStorage("agent.claudeModel") private var claudeModel = AgentProvider.claude.defaultModel
    @AppStorage("agent.codexModel") private var codexModel = AgentProvider.codex.defaultModel
    @AppStorage("agent.effort") private var effort = AgentEffort.high.rawValue
    @AppStorage("agent.claude.authMode") private var claudeAuthMode = AgentAuthMode.apiToken.rawValue
    @AppStorage("agent.codex.authMode") private var codexAuthMode = AgentAuthMode.apiToken.rawValue

    var body: some View {
        Form {
            Section("Способ доступа") {
                authModeRow(provider: .claude, mode: $claudeAuthMode)
                authModeRow(provider: .codex, mode: $codexAuthMode)
                Text("«API-токен» — оплата за токены по ключу из личного кабинета. «Подписка (CLI)» — запросы идут через установленный на этом Mac CLI (Claude Code / Codex CLI) и тратят лимиты вашей подписки Claude Pro/Max или ChatGPT Plus/Pro; токен не нужен.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Токены API") {
                SecureField("Claude (Anthropic API key)", text: $claudeToken)
                    .onChange(of: claudeToken) { _, value in
                        AgentTokenStore.setToken(value, for: .claude)
                    }
                SecureField("Codex (OpenAI API key)", text: $codexToken)
                    .onChange(of: codexToken) { _, value in
                        AgentTokenStore.setToken(value, for: .codex)
                    }
                Text("Токены хранятся в Keychain этого Mac и не попадают в файл проекта.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button {
                    tokenGuideShown = true
                } label: {
                    Label("Как получить токен?", systemImage: "questionmark.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.link)
            }

            Section("Агент по умолчанию") {
                Picker("Источник", selection: $defaultProvider) {
                    ForEach(AgentProvider.allCases) { provider in
                        Text(provider.title).tag(provider.rawValue)
                    }
                }
                modelField(provider: .claude, model: $claudeModel)
                modelField(provider: .codex, model: $codexModel)
                Picker("Effort", selection: $effort) {
                    ForEach(AgentEffort.allCases) { level in
                        Text(level.rawValue).tag(level.rawValue)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
        .sheet(isPresented: $tokenGuideShown) {
            TokenGuideView()
        }
    }

    /// Строка выбора режима доступа + статус CLI для режима подписки.
    @ViewBuilder
    private func authModeRow(provider: AgentProvider, mode: Binding<String>) -> some View {
        let cliInstalled = AgentCLI.isAvailable(provider)
        VStack(alignment: .leading, spacing: 4) {
            Picker(provider.title, selection: mode) {
                ForEach(AgentAuthMode.allCases) { authMode in
                    Text(authMode.title).tag(authMode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            if mode.wrappedValue == AgentAuthMode.subscription.rawValue {
                Label(
                    cliInstalled
                        ? "\(provider.cliTitle) найден — используется \(provider.subscriptionHint)"
                        : "\(provider.cliTitle) не найден («\(provider.cliName)» нет в PATH). Установите CLI и войдите: \(provider.subscriptionHint).",
                    systemImage: cliInstalled ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .font(.system(size: 11))
                .foregroundStyle(cliInstalled ? Color.green : Color.orange)
            }
        }
    }

    @ViewBuilder
    private func modelField(provider: AgentProvider, model: Binding<String>) -> some View {
        HStack {
            TextField("Модель \(provider.title)", text: model)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            Menu {
                ForEach(provider.suggestedModels, id: \.self) { suggestion in
                    Button(suggestion) { model.wrappedValue = suggestion }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

// MARK: - Гайд «Как получить токен?»

/// Пошаговая инструкция получения API-токенов Claude (Anthropic)
/// и Codex (OpenAI) — простыми словами + команды для Терминала
/// с кнопками копирования. Открывается из настроек.
struct TokenGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Как получить токен")
                        .font(.system(size: 18, weight: .bold))

                    Text("Токен (API-ключ) — это пароль, по которому petable ходит к нейросети от вашего имени. Ключ выдаётся в личном кабинете провайдера — это обычный сайт, где вы регистрируетесь по почте и привязываете оплату. Сам ключ создаётся на сайте (по-другому нельзя), а открыть нужную страницу и проверить, что ключ работает, можно командами из Терминала — они ниже, каждая копируется кнопкой.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    // MARK: Claude
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Claude — токен Anthropic", systemImage: "sparkle")
                            .font(.system(size: 14, weight: .semibold))

                        step(1, "Откройте Терминал (Finder → Программы → Утилиты → Terminal) и выполните команду — откроется страница API-ключей в личном кабинете Anthropic:")
                        commandBlock(#"open "https://platform.claude.com/settings/keys""#)

                        step(2, "Если аккаунта нет — зарегистрируйтесь по почте. В разделе Billing привяжите карту или купите кредиты (без этого API не отвечает).")
                        step(3, "На странице ключей нажмите «Create Key», назовите его «petable» и скопируйте ключ вида sk-ant-… Показывается один раз — копируйте сразу.")
                        step(4, "Проверьте ключ из Терминала (подставьте свой вместо sk-ant-…):")
                        commandBlock("""
                        curl -s https://api.anthropic.com/v1/messages \\
                          -H "x-api-key: sk-ant-ВАШ-КЛЮЧ" \\
                          -H "anthropic-version: 2023-06-01" \\
                          -H "content-type: application/json" \\
                          -d '{"model":"claude-haiku-4-5","max_tokens":32,"messages":[{"role":"user","content":"ping"}]}'
                        """)
                        Text("Ответ начинается с {\"id\":\"msg_… — ключ работает. Ответ с «authentication_error» — ключ скопирован неверно; с «billing» — не настроена оплата.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        step(5, "Вставьте ключ в поле «Claude» на экране настроек petable.")
                    }

                    Divider()

                    // MARK: Codex
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Codex — токен OpenAI", systemImage: "circle.hexagongrid")
                            .font(.system(size: 14, weight: .semibold))

                        step(1, "Выполните в Терминале — откроется страница API-ключей в личном кабинете OpenAI:")
                        commandBlock(#"open "https://platform.openai.com/api-keys""#)

                        step(2, "Зарегистрируйтесь или войдите. В разделе Billing привяжите карту или пополните баланс.")
                        step(3, "Нажмите «Create new secret key», назовите «petable» и скопируйте ключ вида sk-… Показывается один раз.")
                        step(4, "Проверьте ключ из Терминала:")
                        commandBlock("""
                        curl -s https://api.openai.com/v1/responses \\
                          -H "Authorization: Bearer sk-ВАШ-КЛЮЧ" \\
                          -H "content-type: application/json" \\
                          -d '{"model":"gpt-5.1","input":"ping"}'
                        """)
                        Text("Ответ с \"id\": \"resp_… — ключ работает; «invalid_api_key» — ключ скопирован неверно.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        step(5, "Вставьте ключ в поле «Codex» на экране настроек petable.")
                    }

                    Divider()

                    // MARK: Подписка
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Без токена — по подписке", systemImage: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Если у вас есть подписка Claude Pro/Max или ChatGPT Plus/Pro, токен не нужен: в настройках переключите способ доступа на «Подписка (CLI)». Запросы пойдут через CLI, установленный на этом Mac, и будут тратить лимиты подписки.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        step(1, "Claude: установите Claude Code и войдите с аккаунтом подписки:")
                        commandBlock("""
                        npm install -g @anthropic-ai/claude-code
                        claude /login
                        """)
                        step(2, "Codex: установите Codex CLI и войдите с аккаунтом ChatGPT:")
                        commandBlock("""
                        npm install -g @openai/codex
                        codex login
                        """)
                        step(3, "В настройках petable переключите «Способ доступа» нужного провайдера на «Подписка (CLI)» — появится статус «CLI найден».")
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Безопасность", systemImage: "lock.shield")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Токен — это доступ к вашему счёту: не публикуйте его и не отправляйте в чаты. petable хранит токены только в Keychain этого Mac. Если ключ утёк — отзовите его на той же странице ключей и создайте новый. После проверки через curl очистите историю Терминала: history -c")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 640)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.system(size: 12.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Команда для Терминала: моноширинный блок + кнопка копирования.
    private func commandBlock(_ command: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .padding(8)
            .help("Скопировать команду")
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

// MARK: - Запуск исследования агентом

/// Шит «Исследовать агентом»: описание решения + конфигурация задачи
/// (источник, модель, effort) → вызов API → интервью + граф работ
/// с пометкой «агент».
struct AgentRunSheet: View {
    @ObservedObject var document: PetableDocument
    @Environment(\.dismiss) private var dismiss

    @AppStorage("agent.defaultProvider") private var defaultProviderRaw = AgentProvider.claude.rawValue
    @AppStorage("agent.claudeModel") private var claudeModel = AgentProvider.claude.defaultModel
    @AppStorage("agent.codexModel") private var codexModel = AgentProvider.codex.defaultModel
    @AppStorage("agent.effort") private var defaultEffortRaw = AgentEffort.high.rawValue
    @AppStorage("agent.claude.authMode") private var claudeAuthModeRaw = AgentAuthMode.apiToken.rawValue
    @AppStorage("agent.codex.authMode") private var codexAuthModeRaw = AgentAuthMode.apiToken.rawValue

    @State private var solution = ""
    @State private var provider: AgentProvider = .claude
    @State private var model = ""
    @State private var effort: AgentEffort = .high
    @State private var templateID: UUID?
    @State private var running = false
    @State private var errorMessage: String?

    /// Выбранный в настройках режим доступа провайдера.
    private func authMode(for provider: AgentProvider) -> AgentAuthMode {
        let raw = provider == .claude ? claudeAuthModeRaw : codexAuthModeRaw
        return AgentAuthMode(rawValue: raw) ?? .apiToken
    }

    /// Провайдер доступен: токен задан (режим API) либо CLI установлен
    /// (режим подписки).
    private var availableProviders: [AgentProvider] {
        AgentProvider.allCases.filter { provider in
            switch authMode(for: provider) {
            case .apiToken: return AgentTokenStore.hasToken(for: provider)
            case .subscription: return AgentCLI.isAvailable(provider)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Исследование агентом", systemImage: "sparkles")
                .font(.system(size: 16, weight: .bold))
            Text("Агент по методологии AJTBD (NMT) раскопает работы пользователей решения, заполнит интервью и построит граф работ. Артефакты будут помечены как созданные агентом.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if availableProviders.isEmpty {
                ContentUnavailableView {
                    Label("Нет доступа к агентам", systemImage: "key.slash")
                } description: {
                    Text("В настройках (⌘,) добавьте API-токен Claude/Codex или включите режим «Подписка (CLI)» при установленном Claude Code / Codex CLI.")
                }
                .frame(height: 140)
            } else {
                TextField("Решение (продукт), например: «Kayak — покупка авиабилетов семьёй»", text: $solution, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)

                Grid(alignment: .leading, verticalSpacing: 10) {
                    GridRow {
                        Text("Источник").gridColumnAlignment(.trailing)
                        Picker("", selection: $provider) {
                            ForEach(availableProviders) { provider in
                                Text("\(provider.title) · \(authMode(for: provider) == .subscription ? "подписка" : "токен")")
                                    .tag(provider)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    GridRow {
                        Text("Модель")
                        HStack {
                            TextField("", text: $model)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            Menu {
                                ForEach(provider.suggestedModels, id: \.self) { suggestion in
                                    Button(suggestion) { model = suggestion }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                    GridRow {
                        Text("Effort")
                        VStack(alignment: .leading, spacing: 4) {
                            Picker("", selection: $effort) {
                                ForEach(AgentEffort.allCases) { level in
                                    Text(level.rawValue).tag(level)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            if provider == .claude, authMode(for: .claude) == .subscription {
                                Text("В режиме подписки Claude Code сам управляет глубиной рассуждений — effort не передаётся.")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    GridRow {
                        Text("Шаблон")
                        Picker("", selection: $templateID) {
                            ForEach(document.research.templates) { template in
                                Text(template.name).tag(Optional(template.id))
                            }
                        }
                        .labelsHidden()
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                if running {
                    ProgressView().controlSize(.small)
                    Text("Агент исследует… это может занять несколько минут")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Исследовать") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        running
                            || availableProviders.isEmpty
                            || solution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || templateID == nil
                    )
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { applyDefaults() }
        .onChange(of: provider) { _, newValue in
            model = newValue == .claude ? claudeModel : codexModel
        }
    }

    private func applyDefaults() {
        let stored = AgentProvider(rawValue: defaultProviderRaw) ?? .claude
        provider = availableProviders.contains(stored) ? stored : (availableProviders.first ?? .claude)
        model = provider == .claude ? claudeModel : codexModel
        effort = AgentEffort(rawValue: defaultEffortRaw) ?? .high
        templateID = document.research.templates.first?.id
    }

    private func run() {
        guard let templateID,
              let template = document.research.templates.first(where: { $0.id == templateID })
        else { return }
        let config = AgentTaskConfig(
            provider: provider,
            authMode: authMode(for: provider),
            model: model,
            effort: effort
        )
        let solutionText = solution.trimmingCharacters(in: .whitespacesAndNewlines)
        running = true
        errorMessage = nil
        Task {
            do {
                let payload = try await AgentService.runResearch(
                    solution: solutionText,
                    template: template,
                    config: config
                )
                await MainActor.run {
                    document.addAgentResearch(payload: payload, template: template)
                    running = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    running = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
