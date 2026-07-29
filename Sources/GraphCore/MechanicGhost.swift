import Foundation

/// Слой призрака: объединённый граф и дельта для строки над канвасом.
///
/// Почему объединённый граф (P2a): `GraphLayout.geometry` в конце сдвигает
/// ВСЕ позиции, приводя левый край к колонке x = 0. У `geometry(current)`
/// и `geometry(preview)` разные глобальные смещения — фантом удалённого
/// узла, нарисованный по «своей» геометрии, встал бы не туда и читался бы
/// как новый узел. Union раскладывается ОДИН раз, и по этой геометрии
/// рисуются и выжившие, и фантомы: сдвиг один на всех.
public enum MechanicGhost {
    /// Что случилось с работой в превью — определяет стиль отрисовки.
    public enum JobFate: Equatable, Sendable {
        /// Есть в обоих графах, без изменений полей.
        case unchanged
        /// Есть в обоих, но изменилась (глагол, роль, области, карточка).
        case changed
        /// Есть только в превью — новая (вставка в разрыв).
        case added
        /// Есть только в текущем — фантом: приглушить и перечеркнуть.
        case removed
    }

    public struct Overlay: Equatable, Sendable {
        /// Синтетический граф для ОДНОЙ раскладки. Никогда не сохраняется
        /// и не редактируется — существует только ради координат.
        public let union: WorkGraph
        /// Судьба каждой работы union-графа.
        public let fates: [UUID: JobFate]
        /// Рёбра, которых нет в превью, — рисуются приглушённо.
        public let removedEdges: Set<JobEdge>
        /// Рёбра, появившиеся в превью, — рисуются пунктиром.
        public let addedEdges: Set<JobEdge>
    }

    /// Собирает слой призрака из текущего графа и превью механики.
    public static func overlay(current: WorkGraph, preview: WorkGraph) -> Overlay {
        let currentJobs = jobsByID(current)
        let previewJobs = jobsByID(preview)

        // Union строится ОТ превью (оно авторитетно для выживших и новых),
        // затем удалённые работы возвращаются на свои места — после
        // ближайшего выжившего соседа слева в порядке текущего графа.
        var union = preview
        var fates: [UUID: JobFate] = [:]

        for (id, job) in previewJobs {
            if let old = currentJobs[id] {
                if job.killed, !old.killed {
                    // Работа убита превью: рисуется перечёркнутой — тот же
                    // вид, что у неё будет после применения (v13: узел
                    // остаётся на графе).
                    fates[id] = .removed
                } else {
                    fates[id] = old == job ? .unchanged : .changed
                }
            } else {
                fates[id] = .added
            }
        }

        for (levelIndex, level) in current.levels.enumerated() {
            for (jobIndex, job) in level.jobs.enumerated() where previewJobs[job.id] == nil {
                fates[job.id] = .removed
                insert(
                    phantom: job,
                    fromLevel: level,
                    at: jobIndex,
                    into: &union,
                    fallbackLevelIndex: levelIndex
                )
            }
        }

        let currentEdges = Set(current.edges)
        let previewEdges = Set(preview.edges)
        let removedEdges = currentEdges.subtracting(previewEdges)

        // Рёбра фантомов возвращаются в union, иначе фантом висит без
        // линий и непонятно, откуда он выпал.
        union.edges.append(contentsOf: removedEdges.filter { edge in
            !union.edges.contains(edge)
        })

        return Overlay(
            union: union,
            fates: fates,
            removedEdges: removedEdges,
            addedEdges: previewEdges.subtracting(currentEdges)
        )
    }

    /// Вставляет фантом в union: тот же уровень (по id, с запасным
    /// вариантом по индексу), позиция — после ближайшего выжившего
    /// соседа слева из порядка текущего графа.
    private static func insert(
        phantom: JobNode,
        fromLevel level: GraphLevel,
        at originalIndex: Int,
        into union: inout WorkGraph,
        fallbackLevelIndex: Int
    ) {
        let targetLevelIndex = union.levels.firstIndex { $0.id == level.id }
            ?? min(fallbackLevelIndex, max(union.levels.count - 1, 0))
        guard union.levels.indices.contains(targetLevelIndex) else { return }

        // Фантом области, которой в превью больше нет, уезжает в основную
        // область: рамки нет, рисовать «внутри неё» нечего.
        var phantom = phantom
        if let zoneID = phantom.zoneID,
           !union.levels[targetLevelIndex].zones.contains(where: { $0.id == zoneID }) {
            phantom.zoneID = nil
        }

        let unionJobs = union.levels[targetLevelIndex].jobs
        let leftNeighbors = level.jobs.prefix(originalIndex).reversed()
        let anchorIndex = leftNeighbors
            .compactMap { neighbor in unionJobs.firstIndex { $0.id == neighbor.id } }
            .first
        // Нет выжившего соседа слева — фантом был самым левым: в начало,
        // а не в конец, иначе все выжившие сдвинутся на колонку.
        let insertAt = anchorIndex.map { $0 + 1 } ?? 0
        union.levels[targetLevelIndex].jobs.insert(phantom, at: min(insertAt, unionJobs.count))
    }

    private static func jobsByID(_ graph: WorkGraph) -> [UUID: JobNode] {
        var result: [UUID: JobNode] = [:]
        for level in graph.levels {
            for job in level.jobs { result[job.id] = job }
        }
        return result
    }
}

// MARK: - Дельта

public extension WorkGraph {
    /// Сводка изменений между графами — строка над канвасом при живом
    /// призраке. Живёт в ядре, а не во вьюхе: чистая функция двух графов,
    /// тестируется без UI (прецедент — SegmentVerdict.title).
    struct Delta: Equatable, Sendable {
        public let jobsAdded: Int
        public let jobsRemoved: Int
        public let edgesAdded: Int
        public let edgesRemoved: Int
        public let zonesRemoved: Int
        /// Работы, у которых снялся zoneID: «переехали в кóровые».
        public let jobsMovedToCore: Int

        public var isEmpty: Bool {
            jobsAdded == 0 && jobsRemoved == 0 && edgesAdded == 0
                && edgesRemoved == 0 && zonesRemoved == 0 && jobsMovedToCore == 0
        }

        /// «−1 работа · −1 связь» / «область снята · 3 работы в кóровых».
        /// Только реально случившееся — больших чисел набор механик не
        /// даёт, и строка обязана быть точной, а не эффектной.
        public var summary: String {
            var parts: [String] = []
            if jobsRemoved > 0 { parts.append("−\(jobsRemoved) \(jobsWord(jobsRemoved))") }
            if jobsAdded > 0 { parts.append("+\(jobsAdded) \(jobsWord(jobsAdded))") }
            if zonesRemoved > 0 {
                parts.append(zonesRemoved == 1 ? "область снята" : "области сняты (\(zonesRemoved))")
            }
            if jobsMovedToCore > 0 {
                parts.append("\(jobsMovedToCore) \(jobsWord(jobsMovedToCore)) в кóровых")
            }
            if edgesRemoved > 0 { parts.append("−\(edgesRemoved) \(edgesWord(edgesRemoved))") }
            if edgesAdded > 0 { parts.append("+\(edgesAdded) \(edgesWord(edgesAdded))") }
            return parts.joined(separator: " · ")
        }

        private func jobsWord(_ count: Int) -> String {
            switch count % 100 {
            case 11...14: return "работ"
            default:
                switch count % 10 {
                case 1: return "работа"
                case 2...4: return "работы"
                default: return "работ"
                }
            }
        }

        private func edgesWord(_ count: Int) -> String {
            switch count % 100 {
            case 11...14: return "связей"
            default:
                switch count % 10 {
                case 1: return "связь"
                case 2...4: return "связи"
                default: return "связей"
                }
            }
        }
    }

    /// Дельта от self к `other` (превью механики).
    func delta(to other: WorkGraph) -> Delta {
        let selfJobs = Dictionary(
            uniqueKeysWithValues: levels.flatMap(\.jobs).map { ($0.id, $0) }
        )
        let otherJobs = Dictionary(
            uniqueKeysWithValues: other.levels.flatMap(\.jobs).map { ($0.id, $0) }
        )
        let selfEdges = Set(edges)
        let otherEdges = Set(other.edges)
        let selfZones = Set(levels.flatMap(\.zones).map(\.id))
        let otherZones = Set(other.levels.flatMap(\.zones).map(\.id))

        let movedToCore = selfJobs.values.count { job in
            job.zoneID != nil && otherJobs[job.id]?.zoneID == nil
        }
        // Убитая работа (v13) не удаляется из графа, но для дельты это
        // «−1 работа»: живых работ стало меньше.
        let killed = selfJobs.values.count { job in
            !job.killed && otherJobs[job.id]?.killed == true
        }

        return Delta(
            jobsAdded: otherJobs.keys.filter { selfJobs[$0] == nil }.count,
            jobsRemoved: selfJobs.keys.filter { otherJobs[$0] == nil }.count + killed,
            edgesAdded: otherEdges.subtracting(selfEdges).count,
            edgesRemoved: selfEdges.subtracting(otherEdges).count,
            zonesRemoved: selfZones.subtracting(otherZones).count,
            jobsMovedToCore: movedToCore
        )
    }
}
