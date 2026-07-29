import GraphCore
import SwiftUI

/// Панель превью механики: мини-граф примера + подпись «что произошло».
/// Топология — призрак дельты (те же судьбы, что на канвасе), карточка —
/// изменение полей карточки, стикер — конвертик на якорной работе.
struct MechanicMiniPreview: View {
    let mechanic: Mechanic

    var body: some View {
        let sample = MechanicExample.sample(for: mechanic.slug)

        VStack(alignment: .leading, spacing: 4) {
            switch mechanic.mechanicClass {
            case .topology:
                if case let .success(preview) = MechanicTransform.preview(
                    mechanic.slug, in: sample.graph, anchor: sample.anchor
                ) {
                    let overlay = MechanicGhost.overlay(current: sample.graph, preview: preview)
                    MiniGraphCanvas(
                        graph: overlay.union,
                        fates: overlay.fates,
                        removedEdges: overlay.removedEdges,
                        addedEdges: overlay.addedEdges
                    )
                    caption("На примере: \(sample.graph.delta(to: preview).summary)")
                }
            case .jobCard:
                MiniGraphCanvas(graph: sample.graph, highlightedJobs: anchorJobs(sample))
                cardCaption(sample)
            case .sticker:
                MiniGraphCanvas(
                    graph: sample.graph,
                    badgedJobs: anchorJobs(sample),
                    badgeSymbol: mechanic.symbol
                )
                caption("На примере: заметка-комментарий вешается на работу — её бейдж виден на графе")
            }
        }
    }

    private func anchorJobs(_ sample: MechanicExample.Sample) -> Set<UUID> {
        if case let .node(id) = sample.anchor { return [id] }
        return []
    }

    /// Подпись карточной механики: что меняется в карточке примера.
    @ViewBuilder
    private func cardCaption(_ sample: MechanicExample.Sample) -> some View {
        switch mechanic.slug {
        case "remove-negative-emotions":
            caption("На примере: «боюсь ошибиться в цифрах» переезжает из негативных эмоций в позитивные")
        default:
            caption("На примере: работает с критериями успеха карточки — «баланс сходится с первого раза»")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Статичный мини-рендер графа для превью палитры: та же геометрия
/// (GraphLayout), масштаб подгоняется под отведённый прямоугольник.
/// Язык призрака совпадает с канвасом: удалённое — перечёркнуто и
/// приглушено, новое — пунктир акцентного цвета.
struct MiniGraphCanvas: View {
    let graph: WorkGraph
    var fates: [UUID: MechanicGhost.JobFate] = [:]
    var removedEdges: Set<JobEdge> = []
    var addedEdges: Set<JobEdge> = []
    /// Работы с бейджем комментария (пример стикерной механики).
    var badgedJobs: Set<UUID> = []
    /// Изображение бейджа — свой SF Symbol у каждой механики.
    var badgeSymbol = "envelope.fill"
    /// Якорные работы карточной механики — акцентное кольцо.
    var highlightedJobs: Set<UUID> = []

    private let canvasHeight: CGFloat = 132

    var body: some View {
        GeometryReader { proxy in
            let geometry = GraphLayout.geometry(graph)
            let positions = geometry.positions
            let transform = fitTransform(positions: positions, size: proxy.size)

            ZStack(alignment: .topLeading) {
                // Рамки областей — пунктир, как на канвасе.
                ForEach(graph.levels) { level in
                    ForEach(level.zones) { zone in
                        if let span = geometry.zones[zone.id] {
                            zoneFrame(span, transform: transform)
                        }
                    }
                }
                ForEach(graph.edges, id: \.self) { edge in
                    edgeLine(edge, positions: positions, transform: transform)
                }
                ForEach(Array(graph.levels.enumerated()), id: \.element.id) { levelIndex, level in
                    ForEach(level.jobs) { job in
                        if let position = positions[job.id] {
                            node(
                                job,
                                style: graph.style(atLevel: levelIndex),
                                at: transform.apply(position)
                            )
                        }
                    }
                }
            }
        }
        .frame(height: canvasHeight)
    }

    // MARK: Масштабирование

    private struct FitTransform {
        var scale: CGFloat
        var offset: CGPoint

        func apply(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y)
        }
    }

    private func fitTransform(positions: [UUID: CGPoint], size: CGSize) -> FitTransform {
        let xs = positions.values.map(\.x)
        let ys = positions.values.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return FitTransform(scale: 1, offset: .zero) }
        // Поля под кружки и мини-подписи по краям.
        let padX: CGFloat = 42
        let padY: CGFloat = 26
        let width = max(maxX - minX, 1)
        let height = max(maxY - minY, 1)
        let scale = min(
            (size.width - padX * 2) / width,
            (size.height - padY * 2) / height,
            0.6
        )
        return FitTransform(
            scale: scale,
            offset: CGPoint(x: padX - minX * scale, y: padY - minY * scale)
        )
    }

    // MARK: Элементы

    private func zoneFrame(_ span: GraphLayout.ZoneSpan, transform: FitTransform) -> some View {
        let topLeft = transform.apply(CGPoint(
            x: span.minX, y: CGFloat(span.levelIndex) * LayoutMetrics.rowHeight
        ))
        let width = span.width * transform.scale + 30
        let height: CGFloat = 52
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(
                LevelColors.zoneStroke.opacity(0.5),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
            .frame(width: width, height: height)
            .position(x: topLeft.x + (width - 30) / 2, y: topLeft.y)
    }

    @ViewBuilder
    private func edgeLine(
        _ edge: JobEdge, positions: [UUID: CGPoint], transform: FitTransform
    ) -> some View {
        if let from = positions[edge.from], let to = positions[edge.to] {
            let start = transform.apply(from)
            let end = transform.apply(to)
            let isRemoved = removedEdges.contains(edge)
            let isAdded = addedEdges.contains(edge)
            Path { path in
                path.move(to: start)
                path.addLine(to: end)
            }
            .stroke(
                isAdded ? Color.accentColor : Color.gray.opacity(isRemoved ? 0.35 : 0.55),
                style: StrokeStyle(
                    lineWidth: isAdded ? 1.4 : 1.1,
                    lineCap: .round,
                    dash: (isAdded || isRemoved) ? [4, 3] : []
                )
            )
        }
    }

    @ViewBuilder
    private func node(_ job: JobNode, style: LevelStyle, at position: CGPoint) -> some View {
        let fate = fates[job.id] ?? .unchanged
        let diameter = max(style.diameter * 0.45, 11)
        let inZone = job.zoneID != nil

        Circle()
            .fill(LevelColors.fill(style))
            .overlay(
                Circle().strokeBorder(
                    fate == .added
                        ? Color.accentColor
                        : (inZone ? LevelColors.zoneStroke : LevelColors.stroke(style)),
                    style: StrokeStyle(
                        lineWidth: 1.2,
                        dash: (inZone || fate == .added) ? [3, 2] : []
                    )
                )
            )
            .overlay {
                if fate == .removed || job.killed {
                    Path { path in
                        path.move(to: CGPoint(x: 2, y: 2))
                        path.addLine(to: CGPoint(x: diameter - 2, y: diameter - 2))
                        path.move(to: CGPoint(x: diameter - 2, y: 2))
                        path.addLine(to: CGPoint(x: 2, y: diameter - 2))
                    }
                    .stroke(Color.secondary.opacity(0.8), lineWidth: 1.2)
                }
                if highlightedJobs.contains(job.id) || fate == .changed {
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.4)
                        .padding(-3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if badgedJobs.contains(job.id) {
                    Image(systemName: badgeSymbol)
                        .font(.system(size: 6, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Circle().fill(Color.orange.gradient))
                        .offset(x: 5, y: -5)
                }
            }
            .frame(width: diameter, height: diameter)
            .opacity(fate == .removed ? 0.35 : 1)
            .position(position)

        Text(job.displayText)
            .font(.system(size: 7.5))
            .foregroundStyle(fate == .removed ? .tertiary : .secondary)
            .lineLimit(1)
            .frame(width: 72)
            .position(x: position.x, y: position.y + diameter / 2 + 9)
    }
}
