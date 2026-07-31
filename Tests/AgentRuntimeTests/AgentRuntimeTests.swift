import Foundation
import Testing
@testable import AgentRuntime
import GraphCore

@Suite("Вердикт: парсинг финального ответа (T5)")
struct VerdictTests {
    @Test("Чистый JSON-блок")
    func plainJSON() {
        let verdict = Verdict.parse(from: #"{"status":"done","note":"ok"}"#)
        #expect(verdict == Verdict(status: .done, note: "ok"))
    }

    @Test("JSON в ```-огранке с текстом вокруг")
    func fencedJSON() {
        let text = """
        Готово, вот вердикт:
        ```json
        {"status":"changesRequested","note":"нет тестов"}
        ```
        """
        let verdict = Verdict.parse(from: text)
        #expect(verdict?.status == .changesRequested)
        #expect(verdict?.note == "нет тестов")
    }

    @Test("Берётся ПОСЛЕДНИЙ валидный блок (модель могла процитировать чужой)")
    func lastBlockWins() {
        let text = #"{"status":"done"} мусор {"status":"cannotComplete","note":"стоп"}"#
        #expect(Verdict.parse(from: text)?.status == .cannotComplete)
    }

    @Test("Подзадачи decompose парсятся")
    func subtasks() {
        let text = #"{"status":"done","subtasks":[{"title":"API","taskType":"Задача","repo":"backend"}]}"#
        let verdict = Verdict.parse(from: text)
        #expect(verdict?.subtasks == [.init(title: "API", taskType: "Задача", repo: "backend")])
    }

    @Test("Нет блока / битый JSON → nil (движок не гадает по тексту)")
    func invalid() {
        #expect(Verdict.parse(from: "сделал всё, отличная работа") == nil)
        #expect(Verdict.parse(from: #"{"status":"maybe"}"#) == nil)
        #expect(Verdict.parse(from: #"{"note":"без статуса"}"#) == nil)
    }

    @Test("Скобки внутри строк не ломают баланс")
    func bracesInsideStrings() {
        let verdict = Verdict.parse(from: #"{"status":"done","note":"скобки } { внутри"}"#)
        #expect(verdict?.note == "скобки } { внутри")
    }
}

@Suite("Парсеры стримов на фикстурах спайка (слайс 0)")
struct StreamParserTests {
    private func fixtureLines(_ name: String) throws -> [String] {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"
        ))
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }

    @Test("claude: init → started, assistant → log, result → finished с usage и стоимостью")
    func claudeFixture() throws {
        let parser = ClaudeStreamParser()
        let events = try fixtureLines("claude-stream").flatMap(parser.events(fromLine:))
        guard case let .started(sessionID) = events.first else {
            Issue.record("нет started: \(events)")
            return
        }
        #expect(!sessionID.isEmpty)
        guard case let .finished(verdict, usage) = events.last else {
            Issue.record("нет finished: \(events)")
            return
        }
        #expect(verdict.status == .done)
        #expect(usage.costEstimate > 0)
        #expect(usage.outputTokens > 0)
    }

    @Test("codex: thread.started → started, agent_message → finished, turn.completed → usage")
    func codexFixture() throws {
        let parser = CodexStreamParser()
        let lines = try fixtureLines("codex-stream")
        let events = lines.flatMap(parser.events(fromLine:))
        guard case let .started(thread) = events.first else {
            Issue.record("нет started: \(events)")
            return
        }
        #expect(!thread.isEmpty)
        guard case let .finished(verdict, _) = events.last else {
            Issue.record("нет finished: \(events)")
            return
        }
        #expect(verdict == Verdict(status: .done, note: "ok"))
        let usage = lines.compactMap { parser.usage(fromLine: $0) }.first
        #expect(usage?.inputTokens == 17228)
        #expect(usage?.outputTokens == 19)
    }

    @Test("claude: is_error → failed")
    func claudeError() {
        let line = #"{"type":"result","is_error":true,"result":"limit"}"#
        #expect(ClaudeStreamParser().events(fromLine: line) == [.failed("limit")])
    }

    @Test("codex: turn.failed → failed")
    func codexTurnFailed() {
        let line = #"{"type":"turn.failed","error":{"message":"schema"}}"#
        #expect(CodexStreamParser().events(fromLine: line) == [.failed("schema")])
    }

    @Test("Финал без валидного вердикта → failed, не done")
    func missingVerdictFails() {
        let line = #"{"type":"result","is_error":false,"result":"готово!","usage":{}}"#
        let events = ClaudeStreamParser().events(fromLine: line)
        guard case .failed = events.first else {
            Issue.record("ожидали failed: \(events)")
            return
        }
    }
}

@Suite("Трансляция конфигурации во флаги CLI")
struct InvocationTests {
    private func request(_ config: AdapterConfig, resume: String? = nil) -> AgentRequest {
        AgentRequest(
            prompt: "промпт",
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            config: config,
            resumeSessionID: resume
        )
    }

    @Test("claude: модель, effort, tools, harness, resume")
    func claudeArgs() {
        var config = AdapterConfig(cli: "claude", model: "opus", effort: "high")
        config.allowedTools = ["Read", "Edit"]
        config.harness = "инструкции"
        let args = CLIInvocation.claudeArguments(request(config, resume: "sid-1"))
        #expect(args.contains("--resume") && args.contains("sid-1"))
        #expect(args.contains("--model") && args.contains("opus"))
        #expect(args.contains("--effort") && args.contains("high"))
        #expect(args.contains("--allowedTools") && args.contains("Edit"))
        #expect(args.contains("--append-system-prompt"))
        #expect(args.contains("stream-json"))
    }

    @Test("codex: read-only профиль ревьюера, схема вердикта, skip-git-repo-check")
    func codexArgs() {
        let config = AdapterConfig(cli: "codex", model: "gpt-5.6-sol", permissionProfile: "readOnly")
        let args = CLIInvocation.codexArguments(request(config), schemaPath: "/tmp/schema.json")
        #expect(args.contains("read-only"))
        #expect(args.contains("--skip-git-repo-check"))
        #expect(args.contains("--output-schema") && args.contains("/tmp/schema.json"))
        #expect(args.contains("--json"))
        // write-профиль → workspace-write
        let writeArgs = CLIInvocation.codexArguments(
            request(AdapterConfig(cli: "codex")), schemaPath: nil
        )
        #expect(writeArgs.contains("workspace-write"))
    }

    @Test("codex resume: подкоманда resume <thread> перед промптом; sandbox через -c, НЕ -s (exit 2 — находка SCRUM-35)")
    func codexResume() {
        let args = CLIInvocation.codexArguments(
            request(AdapterConfig(cli: "codex", permissionProfile: "readOnly"), resume: "th-9"),
            schemaPath: nil
        )
        #expect(Array(args.prefix(3)) == ["exec", "resume", "th-9"])
        #expect(!args.contains("-s")) // `exec resume` не знает -s
        #expect(args.contains("sandbox_mode=\"read-only\""))
    }

    @Test("Реестр адаптеров: неизвестный CLI → nil (состояние UI, не тихий провал)")
    func registry() {
        let registry = AdapterRegistry([])
        #expect(registry.adapter(for: AdapterConfig(cli: "gemini")) == nil)
    }
}
