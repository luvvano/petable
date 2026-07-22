import Foundation
import CoreGraphics

/// Автораскладка по уровням-полосам. Чистая функция: граф → позиции центров.
/// y = индекс уровня × rowHeight. Внутри уровня работы идут слева направо
/// в порядке массива jobs; связанная работа тянется к источнику:
/// под родителя (связь с уровня выше) или сразу справа (связь в уровне).
/// Ручного перетаскивания в продукте нет — эта функция единственный
/// источник позиций; анимация перекладки — withAnimation вокруг мутации.
public enum GraphLayout {
    public static func layout(_ graph: WorkGraph) -> [UUID: CGPoint] {
        var positions: [UUID: CGPoint] = [:]
        let distance = LayoutMetrics.columnWidth

        for (levelIndex, level) in graph.levels.enumerated() {
            let y = CGFloat(levelIndex) * LayoutMetrics.rowHeight
            var previousX: CGFloat = -distance

            for job in level.jobs {
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
        }

        // Нормализация: минимальный x = 0.
        if let minX = positions.values.map(\.x).min(), minX != 0 {
            for (key, point) in positions {
                positions[key] = CGPoint(x: point.x - minX, y: point.y)
            }
        }
        return positions
    }
}
