import Foundation
import GraphCore

/// XPC-граница демон ↔ приложение (решение 1A): NSXPCConnection принимает
/// только @objc-протоколы, поэтому через неё ходит `Data` с Codable-конвертом
/// `{v, type, payload}`. Вся типизация — здесь, ObjC-слой — две функции.
public struct WireEnvelope: Codable, Equatable, Sendable {
    /// Версия протокола. Несовпадение major — «обновить движок»;
    /// minor-дрейф обязан читаться (П0).
    public static let protocolVersion = 1

    public var v: Int
    public var type: String
    public var payload: Data

    public init(v: Int = WireEnvelope.protocolVersion, type: String, payload: Data) {
        self.v = v
        self.type = type
        self.payload = payload
    }

    /// Упаковка типизированного сообщения.
    public static func pack<T: Codable>(_ type: WireType, _ value: T) throws -> Data {
        let payload = try JSONEncoder().encode(value)
        let envelope = WireEnvelope(type: type.rawValue, payload: payload)
        return try JSONEncoder().encode(envelope)
    }

    /// Распаковка: nil — незнакомый тип (minor-дрейф: игнорировать,
    /// не падать); ошибка — битые данные.
    public static func unpack(_ data: Data) throws -> (type: WireType?, envelope: WireEnvelope) {
        let envelope = try JSONDecoder().decode(WireEnvelope.self, from: data)
        return (WireType(rawValue: envelope.type), envelope)
    }

    public func payload<T: Codable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: payload)
    }
}

/// Типы сообщений v1. Строки — third-party дрейф не ломает enum.
public enum WireType: String, Sendable {
    // Команды приложение → демон.
    case startRun, approve, reject, cancel, chat, subscribe, configure
    /// Drain перед обновлением движка (П0): новые этапы не начинаются,
    /// текущие дорабатывают; демон отвечает событием `drained`.
    case drain
    /// Теневой запуск задачи по экспериментальному флоу (слайс 13).
    case shadowRun
    /// Fork запуска с override модели (слайс 12, ⌥Enter).
    case forkRun
    // События демон → приложение (EventSink).
    case runState, logBatch, attention, handshake
    /// Активных этапов не осталось — демона можно заменять.
    case drained
}

/// Секреты внешних сервисов: приложение читает Keychain и передаёт демону
/// при коннекте (Безопасность дизайн-дока) — демон держит ТОЛЬКО в памяти,
/// после рестарта ждёт следующего коннекта, write-back копится в очереди.
/// `githubToken` — для агентного создания репозиториев под подзадачи
/// декомпозиции (правка №5).
public struct ConfigureCommand: Codable, Equatable, Sendable {
    public var jira: JiraConfig?
    public var githubToken: String?

    public init(jira: JiraConfig? = nil, githubToken: String? = nil) {
        self.jira = jira
        self.githubToken = githubToken
    }
}

/// Команда старта запуска. `candidates` — репозитории GitHub-аккаунта
/// на случай пустого реестра: демон выберет агентом и склонирует сам
/// (правка автора: ничего не привязывать руками).
public struct StartRunCommand: Codable, Equatable, Sendable {
    public var organization: Organization
    public var taskID: UUID
    public var candidates: [RemoteRepoCandidate]?

    public init(
        organization: Organization,
        taskID: UUID,
        candidates: [RemoteRepoCandidate]? = nil
    ) {
        self.organization = organization
        self.taskID = taskID
        self.candidates = candidates
    }
}

/// Кандидат на клонирование: оба URL — демон пробует ssh (ключи юзера),
/// затем https (credential helper git).
public struct RemoteRepoCandidate: Codable, Equatable, Sendable {
    public var name: String
    public var sshURL: String
    public var httpsURL: String

    public init(name: String, sshURL: String, httpsURL: String) {
        self.name = name
        self.sshURL = sshURL
        self.httpsURL = httpsURL
    }
}

/// Теневой запуск (слайс 13): та же задача по экспериментальному флоу.
/// Experimental: без Jira write-back, без push, merge недостижим;
/// результат — для сравнения в дебаггере.
public struct ShadowRunCommand: Codable, Equatable, Sendable {
    public var organization: Organization
    public var taskID: UUID
    public var flowID: UUID

    public init(organization: Organization, taskID: UUID, flowID: UUID) {
        self.organization = organization
        self.taskID = taskID
        self.flowID = flowID
    }
}

/// Fork запуска (слайс 12): продолжить с текущего этапа источника в
/// свежем worktree от точки форка (baseSHA, пин refs/petable) с
/// override модели у всех сотрудников; experimental.
public struct ForkRunCommand: Codable, Equatable, Sendable {
    public var runID: UUID
    /// Модель для всех сотрудников снапшота; пустая — без override.
    public var model: String

    public init(runID: UUID, model: String = "") {
        self.runID = runID
        self.model = model
    }
}

/// Снапшот состояния запуска для канваса — по XPC едут СОСТОЯНИЯ,
/// не поток строк (решение 6A).
public struct RunStateMessage: Codable, Equatable, Sendable {
    public var run: OrganizationRun

    public init(run: OrganizationRun) {
        self.run = run
    }
}

/// Коалесцированный батч лога для ОТКРЫТОЙ панели этапа (≤ 5 Гц, 6A).
public struct LogBatchMessage: Codable, Equatable, Sendable {
    public var runID: UUID
    public var stageID: UUID
    public var lines: [String]

    public init(runID: UUID, stageID: UUID, lines: [String]) {
        self.runID = runID
        self.stageID = stageID
        self.lines = lines
    }
}
