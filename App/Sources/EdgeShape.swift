import SwiftUI

/// Ребро графа — отдельный Shape с animatableData, НЕ Canvas:
/// Canvas не участвует в withAnimation, линии телепортировались бы,
/// пока круги плавно едут. Shape интерполируется тем же spring.
///
/// `vertical` — связь на уровень ниже (S-кривая сверху вниз),
/// иначе связь внутри уровня (горизонтальная кривая слева направо).
struct EdgeShape: Shape {
    var from: CGPoint
    var to: CGPoint
    var vertical: Bool

    var animatableData: AnimatablePair<CGPoint.AnimatableData, CGPoint.AnimatableData> {
        get { AnimatablePair(from.animatableData, to.animatableData) }
        set {
            from.animatableData = newValue.first
            to.animatableData = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: from)
        if vertical {
            let midY = (from.y + to.y) / 2
            path.addCurve(
                to: to,
                control1: CGPoint(x: from.x, y: midY),
                control2: CGPoint(x: to.x, y: midY)
            )
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
