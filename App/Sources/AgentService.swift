import Foundation
import Security
import GraphCore

// MARK: - Провайдеры и конфигурация

/// Источник ИИ-агента: Claude (Anthropic API) или Codex (OpenAI API).
enum AgentProvider: String, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var defaultModel: String {
        switch self {
        case .claude: return "claude-opus-4-8"
        case .codex: return "gpt-5.1-codex"
        }
    }

    var suggestedModels: [String] {
        switch self {
        case .claude:
            return ["claude-opus-4-8", "claude-sonnet-5", "claude-haiku-4-5", "claude-fable-5"]
        case .codex:
            return ["gpt-5.1-codex", "gpt-5.1-codex-max", "gpt-5.1"]
        }
    }
}

/// Уровень усилий (глубина рассуждений) агента.
enum AgentEffort: String, CaseIterable, Identifiable {
    case low, medium, high, xhigh, max

    var id: String { rawValue }

    /// Claude: effort в output_config как есть.
    var anthropicValue: String { rawValue }

    /// OpenAI reasoning.effort не знает xhigh/max — сводим к high.
    var openAIValue: String {
        switch self {
        case .low: return "low"
        case .medium: return "medium"
        case .high, .xhigh, .max: return "high"
        }
    }
}

/// Способ доступа к провайдеру: API-токен (оплата за токены)
/// или подписка через локальный CLI (Claude Code / Codex CLI).
enum AgentAuthMode: String, CaseIterable, Identifiable {
    case apiToken
    case subscription

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apiToken: return "API-токен"
        case .subscription: return "Подписка (CLI)"
        }
    }
}

/// Настройки задачи для агента: источник, способ доступа, модель, effort.
struct AgentTaskConfig {
    var provider: AgentProvider
    var authMode: AgentAuthMode
    var model: String
    var effort: AgentEffort
}

extension AgentProvider {
    /// Имя локального CLI для режима подписки.
    var cliName: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }

    var cliTitle: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        }
    }

    /// Какая подписка нужна для CLI.
    var subscriptionHint: String {
        switch self {
        case .claude: return "подписка Claude Pro/Max, вход через «claude /login»"
        case .codex: return "подписка ChatGPT Plus/Pro, вход через «codex login»"
        }
    }
}

// MARK: - Keychain для токенов

/// Токены API живут в Keychain, не в UserDefaults и не в документе.
enum AgentTokenStore {
    private static let service = "com.egorproskurin.petable.agent-tokens"

    static func token(for provider: AgentProvider) -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty
        else { return nil }
        return token
    }

    static func setToken(_ token: String, for provider: AgentProvider) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteToken(for: provider)
            return
        }
        let data = Data(trimmed.utf8)
        var query = baseQuery(provider)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            SecItemAdd(query as CFDictionary, nil)
        }
    }

    static func deleteToken(for provider: AgentProvider) {
        SecItemDelete(baseQuery(provider) as CFDictionary)
    }

    static func hasToken(for provider: AgentProvider) -> Bool {
        token(for: provider) != nil
    }

    private static func baseQuery(_ provider: AgentProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}

// MARK: - NMT-промпт

/// Промпт агента: выжимка методологии AJTBD / Next Move Theory
/// (Иван Замесин) + формат JSON-ответа с id полей шаблона интервью.
enum AgentPrompt {
    static let nmtSkill = """
    Ты — продуктовый исследователь, работающий строго по методологии \
    Advanced Jobs To Be Done (AJTBD) / Next Move Theory Ивана Замесина. \
    Она существенно отличается от «обычного» JTBD (Кристенсен/Ульвик) — \
    не подменяй определения.

    Ключевые тезисы методологии:
    - Работа (Job) — спецификация желаемого перехода: ситуация человека \
    (состояние А), переход и ожидаемый результат (состояние Б), выполняемая \
    «чтобы» выполнить вышестоящую работу. Работа — не потребность, не \
    проблема и не фича; это единица мотивации.
    - Формула работы: «хочу + глагол (+ объект)». Каждый инфинитивный \
    глагол — отдельная работа; многоглагольные формулировки разбираются \
    в иерархию.
    - У работы восемь элементов: контекст, негативные эмоции, consideration \
    set, триггер, ожидаемый результат, критерии успеха, позитивные эмоции, \
    вышестоящая работа.
    - Критерии успеха конкретны: не «быстро», а «за 4 минуты»; у критерия \
    есть направление (ось) и уровень (порог). Без критериев работа \
    непригодна для дизайна.
    - Уровни работ относительны продукта: Большие (мотивация, продукт их \
    не выполняет целиком), Кóровые (продукт выполняет целиком), Малые \
    (соседи кóровых), Микро (шаги внутри). В графе уровень 0 — самый \
    верхний (большие работы), ниже — декомпозиция.
    - Проблема — следствие: решение, нанятое на работу, выполнило её ниже \
    критериев успеха. Реальные конкуренты живут на уровне большой работы.
    - Изучай работы по прошлым тратам денег/времени/энергии, не по \
    намерениям; будущее без прошлой траты — фейковая работа.
    - Критическая цепочка работ: шаги, выполняемые по порядку, \
    декомпозируются из ОДНОЙ вышестоящей работы, лежат на одном уровне \
    подряд и связаны рёбрами последовательности «шаг → следующий шаг» \
    слева направо. Ребро декомпозиции от родителя ведёт к первому шагу \
    цепочки, дальше порядок читается по горизонтальным рёбрам. Веер \
    рёбер от родителя к каждому шагу без связей между шагами — ошибка: \
    теряется порядок выполнения. Отдельные рёбра декомпозиции от \
    родителя получают только независимые (параллельные) под-работы.
    """

    /// System-промпт чат-агента: методология + текущее состояние проекта
    /// + формат команд создания/правки артефактов.
    static func chatSystem(projectContext: String) -> String {
        """
        \(nmtSkill)

        Ты работаешь в приложении petable как чат-консультант по методологии \
        AJTBD / Next Move Theory. Отвечай на вопросы пользователя по \
        методологии и по его проекту: коротко, конкретно, без воды, на русском.

        Текущее состояние проекта (используй эти ID в командах):
        \(projectContext)

        Ты можешь создавать и править артефакты проекта. Для этого включи \
        в ответ один или несколько блоков строго такого вида:

        ```petable-action
        { …JSON одной команды… }
        ```

        Команды:
        1) Создать граф работ:
        {"action": "create_graph", "graph": {"name": "…", "levels": [[{"verb": "глагол с объектом", "role": null}]], "edges": [{"fromLevel": 0, "fromIndex": 0, "toLevel": 1, "toIndex": 0}], "coreLevel": 1}}
        Уровень 0 — большие работы (мотивация), ниже — декомпозиция. \
        coreLevel — индекс уровня кóровых работ (продукт выполняет их \
        целиком); он есть в каждом графе. \
        Узел — «хочу + глагол» (пиши сам глагол с объектом, без «хочу»). \
        Рёбра двух видов: декомпозиция (fromLevel + 1 == toLevel) и \
        последовательность (fromLevel == toLevel, соседние индексы). \
        Шаги, выполняемые по порядку (критическая цепочка), клади на один \
        уровень подряд и связывай цепочкой: родитель → первый шаг \
        (декомпозиция), затем каждый шаг → следующий (последовательность \
        внутри уровня). Не рисуй веер рёбер от родителя к каждому шагу — \
        так теряется порядок. Отдельное ребро декомпозиции от родителя — \
        только для независимых (параллельных) под-работ.

        2) Изменить существующий граф (структура заменяется ЦЕЛИКОМ — \
        перечисли все узлы и рёбра, включая те, что остаются без изменений; \
        пустое name — оставить прежнее имя):
        {"action": "update_graph", "graphID": "UUID из контекста", "graph": {…как в create_graph…}}

        3) Создать интервью по шаблону проекта (answers — по fieldID шаблона):
        {"action": "create_interview", "templateID": "UUID из контекста", "interviewName": "…", "placeholders": {"решение": "…"}, "answers": [{"fieldID": "UUID", "answer": "…"}]}

        4) Править интервью (перечисленные ответы/плейсхолдеры \
        перезаписываются, остальные не трогаются):
        {"action": "update_interview", "interviewID": "UUID из контекста", "placeholders": {}, "answers": [{"fieldID": "UUID", "answer": "…"}]}

        Правила: команды выполняются сразу и без подтверждения — вноси только \
        то, о чём попросил пользователь. Если запрос неоднозначен, сначала \
        уточни, без команды. Если пользователь просто задаёт вопрос — отвечай \
        текстом без команд. UUID бери только из контекста выше, не выдумывай.
        """
    }

    /// Формирует полный промпт: задача, шаблон интервью с id полей,
    /// требуемый JSON.
    static func researchPrompt(solution: String, template: InterviewTemplate) -> String {
        var fieldLines: [String] = []
        for section in template.sections {
            fieldLines.append("Секция «\(section.title)»:")
            for field in section.fields {
                var line = "- fieldID \(field.id.uuidString): «\(field.title)» — \(field.question)"
                if let hint = field.hint { line += " (подсказка: \(hint))" }
                fieldLines.append(line)
            }
        }
        return """
        Задача: исследуй решение (продукт) «\(solution)» по методологии AJTBD.

        1) Восстанови правдоподобное глубинное интервью с типичным платящим \
        пользователем этого решения: раскопай все работы (jobs) — ожидаемые \
        результаты, вышестоящую (большую) работу, предыдущие/следующие/\
        параллельные работы, все 8 элементов ключевой работы, вес работы, \
        оценку выбранного решения. Ответы пиши как слова респондента, \
        конкретно, без абстракций. Это гипотеза для последующей проверки \
        реальными интервью — но делай её максимально правдоподобной.

        2) На основе раскопанных работ построй граф работ: уровень 0 — \
        большая работа (мотивация), ниже — кóровые/малые работы, ещё ниже — \
        декомпозиция. В поле coreLevel укажи индекс уровня кóровых работ \
        (продукт выполняет их целиком) — он есть в каждом графе. \
        Каждый узел — «хочу + глагол» (сам глагол с объектом, \
        без слова «хочу»). Рёбра двух видов: декомпозиция (на уровень вниз) \
        и последовательность (внутри уровня: fromLevel == toLevel). Шаги, \
        выполняемые по порядку, клади на один уровень подряд и связывай \
        цепочкой: родитель → первый шаг (декомпозиция), затем каждый шаг → \
        следующий (последовательность). Не рисуй веер рёбер от родителя \
        к каждому шагу. Отдельное ребро декомпозиции от родителя — только \
        для независимых (параллельных) под-работ.

        Поля шаблона интервью (отвечай по их fieldID):
        \(fieldLines.joined(separator: "\n"))

        Ответь СТРОГО одним JSON-объектом без пояснений и без markdown-фенсов:
        {
          "interviewName": "строка — название интервью",
          "placeholders": {"решение": "...", "ожидаемый результат": "...", "результат вышестоящей работы": "..."},
          "answers": [{"fieldID": "UUID из списка выше", "answer": "текст ответа"}],
          "graph": {
            "name": "строка — название графа",
            "levels": [[{"verb": "глагол с объектом", "role": null}]],
            "edges": [{"fromLevel": 0, "fromIndex": 0, "toLevel": 1, "toIndex": 0}],
            "coreLevel": 1
          }
        }
        """
    }
}

// MARK: - Вызовы API

enum AgentServiceError: Error, LocalizedError {
    case missingToken(AgentProvider)
    case missingCLI(AgentProvider)
    case cliFailed(AgentProvider, exitCode: Int32, stderr: String)
    case httpError(status: Int, body: String)
    case emptyResponse
    case refusal

    var errorDescription: String? {
        switch self {
        case .missingToken(let provider):
            return "Не задан токен для \(provider.title) — добавьте его в настройках (⌘,)."
        case .missingCLI(let provider):
            return "Не найден \(provider.cliTitle) («\(provider.cliName)» нет в PATH). Установите CLI и войдите: \(provider.subscriptionHint)."
        case .cliFailed(let provider, let code, let stderr):
            return "\(provider.cliTitle) завершился с кодом \(code): \(String(stderr.suffix(400)))"
        case .httpError(let status, let body):
            return "Ошибка API (HTTP \(status)): \(String(body.prefix(300)))"
        case .emptyResponse:
            return "Модель вернула пустой ответ."
        case .refusal:
            return "Модель отклонила запрос (refusal)."
        }
    }
}

// MARK: - Локальные CLI (режим подписки)

/// Поиск и запуск локальных CLI. GUI-приложение не видит PATH шелла,
/// поэтому бинарь ищется через логин-zsh один раз и кэшируется.
enum AgentCLI {
    private static var cache: [AgentProvider: URL?] = [:]

    /// Путь к CLI провайдера; nil — не установлен.
    static func locate(_ provider: AgentProvider) -> URL? {
        if let cached = cache[provider] { return cached }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(provider.cliName)"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        var url: URL?
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let path = String(
                    data: out.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !path.isEmpty { url = URL(fileURLWithPath: path) }
            }
        } catch {
            url = nil
        }
        cache[provider] = url
        return url
    }

    static func isAvailable(_ provider: AgentProvider) -> Bool {
        locate(provider) != nil
    }

    /// Запуск CLI: промпт через stdin, ответ из stdout.
    /// Чтение пайпов — до waitUntilExit, иначе дедлок на больших ответах.
    static func run(
        _ provider: AgentProvider,
        arguments: [String],
        stdin: String
    ) async throws -> String {
        guard let executable = locate(provider) else {
            throw AgentServiceError.missingCLI(provider)
        }
        return try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.currentDirectoryURL = FileManager.default.temporaryDirectory

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()
            stdinPipe.fileHandleForWriting.write(Data(stdin.utf8))
            stdinPipe.fileHandleForWriting.closeFile()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            guard process.terminationStatus == 0 else {
                throw AgentServiceError.cliFailed(
                    provider,
                    exitCode: process.terminationStatus,
                    stderr: String(data: stderrData, encoding: .utf8) ?? ""
                )
            }
            guard !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentServiceError.emptyResponse
            }
            return stdout
        }.value
    }
}

/// Вложение реплики чата: картинка, PDF или текстовый файл.
/// Классификация — при выборе файла; неподдержанное отбрасывается сразу.
struct AgentAttachment: Identifiable, Equatable {
    enum Kind: Equatable {
        /// mediaType вида "image/png".
        case image(mediaType: String)
        case pdf
        /// Текстовый файл — содержимое уходит текстом во всех режимах.
        case text(content: String)
    }

    let id = UUID()
    var fileName: String
    var kind: Kind
    var data: Data

    /// Лимит размера файла: держит запрос в пределах лимитов API
    /// (Anthropic — 5 МБ на картинку после base64-роста ~33%).
    static let maxBytes = 6 * 1024 * 1024

    enum LoadError: Error, LocalizedError {
        case tooLarge(String)
        case unsupported(String)
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let name):
                return "«\(name)» больше \(AgentAttachment.maxBytes / 1024 / 1024) МБ — не приложен."
            case .unsupported(let name):
                return "«\(name)»: формат не поддержан (картинки, PDF, текстовые файлы)."
            case .unreadable(let name):
                return "«\(name)» не удалось прочитать."
            }
        }
    }

    private static let imageMediaTypes: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
    ]

    static func load(from url: URL) throws -> AgentAttachment {
        let name = url.lastPathComponent
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            throw LoadError.unreadable(name)
        }
        guard data.count <= maxBytes else { throw LoadError.tooLarge(name) }

        let ext = url.pathExtension.lowercased()
        if let mediaType = imageMediaTypes[ext] {
            return AgentAttachment(fileName: name, kind: .image(mediaType: mediaType), data: data)
        }
        if ext == "pdf" {
            return AgentAttachment(fileName: name, kind: .pdf, data: data)
        }
        if let content = String(data: data, encoding: .utf8) {
            return AgentAttachment(fileName: name, kind: .text(content: content), data: data)
        }
        throw LoadError.unsupported(name)
    }

    var isImage: Bool {
        if case .image = kind { return true }
        return false
    }
}

/// Реплика диалога с чат-агентом (транспортная форма).
struct AgentChatTurn {
    enum Role: String {
        case user
        case assistant
    }

    var role: Role
    var text: String
    var attachments: [AgentAttachment] = []
}

/// Вызов ИИ-агента: собирает промпт с NMT-скиллом, ходит в API выбранного
/// провайдера, парсит JSON в артефакты.
enum AgentService {
    static func runResearch(
        solution: String,
        template: InterviewTemplate,
        config: AgentTaskConfig
    ) async throws -> AgentArtifactsPayload {
        let prompt = AgentPrompt.researchPrompt(solution: solution, template: template)
        let text = try await complete(
            system: AgentPrompt.nmtSkill,
            turns: [AgentChatTurn(role: .user, text: prompt)],
            config: config
        )
        return try AgentArtifactsPayload.parse(from: text)
    }

    /// Ход чата: вся история диалога + system с контекстом проекта →
    /// сырой текст ответа (команды из него разбирает AgentChatReply).
    static func runChat(
        turns: [AgentChatTurn],
        projectContext: String,
        config: AgentTaskConfig
    ) async throws -> String {
        try await complete(
            system: AgentPrompt.chatSystem(projectContext: projectContext),
            turns: turns,
            config: config
        )
    }

    /// Общий вызов: system + история реплик через выбранный провайдер.
    private static func complete(
        system: String,
        turns: [AgentChatTurn],
        config: AgentTaskConfig
    ) async throws -> String {
        switch (config.provider, config.authMode) {
        case (.claude, .apiToken):
            return try await callAnthropic(
                token: try requireToken(.claude), model: config.model,
                effort: config.effort, system: system, turns: turns
            )
        case (.codex, .apiToken):
            return try await callOpenAI(
                token: try requireToken(.codex), model: config.model,
                effort: config.effort, system: system, turns: turns
            )
        case (.claude, .subscription):
            return try await callClaudeCLI(model: config.model, system: system, turns: turns)
        case (.codex, .subscription):
            return try await callCodexCLI(
                model: config.model, effort: config.effort, system: system, turns: turns
            )
        }
    }

    /// CLI-режимы не держат состояние диалога — история склеивается
    /// в один промпт с ролями. Бинарные вложения (картинки/PDF)
    /// материализуются во временные файлы, CLI читает их с диска.
    private static func flattenTurns(_ turns: [AgentChatTurn]) -> String {
        let rendered = turns.map { turn in
            var text = turn.text
            let notes = turn.attachments.compactMap(attachmentNote)
            if !notes.isEmpty {
                text += "\n\n" + notes.joined(separator: "\n")
            }
            return (role: turn.role, text: text)
        }
        guard rendered.count > 1 else { return rendered.first?.text ?? "" }
        let transcript = rendered.map { turn in
            switch turn.role {
            case .user: return "Пользователь:\n\(turn.text)"
            case .assistant: return "Агент (ты):\n\(turn.text)"
            }
        }.joined(separator: "\n\n")
        return "Диалог до этого момента:\n\n\(transcript)\n\nОтветь на последнюю реплику пользователя."
    }

    /// Вложение → фрагмент промпта CLI: текст инлайном, бинарь — путём
    /// к временному файлу (CLI работает из temporaryDirectory и может
    /// его читать).
    private static func attachmentNote(_ attachment: AgentAttachment) -> String? {
        switch attachment.kind {
        case .text(let content):
            return "Приложенный файл «\(attachment.fileName)»:\n```\n\(content)\n```"
        case .image, .pdf:
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("petable-attachments", isDirectory: true)
            let url = directory.appendingPathComponent("\(attachment.id.uuidString)-\(attachment.fileName)")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try attachment.data.write(to: url)
            } catch {
                return "Приложенный файл «\(attachment.fileName)» не удалось сохранить для чтения."
            }
            return "Приложенный файл (прочитай с диска): \(url.path)"
        }
    }

    /// Контент реплики для Anthropic Messages API: строка без вложений,
    /// иначе массив блоков (картинки/PDF — base64, текст файлов — текстом).
    private static func anthropicContent(_ turn: AgentChatTurn) -> Any {
        guard !turn.attachments.isEmpty else { return turn.text }
        var blocks: [[String: Any]] = []
        for attachment in turn.attachments {
            switch attachment.kind {
            case .image(let mediaType):
                blocks.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": mediaType,
                        "data": attachment.data.base64EncodedString(),
                    ],
                ])
            case .pdf:
                blocks.append([
                    "type": "document",
                    "source": [
                        "type": "base64",
                        "media_type": "application/pdf",
                        "data": attachment.data.base64EncodedString(),
                    ],
                ])
            case .text(let content):
                blocks.append([
                    "type": "text",
                    "text": "Приложенный файл «\(attachment.fileName)»:\n```\n\(content)\n```",
                ])
            }
        }
        blocks.append(["type": "text", "text": turn.text])
        return blocks
    }

    /// Контент реплики для OpenAI Responses API.
    private static func openAIContent(_ turn: AgentChatTurn) -> Any {
        guard !turn.attachments.isEmpty else { return turn.text }
        var parts: [[String: Any]] = []
        for attachment in turn.attachments {
            switch attachment.kind {
            case .image(let mediaType):
                parts.append([
                    "type": "input_image",
                    "image_url": "data:\(mediaType);base64,\(attachment.data.base64EncodedString())",
                ])
            case .pdf:
                parts.append([
                    "type": "input_file",
                    "filename": attachment.fileName,
                    "file_data": "data:application/pdf;base64,\(attachment.data.base64EncodedString())",
                ])
            case .text(let content):
                parts.append([
                    "type": "input_text",
                    "text": "Приложенный файл «\(attachment.fileName)»:\n```\n\(content)\n```",
                ])
            }
        }
        parts.append(["type": "input_text", "text": turn.text])
        return parts
    }

    private static func requireToken(_ provider: AgentProvider) throws -> String {
        guard let token = AgentTokenStore.token(for: provider) else {
            throw AgentServiceError.missingToken(provider)
        }
        return token
    }

    // MARK: Подписка: Claude Code CLI

    /// `claude -p` в headless-режиме: использует логин Claude Code
    /// (подписка Pro/Max). System уходит через --append-system-prompt,
    /// промпт задачи (склеенная история) — через stdin.
    private static func callClaudeCLI(
        model: String, system: String, turns: [AgentChatTurn]
    ) async throws -> String {
        try await AgentCLI.run(
            .claude,
            arguments: [
                "-p",
                "--output-format", "text",
                "--model", model,
                "--append-system-prompt", system,
            ],
            stdin: flattenTurns(turns)
        )
    }

    // MARK: Подписка: Codex CLI

    /// `codex exec` в headless-режиме: использует логин Codex CLI
    /// (подписка ChatGPT Plus/Pro). Промпт — через stdin («-»).
    private static func callCodexCLI(
        model: String, effort: AgentEffort, system: String, turns: [AgentChatTurn]
    ) async throws -> String {
        try await AgentCLI.run(
            .codex,
            arguments: [
                "exec",
                "--skip-git-repo-check",
                "--model", model,
                "-c", "model_reasoning_effort=\"\(effort.openAIValue)\"",
                "-",
            ],
            stdin: system + "\n\n" + flattenTurns(turns)
        )
    }

    // MARK: Anthropic Messages API

    private static func callAnthropic(
        token: String, model: String, effort: AgentEffort,
        system: String, turns: [AgentChatTurn]
    ) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16000,
            "system": system,
            "messages": turns.map { ["role": $0.role.rawValue, "content": anthropicContent($0)] },
        ]
        // Fable 5: thinking всегда включён, параметр опускается.
        // Haiku 4.5: adaptive thinking и effort не поддерживаются — опускаем.
        let isFable = model.contains("fable") || model.contains("mythos")
        let isHaiku = model.contains("haiku")
        if !isFable && !isHaiku {
            body["thinking"] = ["type": "adaptive"]
        }
        if !isHaiku {
            body["output_config"] = ["effort": effort.anthropicValue]
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = 600
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentServiceError.emptyResponse
        }
        if json["stop_reason"] as? String == "refusal" {
            throw AgentServiceError.refusal
        }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        guard !text.isEmpty else { throw AgentServiceError.emptyResponse }
        return text
    }

    // MARK: OpenAI Responses API (Codex)

    private static func callOpenAI(
        token: String, model: String, effort: AgentEffort,
        system: String, turns: [AgentChatTurn]
    ) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "reasoning": ["effort": effort.openAIValue],
            "input": [["role": "developer", "content": system]]
                + turns.map { ["role": $0.role.rawValue, "content": openAIContent($0)] },
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 600
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkHTTP(response, data: data)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentServiceError.emptyResponse
        }
        // Responses API: output[] → message → content[] → output_text.
        var parts: [String] = []
        for item in json["output"] as? [[String: Any]] ?? []
        where item["type"] as? String == "message" {
            for content in item["content"] as? [[String: Any]] ?? []
            where content["type"] as? String == "output_text" {
                if let text = content["text"] as? String { parts.append(text) }
            }
        }
        let text = parts.joined(separator: "\n")
        guard !text.isEmpty else { throw AgentServiceError.emptyResponse }
        return text
    }

    private static func checkHTTP(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentServiceError.httpError(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
    }
}
