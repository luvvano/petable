import Foundation
import GraphCore

/// Персистентное событие запуска — плоская структура (П1c): kind —
/// строка, полезные поля опциональны. Источник правды восстановления.
public struct RunEvent: Codable, Equatable, Sendable {
    public var seq: Int
    public var date: Date
    public var kind: String
    public var stageID: UUID?
    public var text: String?
    public var status: String?
    /// Ключ intent-протокола (T2): «намерение → эффект → подтверждение».
    public var intentKey: String?
    public var pid: Int?
    public var sha: String?
    public var cost: Double?
    /// Слепок запуска (kind == .snapshot) — восстановление без реплея
    /// всей истории: последний слепок + хвост событий.
    public var run: OrganizationRun?

    public init(
        seq: Int,
        date: Date,
        kind: Kind,
        stageID: UUID? = nil,
        text: String? = nil,
        status: String? = nil,
        intentKey: String? = nil,
        pid: Int? = nil,
        sha: String? = nil,
        cost: Double? = nil,
        run: OrganizationRun? = nil
    ) {
        self.seq = seq
        self.date = date
        self.kind = kind.rawValue
        self.stageID = stageID
        self.text = text
        self.status = status
        self.intentKey = intentKey
        self.pid = pid
        self.sha = sha
        self.cost = cost
        self.run = run
    }

    public enum Kind: String, Sendable {
        case runStarted, snapshot, stageStarted, log, artifact, needsInput
        case stageFinished, stageFailed, gateApproved, gateRejected
        case returned, needsAttention, testPassed, testFailed
        /// Intent-протокол внешних эффектов (T2).
        case intent, effectConfirmed
        case processSpawned
        case runFinished
        /// Сообщение человека сотруднику (П9) — переписка живёт в
        /// журнале и переживает рестарты.
        case chatMessage
    }

    public var kindValue: Kind? { Kind(rawValue: kind) }
}

/// Результат чтения запуска из хранилища.
public enum LoadedRun: Sendable {
    /// События (обрезанная хвостовая строка уже отброшена — карантин 3A).
    case events([RunEvent])
    /// Каталог/записи не читаются: запуск broken, демон живёт дальше.
    case broken(reason: String)
}

/// Event-хранилище запусков: `<root>/runs/<orgID>/<runID>/events.jsonl`
/// (+ artifacts/ рядом). Root по умолчанию — Application Support (T3),
/// в тестах — временный каталог.
public struct EventStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// Продакшен-корень: `~/Library/Application Support/Petable` —
    /// НЕ ~/Documents (TCC headless-демона + iCloud-синк, решение T3).
    public static func defaultRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Petable", isDirectory: true)
    }

    public func runDirectory(orgID: UUID, runID: UUID) -> URL {
        root.appendingPathComponent("runs", isDirectory: true)
            .appendingPathComponent(orgID.uuidString, isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    private func eventsFile(orgID: UUID, runID: UUID) -> URL {
        runDirectory(orgID: orgID, runID: runID).appendingPathComponent("events.jsonl")
    }

    /// Дописывает событие строкой JSONL (append-only).
    public func append(_ event: RunEvent, orgID: UUID, runID: UUID) throws {
        let directory = runDirectory(orgID: orgID, runID: runID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(event)
        line.append(UInt8(ascii: "\n"))
        let file = eventsFile(orgID: orgID, runID: runID)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: file, options: .atomic)
        }
    }

    /// Читает события запуска с карантином (3A): обрезанная ХВОСТОВАЯ
    /// строка отбрасывается (запись не случилась — краш посреди append);
    /// битая строка в СЕРЕДИНЕ — запуск broken (история недостоверна).
    /// Крашлуп на битой записи невозможен по построению.
    public func load(orgID: UUID, runID: UUID) -> LoadedRun {
        let file = eventsFile(orgID: orgID, runID: runID)
        guard let data = try? Data(contentsOf: file) else {
            return .broken(reason: "events.jsonl не читается")
        }
        let decoder = JSONDecoder()
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        var events: [RunEvent] = []
        for (index, line) in lines.enumerated() {
            if let event = try? decoder.decode(RunEvent.self, from: line) {
                events.append(event)
            } else if index == lines.count - 1 {
                break // обрезанный хвост — отбрасываем молча
            } else {
                return .broken(reason: "битая запись №\(index + 1) в середине журнала")
            }
        }
        return .events(events)
    }

    /// Организации, у которых есть запуски в хранилище, — вход
    /// recovery демона после рестарта (каталоги `runs/<orgID>`).
    public func listOrgIDs() -> [UUID] {
        let runsDir = root.appendingPathComponent("runs")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: runsDir.path) else {
            return []
        }
        return names.compactMap(UUID.init(uuidString:))
    }

    /// Все запуски организации; нечитаемый каталог не роняет остальные.
    public func listRuns(orgID: UUID) -> [UUID: LoadedRun] {
        let orgDir = root.appendingPathComponent("runs").appendingPathComponent(orgID.uuidString)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: orgDir.path) else {
            return [:]
        }
        var result: [UUID: LoadedRun] = [:]
        for name in names {
            guard let runID = UUID(uuidString: name) else { continue }
            result[runID] = load(orgID: orgID, runID: runID)
        }
        return result
    }

    // MARK: Восстановление

    /// Последнее состояние запуска: последний слепок из журнала.
    /// nil — слепков нет (журнал начат и оборван до первого snapshot).
    public static func restoreRun(from events: [RunEvent]) -> OrganizationRun? {
        events.reversed().first(where: { $0.kindValue == .snapshot })?.run
    }

    /// PID процессов, порождённых после последнего слепка, — кандидаты
    /// в осиротевшие: демон убивает их ДО пересоздания worktree (П0).
    public static func orphanPIDs(in events: [RunEvent]) -> [Int] {
        events.compactMap { $0.kindValue == .processSpawned ? $0.pid : nil }
    }

    /// Незавершённые намерения (T2): intent без effectConfirmed с тем же
    /// ключом. Recovery сверяет ФАКТ (ветка влита? комментарий есть?)
    /// прежде чем повторять эффект.
    public static func pendingIntents(in events: [RunEvent]) -> [String] {
        var pending: [String] = []
        for event in events {
            switch event.kindValue {
            case .intent:
                if let key = event.intentKey { pending.append(key) }
            case .effectConfirmed:
                if let key = event.intentKey { pending.removeAll { $0 == key } }
            default:
                break
            }
        }
        return pending
    }

    /// Саммари всех терминальных запусков организации — вход реконсиляции
    /// документа. Broken-каталог тоже саммари (outcome .broken) — задача
    /// не исчезает молча.
    public func summaries(orgID: UUID) -> [RunSummary] {
        listRuns(orgID: orgID).compactMap { runID, loaded in
            switch loaded {
            case let .events(events):
                guard let run = Self.restoreRun(from: events) else { return nil }
                return run.summary
            case .broken:
                return RunSummary(
                    runID: runID,
                    taskTitle: "Запуск повреждён",
                    outcome: .broken,
                    startedAt: Date(timeIntervalSince1970: 0),
                    finishedAt: Date(timeIntervalSince1970: 0)
                )
            }
        }
    }
}
