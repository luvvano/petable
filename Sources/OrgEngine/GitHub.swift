import Foundation

// Интеграция GitHub (П7′, правка автора №5): подключение по токену,
// создание репозитория и клонирование в реестр организации. Токен —
// Keychain приложения; демону не передаётся (git push ходит по
// креденшелам git самого пользователя).

public struct GitHubError: Error, Equatable, Sendable {
    public var statusCode: Int
    public var message: String

    public init(statusCode: Int = 0, message: String) {
        self.statusCode = statusCode
        self.message = message
    }
}

/// Клиент REST API GitHub — тот же HTTP-шов, что у Jira.
public struct GitHubClient: Sendable {
    let transport: any JiraHTTPTransport

    public init(transport: any JiraHTTPTransport = URLSessionJiraTransport()) {
        self.transport = transport
    }

    /// Проверка токена: логин владельца («Подключён как X»).
    public func viewerLogin(token: String) async throws -> String {
        let data = try await send(request(token: token, path: "/user"))
        return try decode(Viewer.self, from: data).login
    }

    public struct RemoteRepo: Equatable, Sendable {
        public var name: String
        public var sshURL: String
        public var httpsURL: String

        public init(name: String, sshURL: String, httpsURL: String) {
            self.name = name
            self.sshURL = sshURL
            self.httpsURL = httpsURL
        }
    }

    /// Репозитории аккаунта (включая организации), свежие сверху —
    /// кандидаты автоклона при пустом реестре.
    public func listRepos(token: String, limit: Int = 100) async throws -> [RemoteRepo] {
        let data = try await send(request(
            token: token, path: "/user/repos?per_page=\(limit)&sort=updated"
        ))
        return try decode([RepoListItem].self, from: data).map {
            RemoteRepo(name: $0.name, sshURL: $0.ssh_url ?? "", httpsURL: $0.clone_url ?? "")
        }
    }

    /// Pull request для ветки запуска (правка автора): уже есть PR с этим
    /// head — возвращается его URL (идемпотентно, повторные заходы на
    /// гейт дубль не плодят); нет — создаётся. `ownerRepo` — `owner/repo`.
    public func ensurePullRequest(
        token: String, ownerRepo: String, head: String, base: String,
        title: String, body: String
    ) async throws -> String {
        let owner = ownerRepo.split(separator: "/").first.map(String.init) ?? ""
        let existing = try await send(request(
            token: token,
            path: "/repos/\(ownerRepo)/pulls?state=all&head=\(owner):\(head)"
        ))
        if let found = try decode([PullRequest].self, from: existing).first {
            return found.html_url
        }
        var request = request(token: token, path: "/repos/\(ownerRepo)/pulls")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "title": title, "head": head, "base": base, "body": body,
        ])
        let data = try await send(request)
        return try decode(PullRequest.self, from: data).html_url
    }

    /// Создаёт приватный репозиторий; возвращает https-URL для клона.
    public func createRepo(token: String, name: String) async throws -> String {
        var request = request(token: token, path: "/user/repos")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "name": name, "private": true, "auto_init": true,
        ])
        let data = try await send(request)
        return try decode(Repo.self, from: data).clone_url
    }

    private func request(token: String, path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.github.com\(path)")
            ?? URL(fileURLWithPath: "/"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, status) = try await transport.send(request)
        guard (200..<300).contains(status) else {
            let snippet = String(String(data: data, encoding: .utf8)?.prefix(200) ?? "")
            throw GitHubError(statusCode: status, message: snippet)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw GitHubError(message: "не разобрал ответ GitHub: \(error)")
        }
    }

    private struct Viewer: Decodable { var login: String }
    private struct Repo: Decodable { var clone_url: String }
    private struct PullRequest: Decodable { var html_url: String }

    private struct RepoListItem: Decodable {
        var name: String
        var ssh_url: String?
        var clone_url: String?
    }
}

/// Локальное разворачивание репозиториев реестра.
public enum RepoProvisioner {
    public struct ProvisionError: Error, Equatable, Sendable {
        public var message: String
    }

    /// Клонирует `url` в `root/<name>`; возвращает абсолютный путь клона.
    /// Каталог уже существует — ошибка, не перезапись.
    @discardableResult
    public static func clone(url: String, into root: URL, name: String) throws -> String {
        let target = root.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw ProvisionError(message: "каталог \(target.path) уже существует")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["clone", url, target.path]
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch {
            throw ProvisionError(message: "git не запустился: \(error)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
            ) ?? ""
            throw ProvisionError(message: String(output.suffix(300)))
        }
        return target.path
    }

    /// Корень локальных клонов организации (T3 — Application Support).
    public static func defaultRoot() -> URL {
        EventStore.defaultRoot().appendingPathComponent("repos", isDirectory: true)
    }
}
