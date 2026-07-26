import SwiftUI
import GraphCore

/// Статичный рендер графа работ для экспорта в PNG: та же геометрия
/// и стили, что на канвасе (полосы, рёбра с обходами, круги, подписи),
/// но без интерактива — контролов, ховеров, выделений и сетки.
/// Размер задаёт сам контент; рендерится офскрин через ImageRenderer.
struct GraphSnapshotView: View {
    let graph: WorkGraph

    // Константы канваса (CanvasRootView) — картинка совпадает с экраном.
    private let contentPadding: CGFloat = 90
    private let bandInset: CGFloat = 24
    private let nodeOffsetInBand: CGFloat = 50
    private var bandHeight: CGFloat { LayoutMetrics.rowHeight - 10 }

    var body: some View {
        let positions = GraphLayout.layout(graph)
        let size = contentSize(positions)

        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)

            ForEach(Array(graph.levels.enumerated()), id: \.element.id) { index, level in
                band(index: index, level: level, width: size.width)
            }

            ForEach(graph.edges, id: \.self) { edge in
                edgeView(edge, positions: positions)
            }

            ForEach(Array(graph.levels.enumerated()), id: \.element.id) { levelIndex, level in
                ForEach(level.jobs) { job in
                    nodeView(job, level: levelIndex, at: point(positions[job.id]))
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: Геометрия

    private func point(_ position: CGPoint?) -> CGPoint {
        guard let position else { return .zero }
        return CGPoint(x: position.x + contentPadding, y: position.y + contentPadding)
    }

    private func bandTop(_ index: Int) -> CGFloat {
        contentPadding + CGFloat(index) * LayoutMetrics.rowHeight - nodeOffsetInBand
    }

    private func contentSize(_ positions: [UUID: CGPoint]) -> CGSize {
        let maxX = (positions.values.map(\.x).max() ?? 0) + contentPadding * 2
        let bottom = bandTop(max(graph.levels.count - 1, 0)) + bandHeight + contentPadding - nodeOffsetInBand
        return CGSize(width: max(maxX, 600), height: max(bottom, 400))
    }

    // MARK: Полосы

    @ViewBuilder
    private func band(index: Int, level: GraphLevel, width: CGFloat) -> some View {
        let top = bandTop(index)

        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LevelColors.fill(for: index).opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(LevelColors.stroke(for: index).opacity(0.18), lineWidth: 1)
            )
            .frame(width: width - bandInset * 2, height: bandHeight)
            .offset(x: bandInset, y: top)

        Text(level.name?.uppercased() ?? (level.isCore ? "CORE JOBS" : "УРОВЕНЬ \(index + 1)"))
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(1.4)
            .foregroundStyle(LevelColors.stroke(for: index).opacity(0.65))
            .lineLimit(1)
            .fixedSize()
            .rotationEffect(.degrees(-90))
            .position(x: bandInset - 12, y: top + bandHeight / 2)
    }

    // MARK: Рёбра

    @ViewBuilder
    private func edgeView(_ edge: JobEdge, positions: [UUID: CGPoint]) -> some View {
        if let fromLevel = graph.levelIndex(of: edge.from),
           let toLevel = graph.levelIndex(of: edge.to) {
            let from = point(positions[edge.from])
            let to = point(positions[edge.to])
            let fromR = LevelStyle.style(for: fromLevel).diameter / 2
            let toR = LevelStyle.style(for: toLevel).diameter / 2
            let vertical = fromLevel != toLevel
            let sign: CGFloat = to.x >= from.x ? 1 : -1
            let start = vertical
                ? CGPoint(x: from.x, y: from.y + (toLevel > fromLevel ? fromR : -fromR))
                : CGPoint(x: from.x + sign * fromR, y: from.y)
            let end = vertical
                ? CGPoint(x: to.x, y: to.y - (toLevel > fromLevel ? toR + 3 : -(toR + 3)))
                : CGPoint(x: to.x - sign * (toR + 3), y: to.y)
            let waypoints = vertical
                ? GraphLayout.detourWaypoints(
                    graph: graph, positions: positions,
                    start: start, end: end,
                    fromLevel: fromLevel, toLevel: toLevel,
                    padding: contentPadding
                )
                : []

            EdgeShape(from: start, to: end, vertical: vertical, waypoints: waypoints)
                .stroke(
                    Color.gray.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                )
        }
    }

    // MARK: Узлы

    @ViewBuilder
    private func nodeView(_ job: JobNode, level: Int, at position: CGPoint) -> some View {
        let diameter = LevelStyle.style(for: level).diameter

        Circle()
            .fill(LevelColors.fill(for: level))
            .overlay(Circle().strokeBorder(LevelColors.stroke(for: level), lineWidth: 2))
            .shadow(color: .black.opacity(0.16), radius: 3, y: 1.5)
            .frame(width: diameter, height: diameter)
            .position(position)

        VStack(spacing: 0) {
            if let role = job.role {
                Text("\(role):")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(job.verb)
                .font(.system(size: level == 0 ? 12 : 11, weight: level == 0 ? .semibold : .regular))
                .lineLimit(job.role == nil ? 3 : 2)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
        }
        .frame(width: LayoutMetrics.columnWidth - 6)
        .position(x: position.x, y: position.y + diameter / 2 + 32)
    }
}
