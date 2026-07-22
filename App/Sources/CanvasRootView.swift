import SwiftUI
import GraphCore

/// Канвас графа работ: автораскладка, zoom/pan, клавиатурное редактирование.
/// Позиции всех узлов — чистая функция от дерева (GraphLayout); ручного
/// перетаскивания нет, поэтому анимация перекладки — просто spring вокруг
/// мутации модели в PetableDocument.perform.
struct CanvasRootView: View {
    @ObservedObject var document: PetableDocument
    @Environment(\.undoManager) private var undoManager

    @State private var selection: UUID?
    @State private var editingId: UUID?
    @State private var draft = ""
    @State private var editingIsNewNode = false
    @FocusState private var editorFocused: Bool

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @StateObject private var focusBridge = CanvasFocusBridge()

    private let contentPadding: CGFloat = 90

    var body: some View {
        let positions = GraphLayout.layout(document.root)

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
            autoEditFreshRoot()
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
            // Рёбра: animatable Shape, интерполируются тем же spring, что и круги.
            ForEach(document.root.allNodes, id: \.id) { node in
                ForEach(node.children, id: \.id) { child in
                    EdgeShape(
                        from: point(positions[node.id]),
                        to: point(positions[child.id])
                    )
                    .stroke(Color.gray.opacity(0.55), lineWidth: 1.5)
                }
            }

            ForEach(document.root.allNodes, id: \.id) { node in
                nodeView(node, at: point(positions[node.id]))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func nodeView(_ node: Job, at position: CGPoint) -> some View {
        let level = document.root.level(of: node.id) ?? 0
        let diameter = LevelStyle.style(for: level).diameter
        let isSelected = selection == node.id

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
            .position(position)
            .onTapGesture(count: 2) { beginEditing(node) }
            .onTapGesture { select(node.id) }

        if editingId == node.id {
            TextField("role: хочу …", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .frame(width: 220)
                .focused($editorFocused)
                .onSubmit { commitEditing() }
                .onExitCommand { cancelEditing() }
                .onKeyPress(.tab) {
                    commitEditingThenAddChild()
                    return .handled
                }
                .position(labelPosition(position, diameter: diameter, level: level))
        } else {
            nodeLabel(node, level: level)
                .position(labelPosition(position, diameter: diameter, level: level))
                .onTapGesture(count: 2) { beginEditing(node) }
                .onTapGesture { select(node.id) }
        }
    }

    @ViewBuilder
    private func nodeLabel(_ node: Job, level: Int) -> some View {
        if level == 0 {
            Text(node.verb)
                .font(.system(size: 15, weight: .bold))
                .lineLimit(2)
                .frame(width: 190, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                if let role = node.role {
                    Text("\(role):")
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(node.verb)
                    .font(.system(size: 11))
                    // Резерв 3 строки — совпадает с labelReserve раскладки;
                    // длиннее — truncation, полный текст в редакторе.
                    .lineLimit(node.role == nil ? 3 : 2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
            }
            .frame(width: LayoutMetrics.columnWidth - 6)
        }
    }

    private func labelPosition(_ nodePosition: CGPoint, diameter: CGFloat, level: Int) -> CGPoint {
        if level == 0, editingId == nil || editingId != document.root.id {
            // Заголовок корня — справа от круга, как в референсе.
            return CGPoint(x: nodePosition.x + diameter / 2 + 105, y: nodePosition.y)
        }
        return CGPoint(x: nodePosition.x, y: nodePosition.y + diameter / 2 + 30)
    }

    private func point(_ position: CGPoint?) -> CGPoint {
        guard let position else { return .zero }
        return CGPoint(x: position.x + contentPadding, y: position.y + contentPadding)
    }

    private func contentSize(_ positions: [UUID: CGPoint]) -> CGSize {
        let maxX = (positions.values.map(\.x).max() ?? 0) + contentPadding * 2 + 120
        let maxY = (positions.values.map(\.y).max() ?? 0) + contentPadding * 2 + 60
        return CGSize(width: max(maxX, 800), height: max(maxY, 600))
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
            let target = selection ?? document.root.id
            if let newId = document.perform(.addChild(of: target)) {
                startEditingNew(newId)
            }
            return true
        case .cmdReturn:
            guard let selection else { return false }
            if let newId = document.perform(.addSiblingAfter(selection)) {
                startEditingNew(newId)
            }
            return true
        case .enter:
            guard let selection, let node = document.root.find(selection) else { return false }
            beginEditing(node)
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
            // Без модалки: ⌘Z возвращает поддерево. На корне — no-op в движке.
            self.selection = document.perform(.delete(selection)) ?? self.selection
            return true
        case .escape:
            selection = nil
            return true
        case .left, .right:
            return moveSelectionSibling(key == .right ? 1 : -1)
        case .up:
            guard let selection, let parent = document.root.parent(of: selection) else { return false }
            select(parent.id)
            return true
        case .down:
            guard let selection, let first = document.root.find(selection)?.children.first else { return false }
            select(first.id)
            return true
        }
    }

    private func moveSelectionSibling(_ delta: Int) -> Bool {
        guard let selection,
              let parent = document.root.parent(of: selection),
              let index = parent.children.firstIndex(where: { $0.id == selection })
        else { return false }
        let target = index + delta
        guard target >= 0, target < parent.children.count else { return false }
        select(parent.children[target].id)
        return true
    }

    private func select(_ id: UUID) {
        commitEditingIfNeeded()
        selection = id
    }

    // MARK: - Инлайн-редактирование

    private func beginEditing(_ node: Job) {
        selection = node.id
        draft = node.displayText
        editingIsNewNode = false
        editingId = node.id
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
        // Движок сам решает: пустой текст → удалить новый узел /
        // плейсхолдер на корне / no-op на существующем.
        let focus = document.perform(.setText(id, raw: draft))
        if document.root.find(id) == nil {
            selection = focus ?? document.root.id
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
            document.perform(.setText(id, raw: ""))
            selection = document.root.find(id) == nil ? document.root.id : id
        }
        focusBridge.focusCanvas()
    }

    private func commitEditingThenAddChild() {
        guard let id = editingId else { return }
        commitEditing()
        guard document.root.find(id) != nil else { return }
        if let newId = document.perform(.addChild(of: id)) {
            startEditingNew(newId)
        }
    }

    /// Новый документ открывается с корнем в режиме редактирования.
    private func autoEditFreshRoot() {
        if document.root.verb == GraphEngine.rootPlaceholder, document.root.children.isEmpty {
            beginEditing(document.root)
            draft = ""
        }
    }
}
