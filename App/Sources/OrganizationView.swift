import SwiftUI
import GraphCore
import OrgEngine

/// Организация — настройки, отделённые от конвейера (правки автора №1/№4):
/// разделы «Типы задач» (маршрутизация), «Сотрудники» (master-detail),
/// «Конвейер» (редактор флоу, слайс 9) и «Интеграции» (Jira, GitHub,
/// репозитории, оркестратор).
struct OrganizationView: View {
    @ObservedObject var document: PetableDocument
    @ObservedObject var controller: OrganizationController
    @Environment(\.undoManager) private var undoManager

    enum Section: String, CaseIterable, Identifiable {
        case taskTypes = "Типы задач"
        case employees = "Сотрудники"
        case pipeline = "Конвейер"
        case integrations = "Интеграции"

        var id: String { rawValue }
    }

    @State private var section: Section = .taskTypes
    // Редактор флоу.
    @State private var selectedStageID: UUID?
    @State private var highlightedStageID: UUID?
    // Типы задач.
    @State private var newTypeName = ""
    /// Тип, у которого раскрыт конструктор флоу (правка автора №2).
    @State private var expandedTypeID: UUID?
    // Сотрудники.
    @State private var selectedEmployeeID: UUID?
    // Интеграции.
    @State private var showJiraSettings = false
    @State private var oauthClientIDDraft = JiraOAuthAppStore.clientID
    @State private var oauthSecretDraft = ""
    @State private var githubTokenDraft = ""
    @State private var newRepoPath = ""
    @State private var cloneURLDraft = ""
    @State private var newRepoNameDraft = ""
    @State private var orchestratorEnabled = OrchestratorSettings.enabled
    @State private var orchestratorAuto = OrchestratorSettings.autoStart
    @State private var orchestratorMinutes = OrchestratorSettings.intervalMinutes

    var body: some View {
        Group {
            if let organization = document.organization {
                content(organization)
            } else {
                emptyOrganization
            }
        }
        .task { await controller.connect(document: document) }
        .sheet(isPresented: $showJiraSettings) {
            JiraSettingsView {
                controller.jiraNeedsReauth = false
                controller.configureJira()
            }
        }
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
            Button("Создать организацию") {
                document.createOrganizationIfNeeded()
            }
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ organization: Organization) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Раздел", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 480)
            .padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch section {
                    case .taskTypes: taskTypesSection(organization)
                    case .employees: employeesSection(organization)
                    case .pipeline: pipelineSection(organization)
                    case .integrations: integrationsSection(organization)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: Типы задач → флоу (компактная таблица, не топология — D3)

    private func taskTypesSection(_ organization: Organization) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Тип задачи выбирает флоу; «Тип в Jira» — маппинг импорта (П4″). «Флоу» — выстроить последовательность работ типа прямо здесь.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            ForEach(organization.taskTypes) { type in
                let routedFlowID = organization.routes.first(where: { $0.taskTypeID == type.id })?.flowID
                TaskTypeRow(
                    type: type,
                    flows: organization.flows,
                    routedFlowID: routedFlowID,
                    isExpanded: expandedTypeID == type.id,
                    onChange: { updated in
                        document.updateOrganization { org in
                            if let index = org.taskTypes.firstIndex(where: { $0.id == updated.id }) {
                                org.taskTypes[index] = updated
                            }
                        }
                    },
                    onRoute: { flowID in
                        document.updateOrganization { org in
                            org.routes.removeAll { $0.taskTypeID == type.id }
                            if let flowID {
                                org.routes.append(OrgRoute(taskTypeID: type.id, flowID: flowID))
                            }
                        }
                    },
                    onToggleFlow: {
                        expandedTypeID = expandedTypeID == type.id ? nil : type.id
                        selectedStageID = nil
                    },
                    onDelete: {
                        document.updateOrganization { org in
                            org.taskTypes.removeAll { $0.id == type.id }
                            org.routes.removeAll { $0.taskTypeID == type.id }
                        }
                    }
                )
                // Конструктор флоу типа (правка №2): «нажимаю и выстраиваю
                // последовательность работ» — редактор прямо под типом.
                if expandedTypeID == type.id {
                    Group {
                        if let flowID = routedFlowID,
                           let flow = organization.flows.first(where: { $0.id == flowID }) {
                            editorFlowSection(flow, organization: organization)
                        } else {
                            Button("Создать флоу для «\(type.name)»") {
                                createFlow(for: type)
                            }
                            .font(.system(size: 11))
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.vertical, 4)
                }
            }
            HStack {
                TextField("Новый тип задачи… (⏎)", text: $newTypeName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)
                    .onSubmit(addTaskType)
                Button("Добавить", action: addTaskType)
                    .disabled(newTypeName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addTaskType() {
        let name = newTypeName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        document.updateOrganization { org in
            let type = OrgTaskType(name: name)
            org.taskTypes.append(type)
            if let flow = org.flows.first {
                org.routes.append(OrgRoute(taskTypeID: type.id, flowID: flow.id))
            }
        }
        newTypeName = ""
    }

    /// Новый флоу типа: старт — один Merge-гейт, этапы достраиваются
    /// «+»-палитрой (например: discovery → арх-discovery → разработка →
    /// ревью → тесты → merge).
    private func createFlow(for type: OrgTaskType) {
        document.updateOrganization { org in
            let merge = OrgStage(name: "Merge", kind: .merge, gate: .human)
            let flow = OrgFlow(name: type.name, stages: [merge])
            org.flows.append(flow)
            org.routes.removeAll { $0.taskTypeID == type.id }
            org.routes.append(OrgRoute(taskTypeID: type.id, flowID: flow.id))
        }
    }

    // MARK: Сотрудники (правка №6, слайс 10 v1): master-detail

    private func employeesSection(_ organization: Organization) -> some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(organization.employees) { employee in
                    Button {
                        selectedEmployeeID = employee.id
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(employee.name)
                                    .font(.system(size: 12))
                                if let presetID = employee.presetID,
                                   let preset = OrganizationPresets.preset(presetID) {
                                    Text("из пресета «\(preset.name)»")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Spacer()
                        }
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedEmployeeID == employee.id
                                      ? Color.accentColor.opacity(0.12)
                                      : Color.clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Menu {
                    ForEach(OrganizationPresets.all, id: \.id) { preset in
                        Button(preset.name) { addEmployee(preset: preset) }
                    }
                    Divider()
                    Button("С нуля") { addEmployee(preset: nil) }
                } label: {
                    Label("Добавить сотрудника", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.top, 6)
            }
            .frame(width: 230, alignment: .leading)
            if let id = selectedEmployeeID,
               let employee = organization.employees.first(where: { $0.id == id }) {
                EmployeeEditor(
                    employee: employee,
                    onChange: { updated in
                        document.updateOrganization { org in
                            if let index = org.employees.firstIndex(where: { $0.id == updated.id }) {
                                org.employees[index] = updated
                            }
                        }
                    },
                    onDelete: {
                        document.updateOrganization { org in
                            org.employees.removeAll { $0.id == employee.id }
                        }
                        selectedEmployeeID = nil
                    }
                )
                .id(employee.id)
            } else {
                Text("Выбери сотрудника слева — настройки: роль, исполнитель, права.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
        }
    }

    private func addEmployee(preset: EmployeePreset?) {
        let employee = preset?.makeEmployee() ?? Employee(name: "Новый сотрудник")
        document.updateOrganization { $0.employees.append(employee) }
        selectedEmployeeID = employee.id
    }

    // MARK: Конвейер — редактор флоу (слайс 9, 12A)

    @ViewBuilder
    private func pipelineSection(_ organization: Organization) -> some View {
        ForEach(organization.flows) { flow in
            editorFlowSection(flow, organization: organization)
        }
    }

    private func editorFlowSection(_ flow: OrgFlow, organization: Organization) -> some View {
        let stages = OrgUI.orderedStages(flow)
        let issues = flow.validate()
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(flow.name.uppercased())
                    .font(.system(size: 10, weight: .medium))
                    .kerning(1.2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !issues.isEmpty {
                    Label("\(issues.count) \(issues.count == 1 ? "ошибка" : "ошибки") флоу",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            HStack(spacing: 4) {
                insertButton(flow: flow, after: nil)
                ForEach(stages) { stage in
                    StageNodeView(
                        stage: stage,
                        subtitle: OrgUI.stageSubtitle(stage, employees: organization.employees),
                        emphasis: highlightedStageID == stage.id
                            ? .flashed
                            : selectedStageID == stage.id ? .selected : .idle
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedStageID = selectedStageID == stage.id ? nil : stage.id
                        highlightedStageID = nil
                    }
                    insertButton(flow: flow, after: stage.id)
                }
                Spacer(minLength: 0)
            }
            // Issues-навигатор: клик подсвечивает узел (12A).
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                Button {
                    highlightedStageID = issue.stageID
                    selectedStageID = issue.stageID
                } label: {
                    Text(flow.describe(issue))
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
            if let selected = selectedStageID, let stage = flow.stage(selected) {
                StageInspector(
                    stage: stage,
                    employees: organization.employees,
                    onChange: { updated in
                        updateFlow(flow.id) { editable in
                            if let index = editable.stages.firstIndex(where: { $0.id == updated.id }) {
                                editable.stages[index] = updated
                            }
                        }
                    },
                    onDelete: {
                        updateFlow(flow.id) { $0.removeStage(stage.id) }
                        selectedStageID = nil
                    }
                )
            }
        }
    }

    /// «+» между узлами: меню видов этапа — палитра редактора (12A).
    private func insertButton(flow: OrgFlow, after stageID: UUID?) -> some View {
        Menu {
            ForEach(StageKind.allCases, id: \.self) { kind in
                Button(OrgUI.kindLabel(kind)) {
                    insertStage(kind, flow: flow, after: stageID)
                }
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Вставить этап")
    }

    private func insertStage(_ kind: StageKind, flow: OrgFlow, after stageID: UUID?) {
        let needsEmployee = kind == .work || kind == .review || kind == .decompose
        let stage = OrgStage(
            name: OrgUI.kindLabel(kind),
            kind: kind,
            gate: kind == .merge ? .human : .auto,
            employeeID: needsEmployee ? document.organization?.employees.first?.id : nil
        )
        updateFlow(flow.id) { $0.insertStage(stage, after: stageID) }
        selectedStageID = stage.id
    }

    private func updateFlow(_ flowID: UUID, _ mutate: @escaping (inout OrgFlow) -> Void) {
        document.updateOrganization { org in
            guard let index = org.flows.firstIndex(where: { $0.id == flowID }) else { return }
            mutate(&org.flows[index])
        }
    }

    // MARK: Интеграции (правка №5): Jira, GitHub, репозитории, оркестратор

    @ViewBuilder
    private func integrationsSection(_ organization: Organization) -> some View {
        jiraCard
        githubCard
        reposCard(organization)
        orchestratorCard
        if let status = controller.integrationStatus {
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var jiraCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("JIRA")
            if let site = JiraSettingsStore.connectedSiteDisplay {
                HStack(spacing: 8) {
                    Label("Подключена · \(site)", systemImage: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                    if JiraOAuthTokenStore.load() != nil {
                        Button("Отключить") { controller.disconnectJiraOAuth() }
                            .font(.system(size: 11))
                    } else {
                        Button("Настроить") { showJiraSettings = true }
                            .font(.system(size: 11))
                    }
                }
            } else {
                HStack(spacing: 8) {
                    // Коннектор: браузер → «Согласен» → готово; сайт
                    // подтянется сам (правка автора).
                    Button("Подключить Jira") {
                        Task { await controller.connectJiraOAuth() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!JiraOAuthAppStore.isConfigured || controller.jiraConnecting)
                    if controller.jiraConnecting {
                        ProgressView().controlSize(.small)
                        Text("жду подтверждения в браузере…")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Button("Вручную (API-токен)…") { showJiraSettings = true }
                        .font(.system(size: 11))
                }
                if !JiraOAuthAppStore.isConfigured {
                    jiraConnectorSetup
                }
            }
            if let status = controller.jiraStatus {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(controller.jiraNeedsReauth ? Color.orange : Color.secondary)
            }
        }
    }

    /// Однократная настройка коннектора: Atlassian требует своё OAuth-
    /// приложение (client_id + secret) — дальше только кнопка.
    private var jiraConnectorSetup: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Однократная настройка коннектора: developer.atlassian.com → Create → OAuth 2.1 integration → разрешения Jira API (read/write) → Callback URL:")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(JiraOAuthFlow.redirectURI)
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("Client ID", text: $oauthClientIDDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                SecureField("Secret", text: $oauthSecretDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button("Сохранить") {
                    JiraOAuthAppStore.clientID = oauthClientIDDraft
                        .trimmingCharacters(in: .whitespaces)
                    JiraOAuthAppStore.clientSecret = oauthSecretDraft
                        .trimmingCharacters(in: .whitespaces)
                    oauthSecretDraft = ""
                }
                .disabled(oauthClientIDDraft.trimmingCharacters(in: .whitespaces).isEmpty
                          || oauthSecretDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.top, 2)
    }

    private var githubCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("GITHUB")
            if controller.githubLogin.isEmpty {
                HStack(spacing: 8) {
                    SecureField("Personal access token (repo)", text: $githubTokenDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    Button("Подключить GitHub") {
                        let token = githubTokenDraft
                        githubTokenDraft = ""
                        Task { await controller.connectGitHub(token: token) }
                    }
                    .disabled(githubTokenDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Токен: github.com → Settings → Developer settings → Tokens. Хранится в Keychain.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                HStack(spacing: 8) {
                    Label("Подключён как \(controller.githubLogin)", systemImage: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                    Button("Отключить") { controller.disconnectGitHub() }
                        .font(.system(size: 11))
                }
            }
        }
    }

    private func reposCard(_ organization: Organization) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("РЕПОЗИТОРИИ")
            if organization.repos.isEmpty {
                Text("Реестр пуст — добавь локальный клон, склонируй по URL или создай в GitHub.")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
            }
            ForEach(organization.repos) { repo in
                RepoRow(repo: repo) { updated in
                    document.updateOrganization { org in
                        if let index = org.repos.firstIndex(where: { $0.id == repo.id }) {
                            org.repos[index] = updated
                        }
                    }
                } onDelete: {
                    document.updateOrganization { org in
                        org.repos.removeAll { $0.id == repo.id }
                    }
                }
            }
            HStack {
                TextField("Путь к локальному клону… (⏎)", text: $newRepoPath)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                    .onSubmit(addRepo)
                Button("Добавить", action: addRepo)
                    .disabled(newRepoPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                TextField("URL для клона (https или git@)…", text: $cloneURLDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                Button("Клонировать") {
                    let url = cloneURLDraft
                    cloneURLDraft = ""
                    Task { await controller.cloneRepository(url: url) }
                }
                .disabled(cloneURLDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            HStack {
                TextField("Имя нового репозитория в GitHub…", text: $newRepoNameDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                Button("Создать в GitHub") {
                    let name = newRepoNameDraft
                    newRepoNameDraft = ""
                    Task { await controller.createRepository(name: name) }
                }
                .disabled(
                    newRepoNameDraft.trimmingCharacters(in: .whitespaces).isEmpty
                        || controller.githubLogin.isEmpty
                )
                .help(controller.githubLogin.isEmpty ? "Сначала подключи GitHub" : "")
            }
        }
        .font(.system(size: 12))
    }

    /// Оркестратор (правки №8/№9): следит за Jira, момент взятия в
    /// работу конфигурируем — спрашивать или брать автоматически.
    private var orchestratorCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("ОРКЕСТРАТОР")
            Toggle("Проверять Jira на новые задачи и напоминать о зависших", isOn: $orchestratorEnabled)
                .font(.system(size: 12))
                .onChange(of: orchestratorEnabled) { _, value in
                    OrchestratorSettings.enabled = value
                    controller.restartOrchestrator()
                }
            if orchestratorEnabled {
                HStack(spacing: 12) {
                    Picker("Интервал", selection: $orchestratorMinutes) {
                        Text("каждую минуту").tag(1)
                        Text("каждые 5 минут").tag(5)
                        Text("каждые 15 минут").tag(15)
                        Text("каждый час").tag(60)
                    }
                    .fixedSize()
                    .onChange(of: orchestratorMinutes) { _, value in
                        OrchestratorSettings.intervalMinutes = value
                        controller.restartOrchestrator()
                    }
                    Picker("Новая задача", selection: $orchestratorAuto) {
                        Text("спрашивать").tag(false)
                        Text("брать в работу автоматически").tag(true)
                    }
                    .fixedSize()
                    .onChange(of: orchestratorAuto) { _, value in
                        OrchestratorSettings.autoStart = value
                    }
                }
                .font(.system(size: 12))
            }
        }
    }

    private func addRepo() {
        let path = (newRepoPath.trimmingCharacters(in: .whitespaces) as NSString)
            .expandingTildeInPath
        guard !path.isEmpty else { return }
        document.updateOrganization { org in
            org.repos.append(RepoRef(
                name: URL(fileURLWithPath: path).lastPathComponent, path: path
            ))
        }
        newRepoPath = ""
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .kerning(1.2)
            .foregroundStyle(.tertiary)
    }
}

/// Редактор сотрудника (слайс 10 v1): роль, исполнитель, права.
/// Текст — по ⏎, пикеры — сразу.
private struct EmployeeEditor: View {
    let employee: Employee
    let onChange: (Employee) -> Void
    let onDelete: () -> Void

    @State private var name: String
    @State private var rolePrompt: String
    @State private var model: String

    init(employee: Employee, onChange: @escaping (Employee) -> Void, onDelete: @escaping () -> Void) {
        self.employee = employee
        self.onChange = onChange
        self.onDelete = onDelete
        _name = State(initialValue: employee.name)
        _rolePrompt = State(initialValue: employee.rolePrompt)
        _model = State(initialValue: employee.adapter.model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                TextField("Имя", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(commitTexts)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Label("Удалить", systemImage: "trash")
                        .font(.system(size: 11))
                }
            }
            HStack(spacing: 12) {
                Picker("Исполнитель", selection: Binding(
                    get: { employee.adapter.cli },
                    set: { cli in
                        var updated = employee
                        updated.adapter.cli = cli
                        onChange(updated)
                    }
                )) {
                    Text("claude").tag("claude")
                    Text("codex").tag("codex")
                }
                .fixedSize()
                Picker("Права", selection: Binding(
                    get: { employee.adapter.permissionProfile },
                    set: { profile in
                        var updated = employee
                        updated.adapter.permissionProfile = profile
                        onChange(updated)
                    }
                )) {
                    Text("только чтение").tag("readOnly")
                    Text("запись").tag("write")
                }
                .fixedSize()
                TextField("Модель (пусто — дефолт CLI)", text: $model)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(commitTexts)
            }
            Text("РОЛЕВОЙ ПРОМПТ")
                .font(.system(size: 9, weight: .medium))
                .kerning(1)
                .foregroundStyle(.tertiary)
            TextEditor(text: $rolePrompt)
                .font(.system(size: 12))
                .frame(minHeight: 120, maxHeight: 200)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
            HStack {
                if let presetID = employee.presetID,
                   let preset = OrganizationPresets.preset(presetID) {
                    Text("Создан из пресета «\(preset.name)»")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Button("Сбросить к пресету") {
                        var reset = preset.makeEmployee()
                        reset.id = employee.id
                        onChange(reset)
                        name = reset.name
                        rolePrompt = reset.rolePrompt
                        model = reset.adapter.model
                    }
                    .font(.system(size: 10))
                }
                Spacer()
                Button("Сохранить текст") { commitTexts() }
                    .font(.system(size: 11))
                    .disabled(name == employee.name
                              && rolePrompt == employee.rolePrompt
                              && model == employee.adapter.model)
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: 560, alignment: .leading)
    }

    private func commitTexts() {
        var updated = employee
        updated.name = name.trimmingCharacters(in: .whitespaces)
        updated.rolePrompt = rolePrompt
        updated.adapter.model = model.trimmingCharacters(in: .whitespaces)
        guard updated != employee, !updated.name.isEmpty else { return }
        onChange(updated)
    }
}

/// Инспектор этапа редактора (12A): имя, вид, гейт, сотрудник, промпт.
/// Текстовые правки коммитятся по ⏎, пикеры — сразу.
private struct StageInspector: View {
    let stage: OrgStage
    let employees: [Employee]
    let onChange: (OrgStage) -> Void
    let onDelete: () -> Void

    @State private var name: String
    @State private var promptTemplate: String

    init(
        stage: OrgStage, employees: [Employee],
        onChange: @escaping (OrgStage) -> Void, onDelete: @escaping () -> Void
    ) {
        self.stage = stage
        self.employees = employees
        self.onChange = onChange
        self.onDelete = onDelete
        _name = State(initialValue: stage.name)
        _promptTemplate = State(initialValue: stage.promptTemplate)
    }

    private var isLLM: Bool {
        stage.kind == .work || stage.kind == .review || stage.kind == .decompose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                TextField("Название этапа", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onSubmit(commitTexts)
                Picker("Вид", selection: Binding(
                    get: { stage.kind },
                    set: { kind in
                        var updated = stage
                        updated.kind = kind
                        if kind == .merge { updated.gate = .human }
                        onChange(updated)
                    }
                )) {
                    ForEach(StageKind.allCases, id: \.self) { kind in
                        Text(OrgUI.kindLabel(kind)).tag(kind)
                    }
                }
                .fixedSize()
                Picker("Гейт", selection: Binding(
                    get: { stage.gate },
                    set: { gate in
                        var updated = stage
                        updated.gate = gate
                        onChange(updated)
                    }
                )) {
                    Text("авто").tag(StageGate.auto)
                    Text("человек").tag(StageGate.human)
                }
                .fixedSize()
                if isLLM {
                    Picker("Сотрудник", selection: Binding(
                        get: { stage.employeeID },
                        set: { id in
                            var updated = stage
                            updated.employeeID = id
                            onChange(updated)
                        }
                    )) {
                        Text("—").tag(UUID?.none)
                        ForEach(employees) { employee in
                            Text(employee.name).tag(UUID?.some(employee.id))
                        }
                    }
                    .fixedSize()
                }
                Spacer()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Удалить этап", systemImage: "trash")
                        .font(.system(size: 11))
                }
            }
            if isLLM {
                TextField("Промпт этапа поверх ролевого… (⏎)", text: $promptTemplate)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit(commitTexts)
            }
        }
        .font(.system(size: 11))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
    }

    private func commitTexts() {
        var updated = stage
        updated.name = name.trimmingCharacters(in: .whitespaces)
        updated.promptTemplate = promptTemplate
        guard updated != stage, !updated.name.isEmpty else { return }
        onChange(updated)
    }
}

/// Строка таблицы «тип задачи → флоу» (связка тип → флоу → сотрудник — D3).
private struct TaskTypeRow: View {
    let type: OrgTaskType
    let flows: [OrgFlow]
    let routedFlowID: UUID?
    let isExpanded: Bool
    let onChange: (OrgTaskType) -> Void
    let onRoute: (UUID?) -> Void
    let onToggleFlow: () -> Void
    let onDelete: () -> Void

    @State private var name: String
    @State private var jiraType: String

    init(
        type: OrgTaskType, flows: [OrgFlow], routedFlowID: UUID?, isExpanded: Bool,
        onChange: @escaping (OrgTaskType) -> Void,
        onRoute: @escaping (UUID?) -> Void,
        onToggleFlow: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.type = type
        self.flows = flows
        self.routedFlowID = routedFlowID
        self.isExpanded = isExpanded
        self.onChange = onChange
        self.onRoute = onRoute
        self.onToggleFlow = onToggleFlow
        self.onDelete = onDelete
        _name = State(initialValue: type.name)
        _jiraType = State(initialValue: type.jiraType)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Тип", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .onSubmit(commit)
            TextField("Тип в Jira", text: $jiraType)
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
                .onSubmit(commit)
                .help("Значение поля «тип задачи» Jira, которое маппится сюда (⏎)")
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .light))
                .foregroundStyle(Color.secondary.opacity(0.5))
            Picker("Флоу", selection: Binding(get: { routedFlowID }, set: onRoute)) {
                Text("— без маршрута —").tag(UUID?.none)
                ForEach(flows) { flow in
                    Text(flow.name).tag(UUID?.some(flow.id))
                }
            }
            .labelsHidden()
            .fixedSize()
            // Конструктор последовательности работ типа (правка №2).
            Button(action: onToggleFlow) {
                Label("Флоу", systemImage: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isExpanded ? Color.accentColor : Color.secondary)
            .help("Выстроить последовательность работ этого типа")
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11))
    }

    private func commit() {
        var updated = type
        updated.name = name.trimmingCharacters(in: .whitespaces)
        updated.jiraType = jiraType.trimmingCharacters(in: .whitespaces)
        guard updated != type, !updated.name.isEmpty else { return }
        onChange(updated)
    }
}

/// Строка реестра репозиториев: правки Jira-проекта и тест-команды
/// коммитятся в документ по ⏎ (undoable до старта запусков).
private struct RepoRow: View {
    let repo: RepoRef
    let onChange: (RepoRef) -> Void
    let onDelete: () -> Void

    @State private var jiraProject: String
    @State private var testCommand: String

    init(repo: RepoRef, onChange: @escaping (RepoRef) -> Void, onDelete: @escaping () -> Void) {
        self.repo = repo
        self.onChange = onChange
        self.onDelete = onDelete
        _jiraProject = State(initialValue: repo.jiraProject)
        _testCommand = State(initialValue: repo.testCommand)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(.system(size: 12))
                Text(repo.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            TextField("Jira-проект", text: $jiraProject)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: 110)
                .onSubmit(commit)
                .help("Ключ проекта Jira (DN) — его задачи поедут в этот репозиторий (⏎)")
            TextField("Тест-команда", text: $testCommand)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: 150)
                .onSubmit(commit)
                .help("Команда тестов репозитория, успех = exit 0 (⏎)")
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Убрать из реестра (клон на диске остаётся)")
        }
        .padding(.vertical, 2)
    }

    private func commit() {
        var updated = repo
        updated.jiraProject = jiraProject.trimmingCharacters(in: .whitespaces)
        updated.testCommand = testCommand.trimmingCharacters(in: .whitespaces)
        guard updated != repo else { return }
        onChange(updated)
    }
}

/// Настройки Jira: адрес и e-mail — UserDefaults, токен — Keychain.
private struct JiraSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = JiraSettingsStore.baseURL
    @State private var email = JiraSettingsStore.email
    @State private var token = ""
    private let hasToken = JiraSettingsStore.token != nil

    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jira")
                .font(.headline)
            Text("API-токен: id.atlassian.com → Security → Create API token.\nТокен хранится в Keychain; движку передаётся только в память.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("https://команда.atlassian.net", text: $baseURL)
                .textFieldStyle(.roundedBorder)
            TextField("E-mail аккаунта Atlassian", text: $email)
                .textFieldStyle(.roundedBorder)
            SecureField(
                hasToken ? "Токен сохранён — ввести новый…" : "API-токен",
                text: $token
            )
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    var url = baseURL.trimmingCharacters(in: .whitespaces)
                    if url.hasSuffix("/") { url = String(url.dropLast()) }
                    JiraSettingsStore.baseURL = url
                    JiraSettingsStore.email = email.trimmingCharacters(in: .whitespaces)
                    let newToken = token.trimmingCharacters(in: .whitespaces)
                    if !newToken.isEmpty {
                        JiraSettingsStore.setToken(newToken)
                    }
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 400)
    }
}
