import Foundation

/// Парсер stream-формата одного CLI: строка JSONL → события контракта.
/// Форматы зафиксированы фикстурами спайка (слайс 0); дрейф при апгрейде
/// CLI ловят тесты на фикстурах.
public protocol StreamParsing: Sendable {
    /// События из одной строки стрима (обычно 0–1).
    func events(fromLine line: String) -> [AgentEvent]
}

/// `claude -p --output-format stream-json --verbose`.
/// Типы строк: `system` (шум сессии), `assistant` (текст хода),
/// `result` (финал: is_error, result-текст, usage, total_cost_usd,
/// session_id — ключ resume для чата П9).
public struct ClaudeStreamParser: StreamParsing {
    public init() {}

    public func events(fromLine line: String) -> [AgentEvent] {
        guard let object = Self.json(line) else { return [] }
        switch object["type"] as? String {
        case "system":
            if (object["subtype"] as? String) == "init",
               let session = object["session_id"] as? String {
                return [.started(sessionID: session)]
            }
            return []
        case "assistant":
            // message.content: [{type: text|thinking, text: …}] — в лог
            // уходит только видимый текст.
            guard let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]]
            else { return [] }
            let text = content
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            return text.isEmpty ? [] : [.log(text)]
        case "result":
            if (object["is_error"] as? Bool) == true {
                let message = (object["result"] as? String) ?? "claude: ошибка без описания"
                return [.failed(message)]
            }
            let usage = AgentUsage(
                inputTokens: Self.int(object, "usage", "input_tokens"),
                outputTokens: Self.int(object, "usage", "output_tokens"),
                costEstimate: (object["total_cost_usd"] as? Double) ?? 0
            )
            let text = (object["result"] as? String) ?? ""
            guard let verdict = Verdict.parse(from: text) else {
                return [.failed("Финальный ответ без валидного JSON-блока вердикта (T5)")]
            }
            return [.finished(verdict, usage: usage)]
        default:
            return []
        }
    }

    private static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static func int(_ object: [String: Any], _ key: String, _ sub: String) -> Int {
        ((object[key] as? [String: Any])?[sub] as? Int) ?? 0
    }
}

/// `codex exec --json --output-schema …`.
/// Типы строк: `thread.started` (thread_id — ключ resume),
/// `item.completed` c `agent_message` (текст = вердикт: схема enforced),
/// `turn.completed` (usage), `error`/`turn.failed`.
/// Запуску нужен git-репозиторий в cwd ЛИБО `--skip-git-repo-check` —
/// находка спайка.
public struct CodexStreamParser: StreamParsing {
    public init() {}

    public func events(fromLine line: String) -> [AgentEvent] {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        switch object["type"] as? String {
        case "thread.started":
            let thread = (object["thread_id"] as? String) ?? ""
            return [.started(sessionID: thread)]
        case "item.completed":
            guard let item = object["item"] as? [String: Any] else { return [] }
            switch item["type"] as? String {
            case "agent_message":
                // Финальный ответ; вердикт достаём здесь, usage придёт
                // отдельной строкой turn.completed — движок склеивает.
                guard let text = item["text"] as? String,
                      let verdict = Verdict.parse(from: text)
                else { return [.failed("Финальный ответ без валидного JSON-блока вердикта (T5)")] }
                return [.finished(verdict, usage: AgentUsage())]
            case "command_execution", "reasoning":
                let text = (item["command"] as? String) ?? (item["text"] as? String) ?? ""
                return text.isEmpty ? [] : [.log(text)]
            default:
                return []
            }
        case "error":
            return [.failed((object["message"] as? String) ?? "codex: ошибка без описания")]
        case "turn.failed":
            let message = ((object["error"] as? [String: Any])?["message"] as? String)
                ?? "codex: turn.failed"
            return [.failed(message)]
        default:
            return []
        }
    }

    /// Usage из строки `turn.completed`; nil для остальных строк.
    public func usage(fromLine line: String) -> AgentUsage? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["type"] as? String) == "turn.completed",
              let usage = object["usage"] as? [String: Any]
        else { return nil }
        return AgentUsage(
            inputTokens: (usage["input_tokens"] as? Int) ?? 0,
            outputTokens: (usage["output_tokens"] as? Int) ?? 0,
            costEstimate: 0
        )
    }
}
