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
    @State private var hoveredJob: UUID?
    @FocusState private var editorFocused: Bool

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @StateObject private var focusBridge = CanvasFocusBridge()

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
                },
                focusBridge: focusBridge
            )

            graphContent(positions)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(offset)
                .allowsHitTesting(true)
        }
        .background(Color(nsColor: .textBackgroundColor))
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
    }

    // MARK: - Рендер

    @ViewBuilder
    private func graphContent(_ positions: [UUID: CGPoint]) -> some View {
        let size = contentSize(positions)

        ZStack(alignment: .topLeading) {
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
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
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

        Text("Уровень \(index + 1)")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(LevelColors.stroke(for: index).opacity(0.55))
            .position(x: bandInset + 46, y: top + 16)
    }

    /// Кнопки полосы: «+ работа» в конце ряда, вставка уровня на стыках,
    /// удаление пустого уровня. Полупрозрачны, оживают под курсором.
    @ViewBuilder
    private func bandControls(index: Int, level: GraphLevel, positions: [UUID: CGPoint]) -> some View {
        let top = bandTop(index)
        let nodeY = top + nodeOffsetInBand
        let lastX = level.jobs.compactMap { positions[$0.id]?.x }.max().map { $0 + contentPadding }

        // Автономная работа — в конец уровня.
        addJobButton(level: level)
            .position(x: (lastX ?? contentPadding - 40) + 96, y: nodeY)

        // Вставка уровня: над самой верхней полосой + под каждой
        // (кромка между полосами — одна кнопка, тот же индекс).
        if index == 0 {
            insertLevelButton(at: 0)
                .position(x: bandInset + 52, y: top - 3)
        }
        insertLevelButton(at: index + 1)
            .position(x: bandInset + 52, y: top + bandHeight + 3)

        // Пустой уровень можно убрать.
        if level.jobs.isEmpty, document.graph.levels.count > 1 {
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
            .position(x: (lastX ?? contentPadding - 40) + 148, y: nodeY)
        }
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
        .modifier(HoverPulse())
        .help("Добавить отдельную работу на этот уровень")
    }

    private func insertLevelButton(at index: Int) -> some View {
        Button {
            commitEditingIfNeeded()
            document.perform(.insertLevel(at: index))
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Text("уровень")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(HoverPulse(idleOpacity: 0.4))
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

            EdgeShape(
                from: vertical
                    ? CGPoint(x: from.x, y: from.y + (toLevel > fromLevel ? fromR : -fromR))
                    : CGPoint(x: from.x + sign * fromR, y: from.y),
                to: vertical
                    ? CGPoint(x: to.x, y: to.y - (toLevel > fromLevel ? toR + 3 : -(toR + 3)))
                    : CGPoint(x: to.x - sign * (toR + 3), y: to.y),
                vertical: vertical
            )
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
        let isSelected = selection == job.id
        let showsPlus = hoveredJob == job.id || isSelected

        Circle()
            .fill(LevelColors.fill(for: level))
            .overlay(Circle().strokeBorder(LevelColors.stroke(for: level), lineWidth: 2))
            .overlay {
                if isSelected {
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 3)
                        .padding(-5)
                }
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(hoveredJob == job.id ? 1.06 : 1)
            .animation(.spring(duration: 0.25), value: hoveredJob == job.id)
            .position(position)
            .onHover { inside in
                if inside {
                    hoveredJob = job.id
                } else if hoveredJob == job.id {
                    hoveredJob = nil
                }
            }
            .onTapGesture(count: 2) { beginEditing(job) }
            .onTapGesture { select(job.id) }

        if showsPlus {
            // Связанная работа справа — тот же уровень.
            nodePlusButton(help: "Связанная работа справа") {
                commitEditingIfNeeded()
                if let newId = document.perform(.addConnectedRight(of: job.id)) {
                    startEditingNew(newId)
                }
            }
            .position(x: position.x + diameter / 2 + 18, y: position.y)
            .transition(.scale(scale: 0.5).combined(with: .opacity))

            // Связанная работа снизу — уровень ниже.
            nodePlusButton(help: "Связанная работа на уровень ниже") {
                commitEditingIfNeeded()
                if let newId = document.perform(.addConnectedBelow(of: job.id)) {
                    startEditingNew(newId)
                }
            }
            .position(x: position.x - diameter / 2 - 14, y: position.y + diameter / 2 + 14)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }

        if editingId == job.id {
            TextField("role: хочу …", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 220)
                .focused($editorFocused)
                .onSubmit { commitEditing() }
                .onExitCommand { cancelEditing() }
                .onKeyPress(.tab) {
                    commitEditingThenAddBelow()
                    return .handled
                }
                .position(x: position.x, y: position.y + diameter / 2 + 34)
        } else {
            nodeLabel(job, level: level)
                .position(x: position.x, y: position.y + diameter / 2 + 32)
                .onTapGesture(count: 2) { beginEditing(job) }
                .onTapGesture { select(job.id) }
        }
    }

    private func nodePlusButton(help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .background(Circle().fill(.ultraThinMaterial))
                .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(HoverPulse(idleOpacity: 0.85))
        .help(help)
    }

    @ViewBuilder
    private func nodeLabel(_ job: JobNode, level: Int) -> some View {
        VStack(spacing: 0) {
            if let role = job.role {
                Text("\(role):")
                    .font(.system(size: 11, weight: .semibold))
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
            guard let selection else { return false }
            // Без модалки: ⌘Z возвращает работу вместе со связями.
            self.selection = document.perform(.delete(selection))
            return true
        case .escape:
            selection = nil
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
