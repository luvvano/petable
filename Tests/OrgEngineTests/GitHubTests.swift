import Foundation
import Testing
@testable import OrgEngine

@Suite("GitHub: клиент и локальное клонирование")
struct GitHubTests {
    private final class FakeTransport: JiraHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var requests: [URLRequest] = []
        private var responses: [(Data, Int)]

        init(_ responses: [(String, Int)]) {
            self.responses = responses.map { (Data($0.0.utf8), $0.1) }
        }

        func send(_ request: URLRequest) async throws -> (Data, Int) {
            lock.withLock {
                requests.append(request)
                return responses.isEmpty ? (Data("{}".utf8), 200) : responses.removeFirst()
            }
        }
    }

    @Test("viewerLogin: bearer-токен, разбор логина; 401 — GitHubError")
    func viewer() async throws {
        let transport = FakeTransport([(#"{"login":"egor"}"#, 200)])
        let login = try await GitHubClient(transport: transport).viewerLogin(token: "t0k")
        #expect(login == "egor")
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/user")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")

        await #expect(throws: GitHubError.self) {
            _ = try await GitHubClient(transport: FakeTransport([("{}", 401)]))
                .viewerLogin(token: "bad")
        }
    }

    @Test("createRepo: POST /user/repos, приватный, возвращает clone_url")
    func createRepo() async throws {
        let transport = FakeTransport([
            (#"{"clone_url":"https://github.com/egor/demo.git"}"#, 201)
        ])
        let url = try await GitHubClient(transport: transport)
            .createRepo(token: "t0k", name: "demo")
        #expect(url == "https://github.com/egor/demo.git")
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        let body = try JSONSerialization.jsonObject(
            with: try #require(request.httpBody)
        ) as? [String: Any]
        #expect(body?["name"] as? String == "demo")
        #expect(body?["private"] as? Bool == true)
    }

    @Test("RepoProvisioner: клон локального репо; существующий каталог — ошибка")
    func cloneLocal() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("petable-clone-\(UUID().uuidString)")
        let origin = base.appendingPathComponent("origin")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        func git(_ args: String...) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = origin
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        try git("init", "-q")
        try "x".write(to: origin.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init")

        let clones = base.appendingPathComponent("clones")
        let path = try RepoProvisioner.clone(url: origin.path, into: clones, name: "demo")
        #expect(FileManager.default.fileExists(atPath: path + "/a.txt"))

        #expect(throws: RepoProvisioner.ProvisionError.self) {
            try RepoProvisioner.clone(url: origin.path, into: clones, name: "demo")
        }
    }
}
