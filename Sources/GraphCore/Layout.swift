import Foundation
import CoreGraphics

/// Автораскладка по уровням-полосам. Чистая функция: граф → позиции центров.
/// y = индекс уровня × rowHeight. Внутри уровня работы идут слева направо
/// в порядке массива jobs; связанная работа тянется к источнику:
/// под родителя (связь с уровня выше) или сразу справа (связь в уровне).
/// Ручного перетаскивания в продукте нет — эта функция единственный
/// источник позиций; анимация перекладки — withAnimation вокруг мутации.
public enum GraphLayout {
    /// Горизонтальные границы области уровня в координатах раскладки —
    /// рамка, которую рисуют канвас и PNG-снапшот.
    public struct ZoneSpan: Equatable, Sendable {
        public let levelIndex: Int
        public let minX: CGFloat
        public let maxX: CGFloat

        public init(levelIndex: Int, minX: CGFloat, maxX: CGFloat) {
            self.levelIndex = levelIndex
            self.minX = minX
            self.maxX = maxX
        }

        public var width: CGFloat { maxX - minX }
        public var midX: CGFloat { (minX + maxX) / 2 }
    }

    /// Результат раскладки: центры работ + рамки областей уровней.
    public struct Geometry: Equatable, Sendable {
        public var positions: [UUID: CGPoint]
        public var zones: [UUID: ZoneSpan]

        public init(positions: [UUID: CGPoint] = [:], zones: [UUID: ZoneSpan] = [:]) {
            self.positions = positions
            self.zones = zones
        }
    }

    public static func layout(_ graph: WorkGraph) -> [UUID: CGPoint] {
        geometry(graph).positions
    }

    /// Полная геометрия графа. Работы уровня раскладываются по областям
    /// слева направо: сначала основная (её выполняет продукт), затем зоны
    /// через зазор `zoneGap` — рамки не слипаются, и видно, что уровень
    /// тот же, а область другая.
    public static func geometry(_ graph: WorkGraph) -> Geometry {
        var positions: [UUID: CGPoint] = [:]
        var zones: [UUID: ZoneSpan] = [:]
        let distance = LayoutMetrics.columnWidth
        let half = distance / 2

        for (levelIndex, level) in graph.levels.enumerated() {
            let y = CGFloat(levelIndex) * LayoutMetrics.rowHeight
            var previousX: CGFloat = -distance

            for (groupIndex, groupID) in level.groupIDs.enumerated() {
                if groupIndex > 0 { previousX += LayoutMetrics.zoneGap }
                let groupJobs = level.jobs(in: groupID)

                guard !groupJobs.isEmpty else {
                    // Пустая область резервирует место под свою рамку.
                    if let groupID {
                        let minX = previousX + distance - half
                        let maxX = minX + LayoutMetrics.emptyZoneWidth
                        zones[groupID] = ZoneSpan(levelIndex: levelIndex, minX: minX, maxX: maxX)
                        previousX = maxX - half
                    }
                    continue
                }

                for job in groupJobs {
                    var desired: [CGFloat] = []
                    for sourceID in graph.sources(of: job.id) {
                        guard let sourcePoint = positions[sourceID] else { continue }
                        if graph.levelIndex(of: sourceID) == levelIndex {
                            // Источник в этом же уровне — новая работа справа от него.
                            desired.append(sourcePoint.x + distance)
                        } else {
                            // Источник выше — выравнивание под родителем.
                            desired.append(sourcePoint.x)
                        }
                    }
                    let target = desired.isEmpty ? 0 : desired.reduce(0, +) / CGFloat(desired.count)
                    let x = max(target, previousX + distance)
                    positions[job.id] = CGPoint(x: x, y: y)
                    previousX = x
                }

                if let groupID {
                    let xs = groupJobs.compactMap { positions[$0.id]?.x }
                    let minX = (xs.min() ?? 0) - half - LayoutMetrics.zonePadding
                    let maxX = (xs.max() ?? 0) + half + LayoutMetrics.zonePadding
                    zones[groupID] = ZoneSpan(levelIndex: levelIndex, minX: minX, maxX: maxX)
                }
            }
        }

        // Нормализация: минимальный x работ = 0 (рамки едут вместе с ними).
        if let minX = positions.values.map(\.x).min(), minX != 0 {
            for (key, point) in positions {
                positions[key] = CGPoint(x: point.x - minX, y: point.y)
            }
            for (key, span) in zones {
                zones[key] = ZoneSpan(
                    levelIndex: span.levelIndex,
                    minX: span.minX - minX,
                    maxX: span.maxX - minX
                )
            }
        }
        return Geometry(positions: positions, zones: zones)
    }

    /// Обходные точки для связи через 2+ уровня: без них S-кривая проходит
    /// сквозь полосу промежуточного уровня рядом с чужим узлом и читается
    /// как связь через него. Линия сразу спускается в колонку целевой
    /// работы, а узлы промежуточных уровней огибает сбоку — со стороны
    /// начала связи, чтобы обход читался как продолжение линии.
    ///
    /// `start`/`end` — концы ребра в координатах вида; `padding` — сдвиг
    /// раскладки относительно этих координат (positions + padding = вид).
    public static func detourWaypoints(
        graph: WorkGraph,
        positions: [UUID: CGPoint],
        start: CGPoint, end: CGPoint,
        fromLevel: Int, toLevel: Int,
        padding: CGFloat
    ) -> [CGPoint] {
        let lower = min(fromLevel, toLevel)
        let upper = max(fromLevel, toLevel)
        guard upper - lower >= 2 else { return [] }
        let between = Array((lower + 1)...(upper - 1))
        let ordered = fromLevel < toLevel ? between : between.reversed()

        var result: [CGPoint] = []
        for levelIndex in ordered {
            guard levelIndex < graph.levels.count else { continue }
            let y = padding + CGFloat(levelIndex) * LayoutMetrics.rowHeight
            let clearance = LevelStyle.style(for: levelIndex).diameter / 2 + 24
            let nodeXs = graph.levels[levelIndex].jobs
                .compactMap { positions[$0.id]?.x }
                .map { $0 + padding }

            var x = end.x
            var iterations = 0
            while iterations < 6,
                  let blocking = nodeXs.first(where: { abs(x - $0) < clearance }) {
                x = blocking + (start.x <= blocking ? -clearance : clearance)
                iterations += 1
            }
            result.append(CGPoint(x: x, y: y))
        }
        return result
    }
}
