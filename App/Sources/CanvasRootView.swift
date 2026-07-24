import SwiftUI
import GraphCore

/// Канвас графа работ: уровни-полосы, автораскладка слева направо,
/// zoom/pan, клавиатурное и мышиное редактирование. Позиции — чистая
/// функция от графа (GraphLayout); ручного перетаскивания нет, поэтому
/// анимация перекладки — spring вокруг мутации модели
/// в PetableDocument.perform.
struct CanvasRootView: View {
    @ObservedObject var document: PetableDocument
    @Environment(\.undoManager) private var undoManager

    @State private var selection: UUID?
    @State private var editingId: UUID?
    @State private var draft = ""
    @State private var editingIsNewNode = false
    @FocusState private var editorFocused: Bool
    /// Инлайн-переименование уровня (двойной клик по имени).
    @State private var editingLevelId: UUID?
    @State private var levelDraft = ""
    @FocusState private var levelEditorFocused: Bool

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    /// Видимая область канваса — для zoom-to-fit и зума от центра.
    @State private var viewportSize: CGSize = .zero
    /// Подсказки горячих клавиш внизу канваса; выключаются кнопкой «?».
    @AppStorage("canvas.showsHints") private var showsHints = true
    /// Курсор в координатах контента — для proximity-reveal кнопок.
    @State private var cursorPosition: CGPoint?
    /// Выделенное ребро — подсветка + ✕ на линии + Delete.
    @State private var selectedEdge: JobEdge?
    /// Активное связывание: drag от плюса узла к другому узлу.
    @State private var dragLink: DragLink?
    @StateObject private var focusBridge = CanvasFocusBridge()

    private static let contentSpace = "canvas-content"

    private struct DragLink {
        var from: UUID
        var fromPoint: CGPoint
        var current: CGPoint
    }

    private let contentPadding: CGFloat = 90
    private let bandInset: CGFloat = 24
    /// Центр узла лежит на этом расстоянии от верхней кромки полосы.
    private let nodeOffsetInBand: CGFloat = 50
    private var bandHeight: CGFloat { LayoutMetrics.rowHeight - 10 }

    var body: some View {
        let positions = GraphLayout.layout(document.graph)

        ZStack(alignment: .topLeading) {
            CanvasHostView(
                onKey: handleKey,
                onPan: { delta in
                    offset.width += delta.width
                    offset.height += delta.height
                },
                onZoom: applyZoom,
                onClickEmpty: {
                    commitEditingIfNeeded()
                    selection = nil
                    selectedEdge = nil
                },
                onDoubleClickEmpty: { location in
                    createJobAtEmptyPoint(location)
                },
                onMouseMove: { location in
                    guard let location else {
                        cursorPosition = nil
                        return
                    }
                    let content = CGPoint(
                        x: (location.x - offset.width) / scale,
                        y: (location.y - offset.height) / scale
                    )
                    // Порог 2pt: не дёргать пересборку канваса на каждый пиксель.
                    if let cursor = cursorPosition,
                       abs(cursor.x - content.x) < 2, abs(cursor.y - content.y) < 2 {
                        return
                    }
                    cursorPosition = content
                },
                focusBridge: focusBridge
            )

            graphContent(positions)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(offset)
                .allowsHitTesting(true)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottomTrailing) { zoomControls }
        .overlay(alignment: .bottom) {
            if showsHints { hintsBar }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportSize = proxy.size }
                    .onChange(of: proxy.size) { _, size in viewportSize = size }
            }
        )
        .focusedSceneValue(\.canvasZoom, CanvasZoomCommands(
            zoomIn: { zoomStep(1.25) },
            zoomOut: { zoomStep(1 / 1.25) },
            actualSize: { setZoom(1) },
            zoomToFit: { zoomToFit() }
        ))
        .focusedSceneValue(\.canvasGraph, CanvasGraphCommands(
            hasSelection: selection != nil,
            addJobTop: {
                commitEditingIfNeeded()
                guard let firstLevel = document.graph.levels.first else { return }
                if let newId = document.perform(.addJob(level: firstLevel.id)) {
                    startEditingNew(newId)
                }
            },
            addBelow: {
                guard let selection else { return }
                commitEditingIfNeeded()
                if let newId = document.perform(.addConnectedBelow(of: selection)) {
                    startEditingNew(newId)
                }
            },
            addRight: {
                guard let selection else { return }
                commitEditingIfNeeded()
                if let newId = document.perform(.addConnectedRight(of: selection)) {
                    startEditingNew(newId)
                }
            },
            editText: {
                guard let selection, let job = document.graph.job(selection) else { return }
                beginEditing(job)
            },
            moveLeft: {
                guard let selection else { return }
                document.perform(.reorder(selection, direction: .left))
            },
            moveRight: {
                guard let selection else { return }
                document.perform(.reorder(selection, direction: .right))
            },
            deleteSelection: {
                guard let selection else { return }
                commitEditingIfNeeded()
                self.selection = document.perform(.delete(selection))
            }
        ))
        .onAppear {
            document.attach(undoManager)
            autoEditFreshDocument()
        }
        .onChange(of: undoManager) { _, newValue in
            document.attach(newValue)
        }
        .onChange(of: editorFocused) { _, focused in
            if !focused { commitEditingIfNeeded() }
        }
        .onChange(of: levelEditorFocused) { _, focused in
            if !focused { commitLevelEditingIfNeeded() }
        }
        .onChange(of: document.selectedGraphID) { _, _ in
            // Смена графа: правка чужого узла невозможна — редактор
            // сбрасывается без коммита, новый пустой граф сразу в редакторе.
            editingId = nil
            editingLevelId = nil
            selection = nil
            selectedEdge = nil
            dragLink = nil
            autoEditFreshDocument()
        }
    }

    // MARK: - Рендер

    @ViewBuilder
    private func graphContent(_ positions: [UUID: CGPoint]) -> some View {
        let size = contentSize(positions)

        ZStack(alignment: .topLeading) {
            // Точечная сетка — ощущение бесконечной доски; масштабируется
            // вместе с контентом.
            dotGrid(size: size)

            // Полосы уровней — фон, событий не перехватывают: клики по
            // пустому месту уходят в CanvasHostView (deselect), hover не ломают.
            ForEach(Array(document.graph.levels.enumerated()), id: \.element.id) { index, _ in
                bandBackground(index: index, width: size.width)
                    .allowsHitTesting(false)
            }

            // Рёбра: animatable Shape, интерполируются тем же spring, что и круги.
            ForEach(document.graph.edges, id: \.self) { edge in
                edgeView(edge, positions: positions)
            }

            // Узлы.
            ForEach(Array(document.graph.levels.enumerated()), id: \.element.id) { levelIndex, level in
                ForEach(level.jobs) { job in
                    nodeView(job, level: levelIndex, at: point(positions[job.id]))
                }
            }

            // Контролы уровней: добавить работу, вставить/удалить уровень.
            ForEach(Array(document.graph.levels.enumerated()), id: \.element.id) { index, level in
                bandControls(index: index, level: level, positions: positions)
            }

            // Резиновая линия: тянется от плюса к курсору при связывании.
            if let dragLink {
                Path { path in
                    path.move(to: dragLink.fromPoint)
                    path.addLine(to: dragLink.current)
                }
                .stroke(
                    Color.accentColor.opacity(0.7),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [5, 4])
                )
                .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: Self.contentSpace)
    }

    /// Тонкая точечная сетка на весь контент. Рисуется один раз на Canvas —
    /// дёшево даже на больших графах.
    private func dotGrid(size: CGSize) -> some View {
        Canvas { context, _ in
            let step: CGFloat = 28
            let dot: CGFloat = 1.6
            var y: CGFloat = step / 2
            while y < size.height {
                var x: CGFloat = step / 2
                while x < size.width {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: dot, height: dot)),
                        with: .color(.primary.opacity(0.055))
                    )
                    x += step
                }
                y += step
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    // MARK: Полосы уровней

    private func bandTop(_ index: Int) -> CGFloat {
        contentPadding + CGFloat(index) * LayoutMetrics.rowHeight - nodeOffsetInBand
    }

    @ViewBuilder
    private func bandBackground(index: Int, width: CGFloat) -> some View {
        let top = bandTop(index)

        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LevelColors.fill(for: index).opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(LevelColors.stroke(for: index).opacity(0.18), lineWidth: 1)
            )
            .frame(width: width - bandInset * 2, height: bandHeight)
            .offset(x: bandInset, y: top)
    }

    /// Имя уровня вертикально у левой кромки полосы — не пересекается
    /// ни с узлами, ни с подписями при любой плотности графа.
    /// Двойной клик — инлайн-переименование; рендерится в слое контролов
    /// (bandBackground events не принимает).
    @ViewBuilder
    private func levelLabel(index: Int, level: GraphLevel, top: CGFloat) -> some View {
        if editingLevelId == level.id {
            TextField("УРОВЕНЬ \(index + 1)", text: $levelDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .focused($levelEditorFocused)
                .onSubmit { commitLevelEditing() }
                .onExitCommand { cancelLevelEditing() }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(width: 200)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                )
                // Горизонтально внутри полосы: вертикальный TextField нечитаем.
                .position(x: bandInset + 116, y: top + bandHeight / 2)
        } else {
            Text(level.name?.uppercased() ?? "УРОВЕНЬ \(index + 1)")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(LevelColors.stroke(for: index).opacity(0.65))
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: bandHeight)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { beginLevelEditing(level) }
                .rotationEffect(.degrees(-90))
                .position(x: bandInset - 12, y: top + bandHeight / 2)
                .help("Двойной клик — переименовать уровень")
        }
    }

    /// Кнопки полосы: «+ работа» в конце ряда, вставка уровня на стыках,
    /// удаление пустого уровня. Появляются только рядом с курсором
    /// (proximity-reveal) — канвас остаётся чистым, кнопка находится
    /// движением в её сторону.
    @ViewBuilder
    private func bandControls(index: Int, level: GraphLevel, positions: [UUID: CGPoint]) -> some View {
        let top = bandTop(index)
        let nodeY = top + nodeOffsetInBand
        let lastX = level.jobs.compactMap { positions[$0.id]?.x }.max().map { $0 + contentPadding }

        levelLabel(index: index, level: level, top: top)

        // Автономная работа — в конец уровня.
        let addJobPoint = CGPoint(x: (lastX ?? contentPadding - 40) + 96, y: nodeY)
        addJobButton(level: level)
            .proximityReveal(reveal(near: addJobPoint))
            .position(addJobPoint)

        // Вставка уровня: слева на кромке — над самой верхней полосой
        // + под каждой (кромка между полосами — одна кнопка, тот же индекс).
        if index == 0 {
            let topPoint = CGPoint(x: bandInset - 12, y: top - 3)
            insertLevelButton(at: 0)
                .proximityReveal(reveal(near: topPoint))
                .position(topPoint)
        }
        let bottomPoint = CGPoint(x: bandInset - 12, y: top + bandHeight + 3)
        insertLevelButton(at: index + 1)
            .proximityReveal(reveal(near: bottomPoint))
            .position(bottomPoint)

        // Пустой уровень можно убрать.
        if level.jobs.isEmpty, document.graph.levels.count > 1 {
            let trashPoint = CGPoint(x: (lastX ?? contentPadding - 40) + 148, y: nodeY)
            Button {
                document.perform(.deleteLevel(level.id))
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.ultraThinMaterial))
                    .overlay(Circle().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .modifier(HoverPulse())
            .help("Удалить пустой уровень")
            .proximityReveal(reveal(near: trashPoint))
            .position(trashPoint)
        }
    }

    /// Курсор в радиусе от точки (координаты контента).
    private func cursorWithin(_ point: CGPoint, _ radius: CGFloat) -> Bool {
        guard let cursor = cursorPosition else { return false }
        return hypot(cursor.x - point.x, cursor.y - point.y) <= radius
    }

    /// 1 вблизи точки, плавное затухание до 0 к краю радиуса.
    /// Расстояние в координатах контента — работает при любом zoom.
    private func reveal(near point: CGPoint) -> Double {
        guard let cursor = cursorPosition else { return 0 }
        let distance = hypot(cursor.x - point.x, cursor.y - point.y)
        let full: CGFloat = 55
        let edge: CGFloat = 150
        if distance <= full { return 1 }
        if distance >= edge { return 0 }
        return Double(1 - (distance - full) / (edge - full))
    }

    private func addJobButton(level: GraphLevel) -> some View {
        Button {
            commitEditingIfNeeded()
            if let newId = document.perform(.addJob(level: level.id)) {
                startEditingNew(newId)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Text("работа")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(HoverPulse(idleOpacity: 0.9))
        .help("Добавить отдельную работу на этот уровень")
    }

    /// Компактный плюс на левой кромке между полосами.
    private func insertLevelButton(at index: Int) -> some View {
        Button {
            commitEditingIfNeeded()
            document.perform(.insertLevel(at: index))
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(Color.secondary.opacity(0.4), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(HoverPulse(idleOpacity: 0.75))
        .help("Вставить уровень здесь")
    }

    // MARK: Рёбра

    @ViewBuilder
    private func edgeView(_ edge: JobEdge, positions: [UUID: CGPoint]) -> some View {
        if let fromLevel = document.graph.levelIndex(of: edge.from),
           let toLevel = document.graph.levelIndex(of: edge.to) {
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
                ? detourWaypoints(start: start, end: end, fromLevel: fromLevel,
                                  toLevel: toLevel, positions: positions)
                : []
            let shape = EdgeShape(from: start, to: end, vertical: vertical, waypoints: waypoints)
            let isSelected = selectedEdge == edge

            shape
                .stroke(
                    isSelected ? Color.accentColor : Color.gray.opacity(0.5),
                    style: StrokeStyle(lineWidth: isSelected ? 2.5 : 1.5, lineCap: .round)
                )
                // Хит-зона — сама линия, раздутая до 16pt; клики мимо линии
                // проходят дальше (пустота, узлы).
                .contentShape(EdgeHitShape(base: shape))
                .onTapGesture { selectEdge(edge) }
                .contextMenu {
                    Button("Удалить связь", role: .destructive) {
                        document.perform(.toggleEdge(from: edge.from, to: edge.to))
                        if selectedEdge == edge { selectedEdge = nil }
                    }
                }

            if isSelected {
                // Без обходных точек кубическая кривая проходит через середину
                // отрезка; с ними средняя обходная точка лежит на самой линии.
                let mid = waypoints.isEmpty
                    ? CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
                    : waypoints[waypoints.count / 2]
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.accentColor))
                    .contentShape(Circle())
                    .onTapGesture {
                        document.perform(.toggleEdge(from: edge.from, to: edge.to))
                        selectedEdge = nil
                    }
                    .help("Удалить связь (или Delete)")
                    .position(x: mid.x, y: mid.y)
            }
        }
    }

    /// Обходные точки ребра через 2+ уровня — общая геометрия в GraphCore
    /// (используется и PNG-снапшотом).
    private func detourWaypoints(
        start: CGPoint, end: CGPoint,
        fromLevel: Int, toLevel: Int,
        positions: [UUID: CGPoint]
    ) -> [CGPoint] {
        GraphLayout.detourWaypoints(
            graph: document.graph, positions: positions,
            start: start, end: end,
            fromLevel: fromLevel, toLevel: toLevel,
            padding: contentPadding
        )
    }

    // MARK: Узлы

    @ViewBuilder
    private func nodeView(_ job: JobNode, level: Int, at position: CGPoint) -> some View {
        let diameter = LevelStyle.style(for: level).diameter
        let isSelected = selection == job.id
        // Ховер — от позиции курсора, не от onHover: тот теряет exit-события
        // при частых пересборках канваса и «залипает».
        let isHovered = cursorWithin(position, diameter / 2 + 8)
        let plusRight = CGPoint(x: position.x + diameter / 2 + 18, y: position.y)
        let plusBelow = CGPoint(x: position.x - diameter / 2 - 14, y: position.y + diameter / 2 + 14)
        // Зоны плюсов держат кнопки видимыми по пути от круга до клика;
        // источник активного связывания не должен исчезнуть посреди drag.
        let showsPlus = isSelected || isHovered || dragLink?.from == job.id
            || cursorWithin(plusRight, 20) || cursorWithin(plusBelow, 20)
        // Узел под резиновой линией — подсветка цели связывания.
        let isLinkTarget = dragLink.map {
            $0.from != job.id
                && hypot($0.current.x - position.x, $0.current.y - position.y) <= diameter / 2 + 12
        } ?? false

        Circle()
            .fill(LevelColors.fill(for: level))
            .overlay(Circle().strokeBorder(LevelColors.stroke(for: level), lineWidth: 2))
            .overlay {
                if isSelected || isLinkTarget {
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2.5)
                        .padding(-5)
                        .shadow(color: Color.accentColor.opacity(0.45), radius: 6)
                }
            }
            .shadow(color: .black.opacity(0.16), radius: 3, y: 1.5)
            .frame(width: diameter, height: diameter)
            .scaleEffect(isHovered ? 1.06 : 1)
            .animation(.spring(duration: 0.25), value: isHovered)
            .position(position)
            .onTapGesture(count: 2) { beginEditing(job) }
            // ⌘ проверяется внутри обычного тапа: отдельный
            // TapGesture().modifiers(.command) блокирует ВСЕ клики узла.
            .onTapGesture {
                if NSEvent.modifierFlags.contains(.command) {
                    toggleEdgeWithSelection(job.id)
                } else {
                    select(job.id)
                }
            }
            .contextMenu {
                Button("Редактировать") { beginEditing(job) }
                Divider()
                Button("Работа справа (⌘Return)") {
                    commitEditingIfNeeded()
                    if let newId = document.perform(.addConnectedRight(of: job.id)) {
                        startEditingNew(newId)
                    }
                }
                Button("Декомпозиция ниже (Tab)") {
                    commitEditingIfNeeded()
                    if let newId = document.perform(.addConnectedBelow(of: job.id)) {
                        startEditingNew(newId)
                    }
                }
                Button("Сдвинуть влево (⌘←)") {
                    document.perform(.reorder(job.id, direction: .left))
                }
                Button("Сдвинуть вправо (⌘→)") {
                    document.perform(.reorder(job.id, direction: .right))
                }
                if let selection, selection != job.id {
                    Divider()
                    Button(edgeExists(selection, job.id)
                           ? "Убрать связь с выделенной"
                           : "Связать с выделенной (⌘-клик)") {
                        toggleEdgeWithSelection(job.id)
                    }
                }
                Divider()
                Button("Удалить", role: .destructive) {
                    commitEditingIfNeeded()
                    selection = document.perform(.delete(job.id))
                }
            }

        if showsPlus {
            // Связанная работа справа — тот же уровень.
            nodePlusControl(
                source: job,
                nodeCenter: position,
                help: "Клик — связанная работа справа; потяните до узла — связь"
            ) {
                commitEditingIfNeeded()
                if let newId = document.perform(.addConnectedRight(of: job.id)) {
                    startEditingNew(newId)
                }
            }
            .position(plusRight)
            .transition(.scale(scale: 0.5).combined(with: .opacity))

            // Связанная работа снизу — уровень ниже.
            nodePlusControl(
                source: job,
                nodeCenter: position,
                help: "Клик — связанная работа на уровень ниже; потяните до узла — связь"
            ) {
                commitEditingIfNeeded()
                if let newId = document.perform(.addConnectedBelow(of: job.id)) {
                    startEditingNew(newId)
                }
            }
            .position(plusBelow)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }

        if editingId == job.id {
            TextField("роль: хочу …", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .focused($editorFocused)
                .onSubmit { commitEditing() }
                .onExitCommand { cancelEditing() }
                .onKeyPress(.tab) {
                    commitEditingThenAddBelow()
                    return .handled
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .frame(width: 230)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(.regularMaterial)
                        .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1.5)
                )
                // Узел у левого края — карточку прижимаем, чтобы не уехала
                // за границу канваса (под сайдбар).
                .position(x: max(position.x, 145), y: position.y + diameter / 2 + 36)
        } else {
            nodeLabel(job, level: level)
                .position(x: position.x, y: position.y + diameter / 2 + 32)
                .onTapGesture(count: 2) { beginEditing(job) }
                .onTapGesture { select(job.id) }
        }
    }

    /// Плюс у узла: клик — новая связанная работа, drag до другого узла —
    /// связь с ним (toggle: повторный drag по той же паре убирает).
    private func nodePlusControl(
        source job: JobNode,
        nodeCenter: CGPoint,
        help: String,
        onTap: @escaping () -> Void
    ) -> some View {
        Image(systemName: "plus")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 22, height: 22)
            .background(Circle().fill(.ultraThinMaterial))
            .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
            .contentShape(Circle())
            .modifier(HoverPulse(idleOpacity: 0.85))
            .help(help)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.contentSpace))
                    .onChanged { value in
                        dragLink = DragLink(from: job.id, fromPoint: nodeCenter, current: value.location)
                    }
                    .onEnded { value in
                        defer { dragLink = nil }
                        let moved = hypot(value.translation.width, value.translation.height)
                        if moved < 6 {
                            onTap()
                        } else if let target = nodeID(at: value.location), target != job.id {
                            commitEditingIfNeeded()
                            document.perform(.toggleEdge(from: job.id, to: target))
                        }
                        focusBridge.focusCanvas()
                    }
            )
    }

    /// Узел, чей круг (с небольшим допуском) накрывает точку контента.
    private func nodeID(at pointInContent: CGPoint) -> UUID? {
        let positions = GraphLayout.layout(document.graph)
        for (levelIndex, level) in document.graph.levels.enumerated() {
            let radius = LevelStyle.style(for: levelIndex).diameter / 2 + 12
            for job in level.jobs {
                guard let raw = positions[job.id] else { continue }
                let center = point(raw)
                if hypot(pointInContent.x - center.x, pointInContent.y - center.y) <= radius {
                    return job.id
                }
            }
        }
        return nil
    }

    @ViewBuilder
    private func nodeLabel(_ job: JobNode, level: Int) -> some View {
        VStack(spacing: 0) {
            if let role = job.role {
                Text("\(role):")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(job.verb)
                .font(.system(size: level == 0 ? 12 : 11, weight: level == 0 ? .semibold : .regular))
                // Резерв 3 строки — совпадает с labelReserve раскладки;
                // длиннее — truncation, полный текст в редакторе.
                .lineLimit(job.role == nil ? 3 : 2)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
        }
        .frame(width: LayoutMetrics.columnWidth - 6)
    }

    private func point(_ position: CGPoint?) -> CGPoint {
        guard let position else { return .zero }
        return CGPoint(x: position.x + contentPadding, y: position.y + contentPadding)
    }

    private func contentSize(_ positions: [UUID: CGPoint]) -> CGSize {
        let maxX = (positions.values.map(\.x).max() ?? 0) + contentPadding * 2 + 220
        let bottom = bandTop(max(document.graph.levels.count - 1, 0)) + bandHeight + contentPadding
        return CGSize(width: max(maxX, 900), height: max(bottom, 600))
    }

    // MARK: - Zoom-контролы и команды меню

    /// Панель масштаба в правом нижнем углу: −, процент (клик — 100%),
    /// +, вписать граф, «?» — подсказки клавиш. Конвенция canvas-приложений
    /// (Freeform, OmniGraffle): текущий масштаб всегда виден.
    private var zoomControls: some View {
        HStack(spacing: 2) {
            zoomBarButton("minus", help: "Уменьшить (⌘−)") { zoomStep(1 / 1.25) }
            Button {
                setZoom(1)
            } label: {
                Text("\(Int((scale * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Реальный размер (⌘0)")
            zoomBarButton("plus", help: "Увеличить (⌘+)") { zoomStep(1.25) }
            Divider().frame(height: 14)
            zoomBarButton(
                "arrow.down.backward.and.arrow.up.forward.rectangle",
                help: "Вписать граф в окно (⇧⌘0)"
            ) { zoomToFit() }
            zoomBarButton(
                showsHints ? "questionmark.circle.fill" : "questionmark.circle",
                help: showsHints ? "Скрыть подсказки клавиш" : "Показать подсказки клавиш"
            ) { showsHints.toggle() }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        .padding(12)
    }

    private func zoomBarButton(
        _ systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Подсказка по контексту: что можно нажать прямо сейчас.
    private var hintsBar: some View {
        Text(currentHint)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(.regularMaterial))
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .padding(.bottom, 12)
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: currentHint)
    }

    private var currentHint: String {
        if editingId != nil {
            return "Return — сохранить · Tab — сохранить и декомпозиция · Esc — отмена"
        }
        if selectedEdge != nil {
            return "Delete — удалить связь · Esc — снять выделение"
        }
        if selection != nil {
            return "Tab — декомпозиция · ⌘Return — работа справа · Return — текст · ⌘-клик — связь · Delete — удалить"
        }
        return "Двойной клик — новая работа · Tab — работа сверху · драг — панорама · ⌘-скролл — zoom"
    }

    /// Zoom от центра видимой области (кнопки и меню, без курсора).
    private func zoomStep(_ factor: CGFloat) {
        withAnimation(.spring(duration: 0.25)) {
            applyZoom(factor, at: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2))
        }
    }

    private func setZoom(_ target: CGFloat) {
        withAnimation(.spring(duration: 0.25)) {
            applyZoom(target / scale, at: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2))
        }
    }

    /// Вписать весь граф в окно: масштаб не больше 100%, контент по центру.
    private func zoomToFit() {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        let content = contentSize(GraphLayout.layout(document.graph))
        let fit = min(
            viewportSize.width / content.width,
            viewportSize.height / content.height
        )
        let newScale = min(max(min(fit, 1), 0.25), 4)
        withAnimation(.spring(duration: 0.3)) {
            scale = newScale
            offset = CGSize(
                width: (viewportSize.width - content.width * newScale) / 2,
                height: (viewportSize.height - content.height * newScale) / 2
            )
        }
    }

    /// Двойной клик по пустому месту — работа на уровне под курсором
    /// (конвенция Freeform/MindNode: пустое место + двойной клик = узел).
    private func createJobAtEmptyPoint(_ location: CGPoint) {
        commitEditingIfNeeded()
        let contentY = (location.y - offset.height) / scale
        let levels = document.graph.levels
        guard !levels.isEmpty else { return }
        let index = Int(((contentY - bandTop(0)) / LayoutMetrics.rowHeight).rounded(.down))
        let level = levels[min(max(index, 0), levels.count - 1)]
        if let newId = document.perform(.addJob(level: level.id)) {
            startEditingNew(newId)
        }
    }

    // MARK: - Zoom вокруг курсора

    private func applyZoom(_ factor: CGFloat, at cursor: CGPoint) {
        let newScale = min(max(scale * factor, 0.25), 4)
        guard newScale != scale else { return }
        // Точка контента под курсором должна остаться под курсором.
        let contentPoint = CGPoint(
            x: (cursor.x - offset.width) / scale,
            y: (cursor.y - offset.height) / scale
        )
        offset = CGSize(
            width: cursor.x - contentPoint.x * newScale,
            height: cursor.y - contentPoint.y * newScale
        )
        scale = newScale
    }

    // MARK: - Клавиатура (режим навигации; в режиме редактирования
    // события уходят в TextField — хост их не видит)

    private func handleKey(_ key: CanvasKey) -> Bool {
        switch key {
        case .tab:
            if let selection {
                // Связанная работа на уровень ниже (декомпозиция).
                if let newId = document.perform(.addConnectedBelow(of: selection)) {
                    startEditingNew(newId)
                }
            } else if let firstLevel = document.graph.levels.first {
                // Пустой канвас/нет выделения — автономная работа в верхний уровень.
                if let newId = document.perform(.addJob(level: firstLevel.id)) {
                    startEditingNew(newId)
                }
            }
            return true
        case .cmdReturn:
            guard let selection else { return false }
            // Связанная работа справа — продолжение последовательности.
            if let newId = document.perform(.addConnectedRight(of: selection)) {
                startEditingNew(newId)
            }
            return true
        case .enter:
            guard let selection, let job = document.graph.job(selection) else { return false }
            beginEditing(job)
            return true
        case .cmdLeft:
            guard let selection else { return false }
            document.perform(.reorder(selection, direction: .left))
            return true
        case .cmdRight:
            guard let selection else { return false }
            document.perform(.reorder(selection, direction: .right))
            return true
        case .delete:
            if let edge = selectedEdge {
                document.perform(.toggleEdge(from: edge.from, to: edge.to))
                selectedEdge = nil
                return true
            }
            guard let selection else { return false }
            // Без модалки: ⌘Z возвращает работу вместе со связями.
            self.selection = document.perform(.delete(selection))
            return true
        case .cmdPlus:
            zoomStep(1.25)
            return true
        case .escape:
            selection = nil
            selectedEdge = nil
            return true
        case .left, .right:
            return moveSelectionInLevel(key == .right ? 1 : -1)
        case .up:
            return moveSelectionAcrossLevels(-1)
        case .down:
            return moveSelectionAcrossLevels(1)
        }
    }

    private func moveSelectionInLevel(_ delta: Int) -> Bool {
        guard let selection,
              let levelIndex = document.graph.levelIndex(of: selection)
        else { return false }
        let jobs = document.graph.levels[levelIndex].jobs
        guard let index = jobs.firstIndex(where: { $0.id == selection }) else { return false }
        let target = index + delta
        guard target >= 0, target < jobs.count else { return false }
        select(jobs[target].id)
        return true
    }

    /// Вверх/вниз: ближайший непустой уровень, работа с ближайшим индексом.
    private func moveSelectionAcrossLevels(_ delta: Int) -> Bool {
        guard let selection,
              let levelIndex = document.graph.levelIndex(of: selection)
        else { return false }
        let jobs = document.graph.levels[levelIndex].jobs
        let index = jobs.firstIndex(where: { $0.id == selection }) ?? 0
        var target = levelIndex + delta
        while target >= 0, target < document.graph.levels.count {
            let targetJobs = document.graph.levels[target].jobs
            if !targetJobs.isEmpty {
                select(targetJobs[min(index, targetJobs.count - 1)].id)
                return true
            }
            target += delta
        }
        return false
    }

    private func select(_ id: UUID) {
        commitEditingIfNeeded()
        selection = id
        selectedEdge = nil
        // Клик по узлу не проходит через NSView канваса — фокус мог остаться
        // у сайдбара/другого поля, и Delete не дошёл бы до канваса.
        focusBridge.focusCanvas()
    }

    private func selectEdge(_ edge: JobEdge) {
        commitEditingIfNeeded()
        selection = nil
        selectedEdge = edge
        focusBridge.focusCanvas()
    }

    /// ⌘-клик / контекстное меню: связь выделенная → эта работа.
    private func toggleEdgeWithSelection(_ target: UUID) {
        guard let selection, selection != target else {
            select(target)
            return
        }
        document.perform(.toggleEdge(from: selection, to: target))
        focusBridge.focusCanvas()
    }

    private func edgeExists(_ a: UUID, _ b: UUID) -> Bool {
        document.graph.edges.contains {
            ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a)
        }
    }

    // MARK: - Инлайн-редактирование

    private func beginEditing(_ job: JobNode) {
        selection = job.id
        draft = job.displayText
        editingIsNewNode = false
        editingId = job.id
        editorFocused = true
    }

    private func startEditingNew(_ id: UUID) {
        selection = id
        draft = ""
        editingIsNewNode = true
        editingId = id
        editorFocused = true
    }

    private func commitEditing() {
        guard let id = editingId else { return }
        editingId = nil
        // Движок сам решает: пустой текст на новом узле → удалить,
        // на существующем → no-op.
        let focus = document.perform(.setText(id, raw: draft))
        if document.graph.job(id) == nil {
            selection = focus
        }
        focusBridge.focusCanvas()
    }

    private func commitEditingIfNeeded() {
        if editingId != nil { commitEditing() }
    }

    // MARK: - Переименование уровня

    private func beginLevelEditing(_ level: GraphLevel) {
        commitEditingIfNeeded()
        levelDraft = level.name ?? ""
        editingLevelId = level.id
        levelEditorFocused = true
    }

    private func commitLevelEditing() {
        guard let id = editingLevelId else { return }
        editingLevelId = nil
        // Движок сам решает: пустое имя → сброс к дефолту, без изменений → no-op.
        document.perform(.renameLevel(id, name: levelDraft))
        focusBridge.focusCanvas()
    }

    private func commitLevelEditingIfNeeded() {
        if editingLevelId != nil { commitLevelEditing() }
    }

    private func cancelLevelEditing() {
        editingLevelId = nil
        focusBridge.focusCanvas()
    }

    private func cancelEditing() {
        guard let id = editingId else { return }
        editingId = nil
        if editingIsNewNode {
            // Esc на только что созданном узле — узел исчезает.
            let focus = document.perform(.setText(id, raw: ""))
            if document.graph.job(id) == nil { selection = focus }
        }
        focusBridge.focusCanvas()
    }

    private func commitEditingThenAddBelow() {
        guard let id = editingId else { return }
        commitEditing()
        guard document.graph.job(id) != nil else { return }
        if let newId = document.perform(.addConnectedBelow(of: id)) {
            startEditingNew(newId)
        }
    }

    /// Новый документ открывается с единственной пустой работой в редакторе.
    private func autoEditFreshDocument() {
        if document.graph.jobCount == 1,
           let job = document.graph.allJobs.first,
           job.verb.isEmpty {
            startEditingNew(job.id)
        }
    }
}

/// Zoom-команды канваса для меню «Вид» (⌘+/⌘−/⌘0/⇧⌘0) — доносятся
/// до активного окна через focusedSceneValue.
struct CanvasZoomCommands {
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let actualSize: () -> Void
    let zoomToFit: () -> Void
}

struct CanvasZoomKey: FocusedValueKey {
    typealias Value = CanvasZoomCommands
}

/// Действия над графом для меню «Граф» — HIG: строка меню остаётся
/// главным местом обнаружения команд, даже когда те дублируются
/// клавишами и контекстными меню.
struct CanvasGraphCommands {
    /// Есть выделенная работа — для disabled-состояния пунктов меню.
    let hasSelection: Bool
    let addJobTop: () -> Void
    let addBelow: () -> Void
    let addRight: () -> Void
    let editText: () -> Void
    let moveLeft: () -> Void
    let moveRight: () -> Void
    let deleteSelection: () -> Void
}

struct CanvasGraphKey: FocusedValueKey {
    typealias Value = CanvasGraphCommands
}

extension FocusedValues {
    var canvasZoom: CanvasZoomCommands? {
        get { self[CanvasZoomKey.self] }
        set { self[CanvasZoomKey.self] = newValue }
    }

    var canvasGraph: CanvasGraphCommands? {
        get { self[CanvasGraphKey.self] }
        set { self[CanvasGraphKey.self] = newValue }
    }
}

private extension View {
    /// Proximity-reveal: прозрачность от близости курсора; невидимая
    /// кнопка не ловит клики.
    func proximityReveal(_ opacity: Double) -> some View {
        self
            .opacity(opacity)
            .allowsHitTesting(opacity > 0.1)
    }
}

/// Хит-зона ребра: линия, раздутая до кликабельной толщины.
/// strokedPath превращает обводку в заполняемый контур — contentShape
/// попадает только по самой линии, а не по её bounding box.
private struct EdgeHitShape: Shape {
    var base: EdgeShape

    func path(in rect: CGRect) -> Path {
        base.path(in: rect)
            .strokedPath(StrokeStyle(lineWidth: 16, lineCap: .round))
    }
}

/// Полупрозрачная кнопка, оживающая под курсором: полная непрозрачность + рост.
private struct HoverPulse: ViewModifier {
    var idleOpacity: Double = 0.55
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .opacity(hovering ? 1 : idleOpacity)
            .scaleEffect(hovering ? 1.12 : 1)
            .animation(.spring(duration: 0.2), value: hovering)
            .onHover { hovering = $0 }
    }
}
