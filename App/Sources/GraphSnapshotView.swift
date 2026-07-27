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
    private let zoneInset: CGFloat = 7
    private var bandHeight: CGFloat { LayoutMetrics.rowHeight - 10 }

    var body: some View {
        let geometry = GraphLayout.geometry(graph)
        let positions = geometry.positions
        let size = contentSize(geometry)

        ZStack(alignment: .topLeading) {
            Color(nsColor: .windowBackgroundColor)

            ForEach(Array(graph.levels.enumerated()), id: \.element.id) { index, level in
                band(index: index, level: level, width: size.width)
            }

            // Области уровней — тот же ряд, отдельная пунктирная рамка.
            ForEach(Array(graph.levels.enumerated()), id: \.element.id) { index, level in
                ForEach(level.zones) { zone in
                    if let span = geometry.zones[zone.id] {
                        zoneBand(zone, span: span)
                    }
                }
            }

            ForEach(graph.edges, id: \.self) { edge in
                edgeView(edge, positions: positions)
            }

            // Работы свёрнутых цепочек позиции не имеют — картинка
            // повторяет канвас: их не видно, у головы стоит счётчик.
            ForEach(Array(graph.levels.enumerated()), id: \.element.id) { levelIndex, level in
                ForEach(level.jobs) { job in
                    if let position = positions[job.id] {
                        nodeView(job, level: levelIndex, at: point(position))
                    }
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

    private func contentSize(_ geometry: GraphLayout.Geometry) -> CGSize {
        let rightEdge = max(
            geometry.positions.values.map(\.x).max() ?? 0,
            geometry.zones.values.map(\.maxX).max() ?? 0
        )
        let maxX = rightEdge + contentPadding * 2
        let bottom = bandTop(max(graph.levels.count - 1, 0)) + bandHeight + contentPadding - nodeOffsetInBand
        return CGSize(width: max(maxX, 600), height: max(bottom, 400))
    }

    // MARK: Полосы

    @ViewBuilder
    private func band(index: Int, level: GraphLevel, width: CGFloat) -> some View {
        let top = bandTop(index)
        let style = graph.style(atLevel: index)

        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LevelColors.fill(style).opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(LevelColors.stroke(style).opacity(0.18), lineWidth: 1)
            )
            .frame(width: width - bandInset * 2, height: bandHeight)
            .offset(x: bandInset, y: top)

        Text(level.name?.uppercased() ?? (level.isCore ? "CORE JOBS" : "УРОВЕНЬ \(index + 1)"))
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(1.4)
            .foregroundStyle(LevelColors.stroke(graph.style(atLevel: index)).opacity(0.65))
            .lineLimit(1)
            .fixedSize()
            .rotationEffect(.degrees(-90))
            .position(x: bandInset - 12, y: top + bandHeight / 2)
    }

    /// Рамка области уровня + её имя — та же геометрия, что на канвасе.
    @ViewBuilder
    private func zoneBand(_ zone: LevelZone, span: GraphLayout.ZoneSpan) -> some View {
        let rect = CGRect(
            x: span.minX + contentPadding,
            y: bandTop(span.levelIndex) + zoneInset,
            width: span.width,
            height: bandHeight - zoneInset * 2
        )

        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(LevelColors.zoneFill.opacity(0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        LevelColors.zoneStroke.opacity(0.5),
                        style: StrokeStyle(lineWidth: 1.3, dash: [6, 5])
                    )
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)

        Text(zone.resolvedName.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(1.2)
            .foregroundStyle(LevelColors.zoneStroke.opacity(0.95))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(Capsule().strokeBorder(LevelColors.zoneStroke.opacity(0.35), lineWidth: 1))
            .frame(width: rect.width, alignment: .leading)
            .position(x: rect.midX, y: rect.minY)
    }

    // MARK: Рёбра

    @ViewBuilder
    private func edgeView(_ edge: JobEdge, positions: [UUID: CGPoint]) -> some View {
        // Конец в свёрнутой цепочке — позиции нет, линию рисовать некуда.
        if let fromLevel = graph.levelIndex(of: edge.from),
           let toLevel = graph.levelIndex(of: edge.to),
           let fromPosition = positions[edge.from],
           let toPosition = positions[edge.to] {
            let from = point(fromPosition)
            let to = point(toPosition)
            let fromR = graph.style(atLevel: fromLevel).diameter / 2
            let toR = graph.style(atLevel: toLevel).diameter / 2
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
        let style = graph.style(atLevel: level)
        let diameter = style.diameter

        // Работа в области уровня: тот же размер, пунктирный контур —
        // продукт её не выполняет.
        let inZone = job.zoneID != nil

        Circle()
            .fill(LevelColors.fill(style))
            .overlay(
                Circle().strokeBorder(
                    inZone ? LevelColors.zoneStroke : LevelColors.stroke(style),
                    style: StrokeStyle(lineWidth: 2, dash: inZone ? [4, 3] : [])
                )
            )
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
                .font(.system(
                    size: style.isTopScale ? 12 : 11,
                    weight: style.isTopScale ? .semibold : .regular
                ))
                .lineLimit(job.role == nil ? 3 : 2)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
        }
        .frame(width: LayoutMetrics.columnWidth - 6)
        .position(x: position.x, y: position.y + diameter / 2 + 32)

        // Счётчик свёрнутой цепочки — то же место и смысл, что на канвасе:
        // столько работ уровня спрятано справа.
        let chain = graph.chain(after: job.id)
        if job.isCollapsed, !chain.isEmpty {
            HStack(spacing: 2) {
                Text("\(chain.count)")
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
            .fixedSize()
            .position(x: position.x + diameter / 2 + 18, y: position.y)
        }
    }
}
