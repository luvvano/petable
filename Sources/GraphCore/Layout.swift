import Foundation
import CoreGraphics

/// Автораскладка по уровням-полосам. Чистая функция: граф → позиции центров.
/// y = индекс уровня × rowHeight. Внутри уровня работы идут слева направо
/// в порядке массива jobs; связанная работа тянется к источнику:
/// под родителя (связь с уровня выше) или сразу справа (связь в уровне).
/// Перетаскивание работы мышью меняет порядок и уровень в модели, а не
/// координаты: эта функция остаётся единственным источником позиций,
/// анимация перекладки — withAnimation вокруг мутации.
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
    /// слева направо: сначала основная (её выполняет продукт), затем зоны.
    /// Следующая область начинается от ПРАВОГО КРАЯ занятого места
    /// (колонки последней работы или рамки предыдущей области) плюс
    /// `zoneGap` — новая область всегда встаёт рядом справа и никогда
    /// не наезжает на соседнюю рамку.
    public static func geometry(_ graph: WorkGraph) -> Geometry {
        var positions: [UUID: CGPoint] = [:]
        var zones: [UUID: ZoneSpan] = [:]
        let distance = LayoutMetrics.columnWidth
        let half = distance / 2
        // Работы свёрнутых цепочек места на полосе не занимают: позиции
        // у них нет вовсе — канвас и PNG рисуют только то, что в `positions`.
        let hidden = graph.hiddenJobs()

        for (levelIndex, level) in graph.levels.enumerated() {
            let y = CGFloat(levelIndex) * LayoutMetrics.rowHeight
            // Правый край занятого места на полосе: колонка работы или
            // рамка области. Первая колонка уровня начинается с x = 0,
            // то есть её левый край — на -half.
            var occupiedRight: CGFloat = -half

            for (groupIndex, groupID) in level.groupIDs.enumerated() {
                let groupJobs = level.jobs(in: groupID).filter { !hidden.contains($0.id) }
                // Рамка области резервирует padding по обе стороны;
                // у основной области рамки нет.
                let inset = groupID == nil ? 0 : LayoutMetrics.zonePadding
                let groupLeft = occupiedRight + (groupIndex > 0 ? LayoutMetrics.zoneGap : 0)

                guard !groupJobs.isEmpty else {
                    // Пустая область резервирует место под свою рамку.
                    if let groupID {
                        let maxX = groupLeft + LayoutMetrics.emptyZoneWidth
                        zones[groupID] = ZoneSpan(levelIndex: levelIndex, minX: groupLeft, maxX: maxX)
                        occupiedRight = maxX
                    }
                    continue
                }

                // Виртуальная колонка слева от группы: первая работа встаёт
                // ровно на groupLeft + inset + half.
                var previousX = groupLeft + inset + half - distance
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
                    occupiedRight = maxX
                } else {
                    occupiedRight = previousX + half
                }
            }
        }

        // Нормализация: левый край занятого места (колонка работы или
        // рамка области) встаёт туда же, где была бы колонка работы
        // с x = 0. Иначе рамка левее самой левой работы уезжает за кромку.
        let leftEdges = positions.values.map { $0.x - half } + zones.values.map(\.minX)
        if let left = leftEdges.min(), left != -half {
            let shift = left + half
            for (key, point) in positions {
                positions[key] = CGPoint(x: point.x - shift, y: point.y)
            }
            for (key, span) in zones {
                zones[key] = ZoneSpan(
                    levelIndex: span.levelIndex,
                    minX: span.minX - shift,
                    maxX: span.maxX - shift
                )
            }
        }
        return Geometry(positions: positions, zones: zones)
    }

    /// Куда попадает точка канваса: уровень, область внутри него и позиция
    /// в этой области. Одна семантика на два жеста — отпускание работы
    /// (интент `move`) и двойной клик по пустому месту (интент `addJob`).
    public struct DropTarget: Equatable, Sendable {
        public let levelIndex: Int
        /// Область под точкой; nil — основная область уровня.
        public let zoneID: UUID?
        /// Позиция внутри области: сколько её работ левее точки.
        public let index: Int

        public init(levelIndex: Int, zoneID: UUID?, index: Int) {
            self.levelIndex = levelIndex
            self.zoneID = zoneID
            self.index = index
        }
    }

    /// Уровень — по y (полоса под точкой, за краями графа — крайняя),
    /// область — по рамке под точкой (рамки нет — основная область),
    /// позиция — по x среди работ этой области.
    ///
    /// `point` — в координатах раскладки (те же, что `positions`).
    /// `bandOffset` — насколько центр узла ниже верхней кромки полосы
    /// (метрика канваса). `excluding` — работа, которую сейчас тащат:
    /// она не считается соседкой сама себе.
    public static func dropTarget(
        graph: WorkGraph,
        geometry: Geometry,
        at point: CGPoint,
        bandOffset: CGFloat,
        excluding: UUID? = nil
    ) -> DropTarget? {
        guard !graph.levels.isEmpty else { return nil }
        let raw = Int(((point.y + bandOffset) / LayoutMetrics.rowHeight).rounded(.down))
        let levelIndex = min(max(raw, 0), graph.levels.count - 1)
        let level = graph.levels[levelIndex]
        let zoneID = level.zones.first { zone in
            guard let span = geometry.zones[zone.id] else { return false }
            return point.x >= span.minX && point.x <= span.maxX
        }?.id
        // Индекс — место в массиве работ области, а не номер среди
        // видимых: работы свёрнутой цепочки из модели не исчезают.
        // Вставка встаёт за последней видимой работой левее точки
        // и перешагивает её скрытый «хвост» — внутрь свёрнутой цепочки
        // работа не проваливается.
        let groupJobs = level.jobs(in: zoneID).filter { $0.id != excluding }
        var index = 0
        for (position, job) in groupJobs.enumerated() {
            guard let x = geometry.positions[job.id]?.x, x < point.x else { continue }
            index = position + 1
        }
        while index < groupJobs.count, geometry.positions[groupJobs[index].id] == nil {
            index += 1
        }
        return DropTarget(levelIndex: levelIndex, zoneID: zoneID, index: index)
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
            let clearance = graph.style(atLevel: levelIndex).diameter / 2 + 24
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
