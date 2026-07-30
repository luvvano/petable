import Foundation
import GraphCore

/// Общий процессный адаптер: один запускатель CLI на всех потребителей
/// (решение 4A). Конкретика CLI — аргументы и парсер стрима.
public struct CLIProcessAdapter: AgentAdapter {
    public let cliID: String
    let executable: URL
    let makeArguments: @Sendable (AgentRequest) -> [String]
    let parser: any StreamParsing
    /// Usage приходит отдельной строкой (codex turn.completed); nil — usage в финале (claude).
    let usageLine: (@Sendable (String) -> AgentUsage?)?

    public init(
        cliID: String,
        executable: URL,
        makeArguments: @escaping @Sendable (AgentRequest) -> [String],
        parser: any StreamParsing,
        usageLine: (@Sendable (String) -> AgentUsage?)? = nil
    ) {
        self.cliID = cliID
        self.executable = executable
        self.makeArguments = makeArguments
        self.parser = parser
        self.usageLine = usageLine
    }

    /// Готовые адаптеры v1. `executable` ищется по PATH заранее (в демоне,
    /// при старте) — «CLI не найден» должен быть состоянием UI, а не
    /// исключением в глубине запуска.
    public static func claude(executable: URL) -> CLIProcessAdapter {
        CLIProcessAdapter(
            cliID: "claude",
            executable: executable,
            makeArguments: { CLIInvocation.claudeArguments($0) },
            parser: ClaudeStreamParser()
        )
    }

    public static func codex(executable: URL, schemaPath: String?) -> CLIProcessAdapter {
        let parser = CodexStreamParser()
        return CLIProcessAdapter(
            cliID: "codex",
            executable: executable,
            makeArguments: { CLIInvocation.codexArguments($0, schemaPath: schemaPath) },
            parser: parser,
            usageLine: { parser.usage(fromLine: $0) }
        )
    }

    /// Бинарь CLI; nil — не установлен (состояние «CLI не найден»).
    public static func find(_ name: String) -> URL? {
        CLIDiscovery.locate(name)
    }

    public func run(_ request: AgentRequest) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = makeArguments(request)
            process.currentDirectoryURL = request.workingDirectory
            // stdin закрыт сразу: CLI неинтерактивны (П2), а claude без
            // этого ждёт stdin 3 секунды — находка спайка.
            process.standardInput = FileHandle.nullDevice

            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()

            let state = StreamState(parser: parser, usageLine: usageLine)

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                for event in state.consume(data) {
                    continuation.yield(event)
                }
            }

            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                let trailing = stdout.fileHandleForReading.readDataToEndOfFile()
                for event in state.consume(trailing, flush: true) {
                    continuation.yield(event)
                }
                for event in state.finale(exitCode: process.terminationStatus) {
                    continuation.yield(event)
                }
                continuation.finish()
            }

            continuation.onTermination = { termination in
                if case .cancelled = termination, process.isRunning {
                    process.terminate()
                }
            }

            do {
                try process.run()
            } catch {
                continuation.yield(.failed("Не удалось запустить \(cliID): \(error.localizedDescription)"))
                continuation.finish()
            }
        }
    }
}

/// Построчная сборка стрима + склейка «вердикт из agent_message, usage из
/// turn.completed» для codex. Доступ сериализован очередью — хендлеры
/// FileHandle приходят с разных потоков.
final class StreamState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "petable.agent-stream")
    private let parser: any StreamParsing
    private let usageLine: (@Sendable (String) -> AgentUsage?)?
    private var buffer = Data()
    private var pendingVerdict: Verdict?
    private var pendingUsage: AgentUsage?
    private var emittedTerminal = false

    init(parser: any StreamParsing, usageLine: (@Sendable (String) -> AgentUsage?)?) {
        self.parser = parser
        self.usageLine = usageLine
    }

    func consume(_ data: Data, flush: Bool = false) -> [AgentEvent] {
        queue.sync {
            buffer.append(data)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex ..< newline]
                buffer.removeSubrange(buffer.startIndex ... newline)
                if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                    lines.append(line)
                }
            }
            if flush, !buffer.isEmpty,
               let line = String(data: buffer, encoding: .utf8), !line.isEmpty {
                lines.append(line)
                buffer.removeAll()
            }
            return lines.flatMap(handle(line:))
        }
    }

    private func handle(line: String) -> [AgentEvent] {
        if let usage = usageLine?(line) {
            pendingUsage = usage
            return flushTerminalIfReady()
        }
        var out: [AgentEvent] = []
        for event in parser.events(fromLine: line) {
            if case let .finished(verdict, usage) = event {
                pendingVerdict = verdict
                if usageLine == nil {
                    // claude: usage приходит вместе с финалом.
                    pendingUsage = usage
                }
                out += flushTerminalIfReady()
            } else if case .failed = event {
                emittedTerminal = true
                out.append(event)
            } else {
                out.append(event)
            }
        }
        return out
    }

    private func flushTerminalIfReady() -> [AgentEvent] {
        guard !emittedTerminal, let verdict = pendingVerdict,
              usageLine == nil || pendingUsage != nil
        else { return [] }
        emittedTerminal = true
        return [.finished(verdict, usage: pendingUsage ?? AgentUsage())]
    }

    /// Процесс завершился: если терминального события не было —
    /// вердикт потерян (упал до финала, убит, невалидный вывод).
    func finale(exitCode: Int32) -> [AgentEvent] {
        queue.sync {
            if emittedTerminal { return [] }
            if let verdict = pendingVerdict {
                emittedTerminal = true
                return [.finished(verdict, usage: pendingUsage ?? AgentUsage())]
            }
            emittedTerminal = true
            return [.failed("Процесс завершился (код \(exitCode)) без вердикта")]
        }
    }
}
