import Foundation
import GraphCore

/// Запрос на исполнение одного этапа сотрудником.
public struct AgentRequest: Sendable {
    /// Полный промпт: роль + шаблон этапа + контекст задачи (+ переписка
    /// чата при рестарте-с-контекстом, П9).
    public var prompt: String
    /// Рабочая директория — worktree запуска.
    public var workingDirectory: URL
    public var config: AdapterConfig
    /// Сессия для продолжения (`claude --resume` / `codex exec resume`);
    /// nil — новый запуск.
    public var resumeSessionID: String?

    public init(
        prompt: String,
        workingDirectory: URL,
        config: AdapterConfig,
        resumeSessionID: String? = nil
    ) {
        self.prompt = prompt
        self.workingDirectory = workingDirectory
        self.config = config
        self.resumeSessionID = resumeSessionID
    }
}

/// Адаптер исполнителя (П2): запуск CLI в worktree, стрим событий,
/// вердикт из финального ответа. Движок зависит только от этого
/// протокола — вся машина состояний тестируется FakeAdapter'ом (5A).
public protocol AgentAdapter: Sendable {
    /// Идентификатор CLI (`claude` | `codex`) — матчится с AdapterConfig.cli.
    var cliID: String { get }
    /// Исполнить этап; поток завершается после `.finished`/`.failed`.
    func run(_ request: AgentRequest) -> AsyncStream<AgentEvent>
}

/// Реестр адаптеров: конфигурация сотрудника → адаптер.
public struct AdapterRegistry: Sendable {
    private let adapters: [String: any AgentAdapter]

    public init(_ adapters: [any AgentAdapter]) {
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.cliID, $0) })
    }

    /// nil — исполнитель не установлен/не зарегистрирован: этап
    /// «требует внимания» с причиной, не тихий провал (матрица 4A).
    public func adapter(for config: AdapterConfig) -> (any AgentAdapter)? {
        adapters[config.cli]
    }
}

/// Аргументы запуска обоих CLI — вынесены из процессного кода, чтобы
/// трансляция конфигурации была проверяемой без запуска процессов.
public enum CLIInvocation {
    /// `claude -p … --output-format stream-json` (спайк слайса 0).
    public static func claudeArguments(_ request: AgentRequest) -> [String] {
        var args = ["-p", request.prompt, "--output-format", "stream-json", "--verbose"]
        if let session = request.resumeSessionID { args += ["--resume", session] }
        if !request.config.model.isEmpty { args += ["--model", request.config.model] }
        if !request.config.effort.isEmpty { args += ["--effort", request.config.effort] }
        if !request.config.allowedTools.isEmpty {
            args += ["--allowedTools"] + request.config.allowedTools
        }
        if !request.config.harness.isEmpty {
            args += ["--append-system-prompt", request.config.harness]
        }
        return args
    }

    /// `codex exec --json --skip-git-repo-check` (worktree всегда git,
    /// но флаг делает адаптер нечувствительным к cwd — находка спайка).
    /// Вердикт enforced схемой: `--output-schema` (strict: все properties
    /// в required — вторая находка спайка).
    public static func codexArguments(_ request: AgentRequest, schemaPath: String?) -> [String] {
        var args = ["exec"]
        if let session = request.resumeSessionID { args += ["resume", session] }
        args += [request.prompt, "--json", "--skip-git-repo-check"]
        args += ["-s", request.config.permissionProfile == "readOnly" ? "read-only" : "workspace-write"]
        if !request.config.model.isEmpty { args += ["-m", request.config.model] }
        if !request.config.effort.isEmpty {
            args += ["-c", "model_reasoning_effort=\"\(request.config.effort)\""]
        }
        if let schemaPath { args += ["--output-schema", schemaPath] }
        return args
    }
}
