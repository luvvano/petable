import SwiftUI

/// Ребро графа — отдельный Shape с animatableData, НЕ Canvas:
/// Canvas не участвует в withAnimation, линии телепортировались бы,
/// пока круги плавно едут. Shape интерполируется тем же spring.
struct EdgeShape: Shape {
    var from: CGPoint
    var to: CGPoint

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
        path.addLine(to: to)
        return path
    }
}
