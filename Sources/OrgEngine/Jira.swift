import Foundation
import GraphCore

// Слайс 7 (П4″): Jira туда-обратно. Импорт — read-only, выполняется
// приложением (токен в его Keychain); запись статуса и комментария при
// финале — демоном по intent-протоколу T2. Секреты демон держит только
// в памяти (Безопасность дизайн-дока).

/// Учётные данные Jira Cloud. Приложение читает их из Keychain и передаёт
/// демону по XPC при коннекте; демон НЕ персистит.
///
/// Два способа авторизации: OAuth-коннектор (`bearerToken`, база
/// `https://api.atlassian.com/ex/jira/<cloudId>`) — приоритетный; и
/// ручной API-токен (`email`+`token`, Basic, база сайта).
public struct JiraConfig: Codable, Equatable, Sendable {
    /// База REST без завершающего «/»: сайт (`https://team.atlassian.net`)
    /// для Basic или `https://api.atlassian.com/ex/jira/<cloudId>` для OAuth.
    public var baseURL: String
    public var email: String
    public var token: String
    /// Access-токен OAuth-коннектора; непустой — используется вместо Basic.
    /// Короткоживущий: приложение освежает его при каждом configure, демон
    /// между конфигурациями переживает истечение очередью write-back.
    public var bearerToken: String

    public init(baseURL: String, email: String = "", token: String = "", bearerToken: String = "") {
        self.baseURL = baseURL
        self.email = email
        self.token = token
        self.bearerToken = bearerToken
    }

    public var authorizationHeader: String? {
        if !bearerToken.isEmpty { return "Bearer \(bearerToken)" }
        guard !email.isEmpty, !token.isEmpty else { return nil }
        return "Basic \(Data("\(email):\(token)".utf8).base64EncodedString())"
    }

    public var isComplete: Bool {
        !baseURL.isEmpty && authorizationHeader != nil
    }
}

/// Задача Jira после импорта — только поля, нужные маппингу П4″.
public struct JiraIssue: Equatable, Sendable {
    public var key: String
    public var summary: String
    public var description: String
    public var typeName: String
    public var projectKey: String

    public init(
        key: String, summary: String, description: String = "",
        typeName: String = "", projectKey: String = ""
    ) {
        self.key = key
        self.summary = summary
        self.description = description
        self.typeName = typeName
        self.projectKey = projectKey
    }
}

/// Ошибка Jira API; `statusCode == 401` — протухший токен, у борда
/// баннер с кнопкой переавторизации (матрица 4A).
public struct JiraError: Error, Equatable, Sendable {
    public var statusCode: Int
    public var message: String

    public init(statusCode: Int = 0, message: String) {
        self.statusCode = statusCode
        self.message = message
    }
}

/// HTTP-шов: тесты подменяют сеть фикстурами.
public protocol JiraHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

public struct URLSessionJiraTransport: JiraHTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

/// Внешние эффекты Jira, которые исполняет демон, — шов для тестов
/// DaemonCore (по образцу AdapterRegistry).
public protocol JiraGateway: Sendable {
    func addComment(_ config: JiraConfig, issueKey: String, body: String) async throws
    /// Сверка факта при recovery (T2): комментарий с маркером runID уже есть?
    func hasComment(_ config: JiraConfig, issueKey: String, marker: String) async throws -> Bool
    /// Переход в статус категории «done»; перехода нет (уже Done) — no-op.
    func transitionToDone(_ config: JiraConfig, issueKey: String) async throws
    /// Статусная модель Jira не 1:1 с конвейером — выбирается ближайший
    /// переход: сперва по подсказкам имени (в порядке приоритета), затем
    /// по категории; ничего похожего — no-op, не ошибка.
    func transitionBestMatch(
        _ config: JiraConfig, issueKey: String, hints: [String], category: String?
    ) async throws
}

/// Клиент REST API v2 Jira Cloud: v2 отдаёт описание плоским текстом
/// (v3 — ADF-деревом, которое конвейеру не нужно).
public struct JiraClient: JiraGateway, Sendable {
    let transport: any JiraHTTPTransport

    public init(transport: any JiraHTTPTransport = URLSessionJiraTransport()) {
        self.transport = transport
    }

    // MARK: Импорт

    public func searchIssues(
        _ config: JiraConfig, jql: String, maxResults: Int = 50
    ) async throws -> [JiraIssue] {
        let data = try await get(config, path: "/rest/api/2/search", query: [
            URLQueryItem(name: "jql", value: jql),
            URLQueryItem(name: "fields", value: "summary,description,issuetype,project"),
            URLQueryItem(name: "maxResults", value: "\(maxResults)"),
        ])
        let page = try decode(SearchResponse.self, from: data)
        return page.issues.map {
            JiraIssue(
                key: $0.key,
                summary: $0.fields.summary ?? "",
                description: $0.fields.description ?? "",
                typeName: $0.fields.issuetype?.name ?? "",
                projectKey: $0.fields.project?.key ?? ""
            )
        }
    }

    // MARK: Запись при финале

    public func addComment(_ config: JiraConfig, issueKey: String, body: String) async throws {
        try await post(
            config, path: "/rest/api/2/issue/\(issueKey)/comment",
            json: ["body": body]
        )
    }

    public func hasComment(
        _ config: JiraConfig, issueKey: String, marker: String
    ) async throws -> Bool {
        let data = try await get(
            config, path: "/rest/api/2/issue/\(issueKey)/comment",
            query: [URLQueryItem(name: "maxResults", value: "100"),
                    URLQueryItem(name: "orderBy", value: "-created")]
        )
        let page = try decode(CommentsResponse.self, from: data)
        return page.comments.contains { ($0.body ?? "").contains(marker) }
    }

    public func transitionToDone(_ config: JiraConfig, issueKey: String) async throws {
        try await transitionBestMatch(config, issueKey: issueKey, hints: [], category: "done")
    }

    public func transitionBestMatch(
        _ config: JiraConfig, issueKey: String, hints: [String], category: String?
    ) async throws {
        let data = try await get(
            config, path: "/rest/api/2/issue/\(issueKey)/transitions", query: []
        )
        let page = try decode(TransitionsResponse.self, from: data)
        var match: TransitionsResponse.Transition?
        for hint in hints {
            if let found = page.transitions.first(
                where: { ($0.name ?? "").localizedCaseInsensitiveContains(hint) }
            ) {
                match = found
                break
            }
        }
        if match == nil, let category {
            match = page.transitions.first { $0.to?.statusCategory?.key == category }
        }
        guard let match else { return } // похожего статуса нет — no-op
        try await post(
            config, path: "/rest/api/2/issue/\(issueKey)/transitions",
            json: ["transition": ["id": match.id]]
        )
    }

    // MARK: HTTP

    private func get(
        _ config: JiraConfig, path: String, query: [URLQueryItem]
    ) async throws -> Data {
        try await send(request(config, path: path, query: query))
    }

    private func post(_ config: JiraConfig, path: String, json: Any) async throws {
        var request = request(config, path: path, query: [])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        _ = try await send(request)
    }

    private func request(
        _ config: JiraConfig, path: String, query: [URLQueryItem]
    ) -> URLRequest {
        let base = config.baseURL.hasSuffix("/")
            ? String(config.baseURL.dropLast()) : config.baseURL
        var components = URLComponents(string: base + path) ?? URLComponents()
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url ?? URL(fileURLWithPath: "/"))
        if let authorization = config.authorizationHeader {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, status) = try await transport.send(request)
        guard (200..<300).contains(status) else {
            let snippet = String(String(data: data, encoding: .utf8)?.prefix(200) ?? "")
            throw JiraError(statusCode: status, message: snippet)
        }
        return data
    }

    // MARK: Ответы API

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw JiraError(message: "не разобрал ответ Jira: \(error)")
        }
    }

    private struct SearchResponse: Decodable {
        var issues: [Issue]

        struct Issue: Decodable {
            var key: String
            var fields: Fields
        }

        struct Fields: Decodable {
            var summary: String?
            var description: String?
            var issuetype: Named?
            var project: Keyed?
        }

        struct Named: Decodable { var name: String? }
        struct Keyed: Decodable { var key: String? }
    }

    private struct CommentsResponse: Decodable {
        var comments: [Comment]

        struct Comment: Decodable { var body: String? }
    }

    private struct TransitionsResponse: Decodable {
        var transitions: [Transition]

        struct Transition: Decodable {
            var id: String
            var name: String?
            var to: To?
        }

        struct To: Decodable { var statusCategory: Category? }
        struct Category: Decodable { var key: String? }
    }
}

/// Маппинг импорта (П4″) — чистая функция, тестируется без сети:
/// тип задачи из поля Jira → `OrgTaskType.jiraType`, Jira-проект →
/// `RepoRef.jiraProject`. Маппинг проекта НЕ обязателен (правка автора):
/// не разрешился — единственный репозиторий берётся сам, при нескольких
/// репозиторий выберет агент на старте (`repoID = nil`); пропуск только
/// когда реестр пуст.
public enum JiraImporter {
    public struct Result: Equatable, Sendable {
        public var tasks: [OrgTask]
        public var skipped: [String]

        public init(tasks: [OrgTask] = [], skipped: [String] = []) {
            self.tasks = tasks
            self.skipped = skipped
        }
    }

    public static func map(
        issues: [JiraIssue],
        organization: Organization,
        existingKeys: Set<String>
    ) -> Result {
        var result = Result()
        for issue in issues {
            guard !existingKeys.contains(issue.key) else { continue } // идемпотентный повтор
            // Репозиторий не условие импорта: nil выберется агентом на
            // старте (при пустом реестре — из GitHub-кандидатов).
            let repo = organization.repos.first(where: {
                !$0.jiraProject.isEmpty
                    && $0.jiraProject.caseInsensitiveCompare(issue.projectKey) == .orderedSame
            }) ?? (organization.repos.count == 1 ? organization.repos[0] : nil)
            let taskType = organization.taskTypes.first(where: {
                !$0.jiraType.isEmpty
                    && $0.jiraType.caseInsensitiveCompare(issue.typeName) == .orderedSame
            }) ?? organization.taskTypes.first(where: {
                $0.name.caseInsensitiveCompare(issue.typeName) == .orderedSame
            }) ?? organization.taskTypes.first
            guard let taskType else {
                result.skipped.append("\(issue.key): в организации нет типов задач")
                continue
            }
            result.tasks.append(OrgTask(
                title: issue.summary,
                details: issue.description,
                taskTypeID: taskType.id,
                repoID: repo?.id,
                source: .jira,
                jiraKey: issue.key
            ))
        }
        return result
    }
}
