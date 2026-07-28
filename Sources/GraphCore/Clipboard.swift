import Foundation

/// Кусок графа в буфере обмена: работы выделенного поддерева, связи
/// между ними и место, откуда их взяли — уровень (id + номер) и область.
///
/// Не `WorkGraph`: подграф теряет номера уровней (пустые отбрасываются),
/// а вставке нужно знать, на какую полосу лечь. Формат самодостаточен —
/// в буфер он кладётся и как своя разновидность данных, и как JSON-текст,
/// поэтому переживает копирование между окнами и проектами.
public struct JobClipboard: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileType = "petable.jobs"

    /// Работы одного уровня-источника.
    public struct Level: Codable, Equatable, Sendable {
        /// id уровня-источника: вставка в тот же граф ложится точно
        /// на свою полосу, даже если уровни переставляли.
        public var id: UUID
        /// Номер уровня в исходном графе — запасной путь для вставки
        /// в другой граф, где уровня с таким id нет.
        public var index: Int
        public var jobs: [JobNode]
        /// Области, в которых лежали скопированные работы.
        public var zones: [LevelZone]

        public init(id: UUID, index: Int, jobs: [JobNode], zones: [LevelZone] = []) {
            self.id = id
            self.index = index
            self.jobs = jobs
            self.zones = zones
        }
    }

    public var version: Int
    public var type: String
    public var levels: [Level]
    public var edges: [JobEdge]

    public init(levels: [Level], edges: [JobEdge]) {
        self.version = Self.currentVersion
        self.type = Self.fileType
        self.levels = levels
        self.edges = edges
    }

    public var isEmpty: Bool { levels.allSatisfy(\.jobs.isEmpty) }

    public var jobCount: Int { levels.reduce(0) { $0 + $1.jobs.count } }

    public func encoded() throws -> Data {
        try ExportCoding.makeEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> JobClipboard {
        try ExportCoding.validateHeader(data, expectedType: fileType, supportedVersion: currentVersion)
        return try ExportCoding.makeDecoder().decode(JobClipboard.self, from: data)
    }
}

public extension WorkGraph {
    /// Снимок выделенных работ для буфера обмена: работы по уровням,
    /// связи только между выделенными, области — только те, в которых
    /// эти работы лежат.
    ///
    /// Свёрнутость головы снимается, если её цепочка не попала в выделение:
    /// вставленная работа со свёрнутой пустотой была бы невидимой пылью
    /// в файле (тот же инвариант, что у `.setCollapsed`).
    func clipboard(keeping ids: Set<UUID>) -> JobClipboard {
        let levels = self.levels.enumerated().compactMap { index, level -> JobClipboard.Level? in
            let jobs = level.jobs
                .filter { ids.contains($0.id) }
                .map { job -> JobNode in
                    var copy = job
                    if copy.isCollapsed,
                       !chainSuccessors(of: job.id).contains(where: { ids.contains($0) }) {
                        copy.isCollapsed = false
                    }
                    return copy
                }
            guard !jobs.isEmpty else { return nil }
            return JobClipboard.Level(
                id: level.id,
                index: index,
                jobs: jobs,
                zones: level.zones.filter { zone in jobs.contains { $0.zoneID == zone.id } }
            )
        }
        let edges = self.edges.filter { ids.contains($0.from) && ids.contains($0.to) }
        return JobClipboard(levels: levels, edges: edges)
    }
}
