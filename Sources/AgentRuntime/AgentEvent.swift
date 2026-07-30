import Foundation

/// Статус вердикта сотрудника — семантику завершения несёт САМ ответ
/// (JSON-блок в конце), а не процессные события CLI (решение T5).
public enum VerdictStatus: String, Codable, Sendable {
    case done
    case changesRequested
    case cannotComplete
}

/// Вердикт из финального ответа сотрудника.
public struct Verdict: Equatable, Sendable {
    public var status: VerdictStatus
    public var note: String
    /// Подзадачи decompose-этапа: `{заголовок, тип, репо}` по именам;
    /// резолвинг в id — забота движка.
    public var subtasks: [Subtask]

    public struct Subtask: Codable, Equatable, Sendable {
        public var title: String
        public var taskType: String
        public var repo: String

        public init(title: String, taskType: String = "", repo: String = "") {
            self.title = title
            self.taskType = taskType
            self.repo = repo
        }
    }

    public init(status: VerdictStatus, note: String = "", subtasks: [Subtask] = []) {
        self.status = status
        self.note = note
        self.subtasks = subtasks
    }

    private struct Payload: Codable {
        var status: VerdictStatus
        var note: String?
        var subtasks: [Subtask]?
    }

    /// Достаёт вердикт из финального текста сотрудника: последний JSON-объект
    /// с полем `status` (допускается ```json-огранка и текст вокруг).
    /// nil — блока нет или он не парсится: этап считается `failed` (T5),
    /// движок не гадает по тексту модели.
    public static func parse(from text: String) -> Verdict? {
        let decoder = JSONDecoder()
        // Кандидаты — сбалансированные JSON-объекты, ищем с конца.
        var candidates: [Substring] = []
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        for index in text.indices {
            let char = text[index]
            if escaped { escaped = false; continue }
            switch char {
            case "\\" where inString: escaped = true
            case "\"": inString.toggle()
            case "{" where !inString:
                if depth == 0 { start = index }
                depth += 1
            case "}" where !inString:
                depth -= 1
                if depth == 0, let s = start {
                    candidates.append(text[s ... index])
                    start = nil
                }
            default: break
            }
        }
        for candidate in candidates.reversed() {
            guard let data = String(candidate).data(using: .utf8),
                  let payload = try? decoder.decode(Payload.self, from: data)
            else { continue }
            return Verdict(
                status: payload.status,
                note: payload.note ?? "",
                subtasks: payload.subtasks ?? []
            )
        }
        return nil
    }
}

/// Использование модели за этап — из usage-полей CLI; деньги — оценка (T7.5).
public struct AgentUsage: Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    /// Оценка стоимости в долларах; 0 — CLI не отдал.
    public var costEstimate: Double

    public init(inputTokens: Int = 0, outputTokens: Int = 0, costEstimate: Double = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.costEstimate = costEstimate
    }
}

/// Событие адаптера — минимальный контракт П2. In-memory тип
/// (персистентная форма — RunEvent в OrgEngine, плоская).
public enum AgentEvent: Equatable, Sendable {
    case started(sessionID: String)
    case log(String)
    case artifact(kind: String, path: String)
    /// CLI задал вопрос. Fallback: движок переводит этап в «требует
    /// внимания», ответ приходит рестартом-с-контекстом (П9).
    case needsInput(prompt: String)
    case finished(Verdict, usage: AgentUsage)
    case failed(String)
}
