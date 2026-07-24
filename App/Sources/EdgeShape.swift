import SwiftUI

/// Ребро графа — отдельный Shape с animatableData, НЕ Canvas:
/// Canvas не участвует в withAnimation, линии телепортировались бы,
/// пока круги плавно едут. Shape интерполируется тем же spring.
///
/// `vertical` — связь на уровень ниже (S-кривая сверху вниз),
/// иначе связь внутри уровня (горизонтальная кривая слева направо).
///
/// `waypoints` — обходные точки для связи через 2+ уровня: линия проходит
/// через них, огибая узлы промежуточных уровней. В каждой точке касательная
/// вертикальна, поэтому стыки сегментов гладкие.
struct EdgeShape: Shape {
    var from: CGPoint
    var to: CGPoint
    var vertical: Bool
    var waypoints: [CGPoint] = []

    var animatableData: AnimatablePair<AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData>, WaypointVector> {
        get {
            AnimatablePair(
                AnimatablePair(from.animatableData, to.animatableData),
                WaypointVector(values: waypoints.flatMap { [Double($0.x), Double($0.y)] })
            )
        }
        set {
            from.animatableData = newValue.first.first
            to.animatableData = newValue.first.second
            let values = newValue.second.values
            waypoints = stride(from: 0, to: values.count - 1, by: 2).map {
                CGPoint(x: values[$0], y: values[$0 + 1])
            }
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        if vertical {
            var previous = from
            for point in waypoints + [to] {
                let midY = (previous.y + point.y) / 2
                path.addCurve(
                    to: point,
                    control1: CGPoint(x: previous.x, y: midY),
                    control2: CGPoint(x: point.x, y: midY)
                )
                previous = point
            }
        } else {
            let midX = (from.x + to.x) / 2
            path.addCurve(
                to: to,
                control1: CGPoint(x: midX, y: from.y),
                control2: CGPoint(x: midX, y: to.y)
            )
        }
        return path
    }
}

/// Плоский вектор координат обходных точек — участвует в анимации ребра
/// наравне с концами. При смене числа точек (структурная правка графа)
/// короткий вектор дополняется нулями и интерполяция вырождается в скачок —
/// редкий случай, совпадающий с перестройкой самого графа.
struct WaypointVector: VectorArithmetic {
    var values: [Double]

    static var zero: WaypointVector { WaypointVector(values: []) }

    static func + (lhs: WaypointVector, rhs: WaypointVector) -> WaypointVector {
        merge(lhs, rhs, +)
    }

    static func - (lhs: WaypointVector, rhs: WaypointVector) -> WaypointVector {
        merge(lhs, rhs, -)
    }

    private static func merge(
        _ lhs: WaypointVector, _ rhs: WaypointVector, _ op: (Double, Double) -> Double
    ) -> WaypointVector {
        let count = max(lhs.values.count, rhs.values.count)
        var result = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let a = index < lhs.values.count ? lhs.values[index] : 0
            let b = index < rhs.values.count ? rhs.values[index] : 0
            result[index] = op(a, b)
        }
        return WaypointVector(values: result)
    }

    mutating func scale(by rhs: Double) {
        values = values.map { $0 * rhs }
    }

    var magnitudeSquared: Double {
        values.reduce(0) { $0 + $1 * $1 }
    }
}
