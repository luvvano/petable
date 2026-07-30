import AppKit
import Foundation
import Network
import Security
import OrgEngine

// Jira-коннектор «в один клик» (правка автора): OAuth 2.0 (3LO) Atlassian.
// Кнопка открывает браузер → страница согласия Atlassian → редирект на
// localhost-листенер → обмен кода на токены → сайт подтягивается сам из
// accessible-resources. Копировать пространство и API-токен не нужно.
//
// Единственная однократная настройка: Atlassian требует зарегистрированное
// OAuth-приложение (client_id + secret) в developer.atlassian.com — поля
// «Настройка коннектора» в Интеграциях.

/// Регистрация коннектора: client_id — UserDefaults, secret — Keychain.
enum JiraOAuthAppStore {
    private static let service = "com.egorproskurin.petable.jira"
    private static let secretAccount = "oauth-client-secret"
    private static let clientIDKey = "jira.oauth.clientID"

    static var clientID: String {
        get { UserDefaults.standard.string(forKey: clientIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: clientIDKey) }
    }

    static var clientSecret: String? {
        get { KeychainItem.read(service: service, account: secretAccount) }
        set { KeychainItem.write(newValue ?? "", service: service, account: secretAccount) }
    }

    static var isConfigured: Bool {
        !clientID.isEmpty && !(clientSecret ?? "").isEmpty
    }
}

/// Токены коннектора + выбранный сайт. Один Keychain-айтем (JSON).
struct JiraOAuthTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var cloudID: String
    var siteURL: String
}

enum JiraOAuthTokenStore {
    private static let service = "com.egorproskurin.petable.jira"
    private static let account = "oauth-tokens"

    static func load() -> JiraOAuthTokens? {
        guard let raw = KeychainItem.read(service: service, account: account),
              let data = raw.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(JiraOAuthTokens.self, from: data)
    }

    static func save(_ tokens: JiraOAuthTokens) {
        guard let data = try? JSONEncoder().encode(tokens),
              let raw = String(data: data, encoding: .utf8)
        else { return }
        KeychainItem.write(raw, service: service, account: account)
    }

    static func delete() {
        KeychainItem.write("", service: service, account: account)
    }
}

/// Общий Keychain-примитив (тот же паттерн, что AgentTokenStore).
enum KeychainItem {
    static func read(service: String, account: String) -> String? {
        var query = base(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func write(_ value: String, service: String, account: String) {
        let query = base(service: service, account: account)
        guard !value.isEmpty else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func base(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Сам поток: браузер → согласие → localhost-callback → токены → сайт.
enum JiraOAuthFlow {
    static let redirectPort: UInt16 = 52786
    static var redirectURI: String { "http://localhost:\(redirectPort)/callback" }
    private static let scopes = "read:jira-work write:jira-work offline_access"

    struct OAuthError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Полный проход подключения. Отмена — закрыть вкладку и подождать
    /// таймаут (5 минут).
    static func connect() async throws -> JiraOAuthTokens {
        let clientID = JiraOAuthAppStore.clientID
        guard JiraOAuthAppStore.isConfigured, let secret = JiraOAuthAppStore.clientSecret else {
            throw OAuthError(message: "коннектор не настроен: заполни Client ID и Secret")
        }
        let state = UUID().uuidString
        var components = URLComponents(string: "https://auth.atlassian.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "audience", value: "api.atlassian.com"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        let code = try await CallbackServer.waitForCode(
            port: redirectPort, expectedState: state,
            openingBrowserAt: components.url!
        )
        let grant = try await tokenRequest(json: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "client_secret": secret,
            "code": code,
            "redirect_uri": redirectURI,
        ])
        let site = try await primarySite(accessToken: grant.accessToken)
        return JiraOAuthTokens(
            accessToken: grant.accessToken,
            refreshToken: grant.refreshToken,
            expiresAt: Date().addingTimeInterval(grant.expiresIn),
            cloudID: site.id,
            siteURL: site.url
        )
    }

    /// Освежение access-токена (rotating refresh — сохранять результат).
    static func refresh(_ tokens: JiraOAuthTokens) async throws -> JiraOAuthTokens {
        guard JiraOAuthAppStore.isConfigured, let secret = JiraOAuthAppStore.clientSecret else {
            throw OAuthError(message: "коннектор не настроен")
        }
        let grant = try await tokenRequest(json: [
            "grant_type": "refresh_token",
            "client_id": JiraOAuthAppStore.clientID,
            "client_secret": secret,
            "refresh_token": tokens.refreshToken,
        ])
        var updated = tokens
        updated.accessToken = grant.accessToken
        if !grant.refreshToken.isEmpty { updated.refreshToken = grant.refreshToken }
        updated.expiresAt = Date().addingTimeInterval(grant.expiresIn)
        return updated
    }

    // MARK: Запросы Atlassian

    private struct Grant {
        var accessToken: String
        var refreshToken: String
        var expiresIn: TimeInterval
    }

    private static func tokenRequest(json: [String: String]) async throws -> Grant {
        var request = URLRequest(url: URL(string: "https://auth.atlassian.com/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = object["access_token"] as? String
        else {
            let snippet = String(String(data: data, encoding: .utf8)?.prefix(200) ?? "")
            throw OAuthError(message: "обмен токена не прошёл (HTTP \(status)): \(snippet)")
        }
        return Grant(
            accessToken: access,
            refreshToken: object["refresh_token"] as? String ?? "",
            expiresIn: object["expires_in"] as? TimeInterval ?? 3600
        )
    }

    private struct Site {
        var id: String
        var url: String
    }

    /// Первый доступный сайт Jira — «пространство» подтягивается само.
    private static func primarySite(accessToken: String) async throws -> Site {
        var request = URLRequest(
            url: URL(string: "https://api.atlassian.com/oauth/token/accessible-resources")!
        )
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = list.first,
              let id = first["id"] as? String,
              let url = first["url"] as? String
        else {
            throw OAuthError(message: "у аккаунта нет доступных сайтов Jira")
        }
        return Site(id: id, url: url)
    }
}

/// Одноразовый HTTP-листенер на localhost: ловит редирект Atlassian с
/// `code`, отвечает страницей «можно закрыть вкладку».
private enum CallbackServer {
    static func waitForCode(
        port: UInt16, expectedState: String, openingBrowserAt url: URL
    ) async throws -> String {
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            throw JiraOAuthFlow.OAuthError(
                message: "порт \(port) занят — закрой второй petable и повтори"
            )
        }
        defer { listener.cancel() }

        let box = ResumeBox()
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let outcome = Self.parse(request: request, expectedState: expectedState)
                Self.respond(connection, body: outcome.pageText)
                switch outcome {
                case let .code(code): box.resume(.success(code))
                case let .failure(message):
                    box.resume(.failure(JiraOAuthFlow.OAuthError(message: message)))
                case .ignore: break // favicon и прочий шум
                }
            }
        }
        listener.start(queue: .main)
        NSWorkspace.shared.open(url)
        // Таймаут: юзер закрыл вкладку — не висим вечно.
        let timeout = Task {
            try? await Task.sleep(for: .seconds(300))
            box.resume(.failure(JiraOAuthFlow.OAuthError(
                message: "не дождался подтверждения в браузере (5 мин)"
            )))
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.attach(continuation)
            }
        } onCancel: {
            box.resume(.failure(CancellationError()))
        }
    }

    private enum Outcome {
        case code(String)
        case failure(String)
        case ignore

        var pageText: String {
            switch self {
            case .code: return "petable: Jira подключена — вкладку можно закрыть."
            case let .failure(message): return "petable: \(message)"
            case .ignore: return ""
            }
        }
    }

    private static func parse(request: String, expectedState: String) -> Outcome {
        guard let line = request.split(separator: "\r\n").first,
              line.hasPrefix("GET ")
        else { return .ignore }
        let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        guard path.hasPrefix("/callback") else { return .ignore }
        let components = URLComponents(string: "http://localhost\(path)")
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        if let error = value("error") {
            return .failure("Atlassian отказал: \(value("error_description") ?? error)")
        }
        guard value("state") == expectedState else {
            return .failure("state не совпал — попробуй ещё раз")
        }
        guard let code = value("code"), !code.isEmpty else {
            return .failure("редирект без кода")
        }
        return .code(code)
    }

    private static func respond(_ connection: NWConnection, body: String) {
        let html = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Connection: close\r
        \r
        <html><body style="font: 14px -apple-system; padding: 40px">\(body)</body></html>
        """
        connection.send(content: Data(html.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Continuation резюмится ровно один раз, из какого бы соединения,
    /// таймаута или отмены ни пришёл результат; первый результат может
    /// прийти и ДО attach.
    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<String, Error>?
        private var result: Result<String, Error>?

        func attach(_ continuation: CheckedContinuation<String, Error>) {
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resume(_ result: Result<String, Error>) {
            lock.lock()
            guard self.result == nil else {
                lock.unlock()
                return
            }
            self.result = result
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }
}
