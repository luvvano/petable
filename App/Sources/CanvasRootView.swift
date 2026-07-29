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
    /// Инлайн-переименование области уровня (двойной клик по её имени).
    @State private var editingZoneId: UUID?
    @State private var zoneDraft = ""
    @FocusState private var zoneEditorFocused: Bool

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
    /// Подсветка поддерева «работы ниже»: работы вне набора приглушаются.
    /// nil — режим подсветки выключен.
    @State private var highlightedJobs: Set<UUID>?
    /// Карточка работы (двойной клик по узлу): id открытой + черновик
    /// полей. Черновик коммитится одним интентом при закрытии карточки
    /// и при выходе из режима редактирования.
    @State private var detailsId: UUID?
    @State private var detailsDraft = JobDetails()
    /// Режим карточки: false — отформатированный просмотр, true — редактор
    /// (карандаш в шапке). Пустая карточка открывается сразу в редакторе.
    @State private var detailsEditing = false
    @StateObject private var focusBridge = CanvasFocusBridge()

    /// Перетаскивание работы (нажать на узел и вести): работа следует за
    /// курсором, отпускание — перенос на уровень/позицию под курсором.
    @State private var dragNode: NodeDrag?

    /// Палитра механик ценности (⌘K).
    @State private var mechanicsShown = false
    /// Слаг механики под курсором списка — по ней канвас рисует призрак.
    @State private var mechanicHighlight: String?
    /// Взведённая механика: палитра закрыта, курсор — прицел, клик по
    /// работе (или связи) применяет её к цели. Esc — отбой.
    @State private var armedMechanic: String?

    private static let contentSpace = "canvas-content"

    /// Живой призрак: union-граф + судьбы + дельта. Считается только для
    /// применимой топологической механики; карточные и стикеры канвас
    /// не трогают.
    private struct GhostState {
        var overlay: MechanicGhost.Overlay
        var delta: WorkGraph.Delta
    }

    private var mechanicAnchor: MechanicAnchor {
        if let edge = selectedEdge { return .chainEdge(from: edge.from, to: edge.to) }
        if let selection { return .node(selection) }
        return .unanchored
    }

    /// Работа под курсором — цель взведённой механики. Радиус чуть больше
    /// круга, как у ховера узла.
    private var hoveredJobID: UUID? {
        guard let cursor = cursorPosition else { return nil }
        let positions = GraphLayout.layout(document.graph)
        for (levelIndex, level) in document.graph.levels.enumerated() {
            let radius = document.graph.style(atLevel: levelIndex).diameter / 2 + 8
            for job in level.jobs {
                guard let position = positions[job.id] else { continue }
                let point = point(position)
                if hypot(cursor.x - point.x, cursor.y - point.y) <= radius {
                    return job.id
                }
            }
        }
        return nil
    }

    private var activeGhost: GhostState? {
        guard case let .success(catalog) = MechanicCatalogStore.result else { return nil }
        // Два источника призрака: палитра (механика под курсором списка,
        // якорь — текущее выделение) и взведённый режим (якорь — работа
        // под курсором мыши: видно, что случится, ДО клика).
        let slug: String
        let anchor: MechanicAnchor
        if mechanicsShown, let highlighted = mechanicHighlight {
            slug = highlighted
            anchor = mechanicAnchor
        } else if let armed = armedMechanic, let hovered = hoveredJobID {
            slug = armed
            anchor = .node(hovered)
        } else {
            return nil
        }
        guard let mechanic = catalog.mechanic(slug),
              mechanic.mechanicClass == .topology,
              case let .success(preview) = MechanicTransform.preview(
                  slug, in: document.graph, anchor: anchor
              )
        else { return nil }
        return GhostState(
            overlay: MechanicGhost.overlay(current: document.graph, preview: preview),
            delta: document.graph.delta(to: preview)
        )
    }

    private struct DragLink {
        var from: UUID
        var fromPoint: CGPoint
        var current: CGPoint
    }

    private struct NodeDrag {
        var id: UUID
        var current: CGPoint
    }

    private let contentPadding: CGFloat = 90
    private let bandInset: CGFloat = 24
    /// Центр узла лежит на этом расстоянии от верхней кромки полосы.
    private let nodeOffsetInBand: CGFloat = 50
    private var bandHeight: CGFloat { LayoutMetrics.rowHeight - 10 }

    var body: some View {
        // Призрак активен — раскладывается union-граф (P2a): одна
        // геометрия на выживших и фантомов, глобальный сдвиг общий.
        let ghost = activeGhost
        let renderGraph = ghost?.overlay.union ?? document.graph
        let geometry = GraphLayout.geometry(renderGraph)

        ZStack(alignment: .topLeading) {
            CanvasHostView(
                onKey: handleKey,
                onPan: { delta in
                    offset.width += delta.width
                    offset.height += delta.height
                },
                onZoom: applyZoom,
                onClickEmpty: {
                    // Клик по пустому месту при взведённой механике —
                    // отбой: промахнулся или передумал.
                    if armedMechanic != nil {
                        disarmMechanic()
                        return
                    }
                    commitEditingIfNeeded()
                    // Клик мимо карточки закрывает её (черновик коммитится) —
                    // конвенция поповера: клик наружу = «готово».
                    closeDetails()
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
                canCopy: { copyableJobs != nil },
                onCopy: { copySelectedJobs() },
                canPaste: { ExportImport.hasJobsInClipboard },
                onPaste: { location in
                    // Правый клик по пустому месту знает свою точку;
                    // ⌘V и меню «Правка» — по курсору.
                    guard let location else {
                        pasteJobs()
                        return
                    }
                    pasteJobs(anchorLevel: levelIndex(atViewPoint: location))
                },
                focusBridge: focusBridge
            )

            graphContent(geometry, graph: renderGraph, ghost: ghost?.overlay)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(offset)
                // Призрак из палитры — только просмотр. Во взведённом
                // режиме клики нужны: по узлу стреляет механика.
                .allowsHitTesting(ghost == nil || armedMechanic != nil)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .bottomTrailing) { zoomControls }
        .overlay(alignment: .bottom) {
            if showsHints { hintsBar }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                if let armed = armedMechanic {
                    // Чип взведённой механики: что выбрано, куда кликать,
                    // как отменить. Виден, пока курсор ищет цель.
                    HStack(spacing: 6) {
                        Image(systemName: "scope")
                            .font(.system(size: 10, weight: .semibold))
                        Text("«\(mechanicTitle(armed))» — \(armedTargetHint(armed))")
                        Text("Esc — отмена")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1))
                    .transition(.opacity)
                }
                if let ghost, !ghost.delta.isEmpty {
                    // Строка дельты: только реально случившееся, точная, не
                    // эффектная. Живёт над канвасом, пока призрак активен.
                    Text(ghost.delta.summary)
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.separator, lineWidth: 1))
                        .transition(.opacity)
                }
            }
            .padding(.top, 10)
        }
        // Прицел вместо стрелки, пока механика взведена: курсор сам
        // говорит «выбери цель».
        .onContinuousHover { phase in
            guard armedMechanic != nil else { return }
            switch phase {
            case .active: NSCursor.crosshair.set()
            case .ended: NSCursor.arrow.set()
            }
        }
        .overlay {
            if mechanicsShown {
                mechanicPaletteOverlay
            }
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
            },
            canCollapse: chainState.hasChain && !chainState.isCollapsed,
            canExpand: chainState.hasChain && chainState.isCollapsed,
            collapseChain: {
                guard let selection, let job = document.graph.job(selection) else { return }
                if !job.isCollapsed { toggleChain(job) }
            },
            expandChain: {
                guard let selection, let job = document.graph.job(selection) else { return }
                if job.isCollapsed { toggleChain(job) }
            },
            canCopy: copyableJobs != nil,
            copyJobs: { copySelectedJobs() },
            pasteJobs: { pasteJobs() },
            // Через меню, а не canvasKey: тот работает только пока канвас —
            // first responder, а ⌘K должен открываться и из карточки работы.
            showMechanics: { openMechanicPalette() }
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
        .onChange(of: zoneEditorFocused) { _, focused in
            if !focused { commitZoneEditingIfNeeded() }
        }
        .onChange(of: document.selectedGraphID) { _, _ in
            // Смена графа: правка чужого узла невозможна — редактор
            // сбрасывается без коммита, новый пустой граф сразу в редакторе.
            editingId = nil
            editingLevelId = nil
            editingZoneId = nil
            selection = nil
            selectedEdge = nil
            dragLink = nil
            dragNode = nil
            highlightedJobs = nil
            detailsId = nil
            mechanicsShown = false
            mechanicHighlight = nil
            disarmMechanic()
            autoEditFreshDocument()
        }
    }

    // MARK: - Механики ценности

    /// Оверлей палитры. Центрируется по видимой части канваса — при
    /// открытой панели агента detail-колонка уже, и палитра не должна
    /// вылезать под неё.
    @ViewBuilder
    private var mechanicPaletteOverlay: some View {
        ZStack(alignment: .top) {
            // Клик мимо палитры закрывает её — конвенция поповера.
            // Почти прозрачный, но кликабельный фон ловит промахи.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { closeMechanicPalette() }

            switch MechanicCatalogStore.result {
            case let .success(catalog):
                MechanicPaletteView(
                    catalog: catalog,
                    anchor: mechanicAnchor,
                    graph: document.graph,
                    highlighted: $mechanicHighlight,
                    onApply: { mechanic, note in applyMechanic(mechanic, note: note) },
                    onArm: { mechanic in armMechanic(mechanic) },
                    onFork: { mechanic in forkMechanic(mechanic) },
                    onClose: { closeMechanicPalette() }
                )
                .padding(.top, 46)
            case let .failure(error):
                MechanicCatalogErrorView(error: error) { closeMechanicPalette() }
                    .padding(.top, 46)
            }
        }
    }

    /// Тултип бейджа стикеров: заголовок механики + заметка.
    private func stickerHelp(_ stickers: [MechanicSticker]) -> String {
        stickers.map { sticker in
            let title = mechanicTitle(sticker.slug)
            return sticker.note.isEmpty ? title : "\(title): \(sticker.note)"
        }
        .joined(separator: "\n")
    }

    /// Русский заголовок механики; слаг как есть, если каталог не загрузился.
    private func mechanicTitle(_ slug: String) -> String {
        guard case let .success(catalog) = MechanicCatalogStore.result,
              let mechanic = catalog.mechanic(slug)
        else { return slug }
        return mechanic.title
    }

    private func openMechanicPalette() {
        commitEditingIfNeeded()
        closeDetails()
        disarmMechanic()
        mechanicsShown = true
    }

    private func closeMechanicPalette() {
        withAnimation(.spring(duration: 0.35)) {
            mechanicsShown = false
            mechanicHighlight = nil
        }
    }

    // MARK: Взведённый режим

    /// Клик по механике в палитре: палитра закрывается, курсор — прицел,
    /// следующий клик по работе (или связи) применяет механику к ней.
    private func armMechanic(_ mechanic: Mechanic) {
        closeMechanicPalette()
        armedMechanic = mechanic.slug
        NSCursor.crosshair.set()
    }

    private func disarmMechanic() {
        guard armedMechanic != nil else { return }
        armedMechanic = nil
        NSCursor.arrow.set()
    }

    /// Подсказка чипа: куда кликать взведённой механикой.
    private func armedTargetHint(_ slug: String) -> String {
        guard case let .success(catalog) = MechanicCatalogStore.result,
              let mechanic = catalog.mechanic(slug)
        else { return "кликните по работе" }
        if mechanic.mechanicClass == .topology, isChainEdgeMechanic(slug) {
            return "кликните по связи внутри уровня"
        }
        switch mechanic.mechanicClass {
        case .topology: return "кликните по работе"
        case .jobCard: return "кликните по работе — правка карточки"
        case .sticker: return "кликните по работе — повесить заметку"
        }
    }

    /// Механики, чей якорь — связь, а не работа.
    private func isChainEdgeMechanic(_ slug: String) -> Bool {
        ["reduce-hand-offs", "fix-chain-breaks-between-people", "fix-unperformed-jobs-in-chain"]
            .contains(slug)
    }

    /// Выстрел взведённой механикой по работе.
    private func fireArmedMechanic(atNode id: UUID) {
        guard let slug = armedMechanic,
              case let .success(catalog) = MechanicCatalogStore.result,
              let mechanic = catalog.mechanic(slug)
        else { disarmMechanic(); return }
        // Механика связи по клику в узел не стреляет — чип уже объясняет,
        // куда целиться; взвод не сбрасывается.
        guard !isChainEdgeMechanic(slug) else { return }
        applyMechanic(mechanic, note: "", anchor: .node(id))
        disarmMechanic()
    }

    /// Выстрел взведённой механикой по связи.
    private func fireArmedMechanic(atEdge edge: JobEdge) {
        guard let slug = armedMechanic,
              case let .success(catalog) = MechanicCatalogStore.result,
              let mechanic = catalog.mechanic(slug)
        else { disarmMechanic(); return }
        guard isChainEdgeMechanic(slug) else { return }
        applyMechanic(mechanic, note: "", anchor: .chainEdge(from: edge.from, to: edge.to))
        disarmMechanic()
    }

    /// Enter в палитре или выстрел взведённой механикой: топология —
    /// заменить граф превью (⌘Z откатывает), карточка — правка через
    /// .setDetails или редактор карточки, стикер — заметка на якоре.
    private func applyMechanic(_ mechanic: Mechanic, note: String, anchor: MechanicAnchor? = nil) {
        let anchor = anchor ?? mechanicAnchor
        switch mechanic.mechanicClass {
        case .topology:
            guard case let .success(preview) = MechanicTransform.preview(
                mechanic.slug, in: document.graph, anchor: anchor
            ) else { return }
            document.applyMechanicPreview(preview)
            closeMechanicPalette()
        case .jobCard:
            guard case let .node(id) = anchor,
                  case let .success(details) = MechanicTransform.cardPreview(
                      mechanic.slug, in: document.graph, anchor: anchor
                  ),
                  let job = document.graph.job(id)
            else { return }
            if details != job.details {
                // Детерминированная правка (перенос эмоций) — интентом.
                document.perform(.setDetails(id, details: details))
                closeMechanicPalette()
            } else {
                // Критериальные механики: новые пороги пишет человек —
                // палитра закрывается, открывается редактор карточки.
                closeMechanicPalette()
                openDetails(job)
            }
        case .sticker:
            document.addMechanicSticker(
                MechanicSticker(slug: mechanic.slug, anchor: anchor, note: note)
            )
            closeMechanicPalette()
        }
    }

    /// ⌥Enter: граф-потомок с применённой механикой. Для стикеров форк —
    /// копия графа со стикером: гипотеза уезжает в отдельную ветку.
    private func forkMechanic(_ mechanic: Mechanic) {
        // Происхождение снимается ДО применения: kill-a-job удаляет якорь.
        let origin = MechanicOrigin.capture(
            slug: mechanic.slug, anchor: mechanicAnchor, in: document.graph
        )
        switch mechanic.mechanicClass {
        case .topology:
            guard case let .success(preview) = MechanicTransform.preview(
                mechanic.slug, in: document.graph, anchor: mechanicAnchor
            ) else { return }
            document.forkWithMechanic(
                preview: preview, origin: origin, mechanicTitle: mechanic.title
            )
        case .jobCard:
            guard case let .node(id) = mechanicAnchor,
                  case let .success(details) = MechanicTransform.cardPreview(
                      mechanic.slug, in: document.graph, anchor: mechanicAnchor
                  )
            else { return }
            var preview = document.graph
            for levelIndex in preview.levels.indices {
                for jobIndex in preview.levels[levelIndex].jobs.indices
                where preview.levels[levelIndex].jobs[jobIndex].id == id {
                    preview.levels[levelIndex].jobs[jobIndex].details = details
                }
            }
            document.forkWithMechanic(
                preview: preview, origin: origin, mechanicTitle: mechanic.title
            )
        case .sticker:
            document.forkWithMechanic(
                preview: document.graph, origin: origin, mechanicTitle: mechanic.title
            )
        }
        closeMechanicPalette()
    }

    // MARK: - Рендер

    @ViewBuilder
    private func graphContent(
        _ geometry: GraphLayout.Geometry,
        graph: WorkGraph,
        ghost: MechanicGhost.Overlay?
    ) -> some View {
        let positions = geometry.positions
        let size = contentSize(geometry)

        ZStack(alignment: .topLeading) {
            // Точечная сетка — ощущение бесконечной доски; масштабируется
            // вместе с контентом.
            dotGrid(size: size)

            // Полосы уровней — фон, событий не перехватывают: клики по
            // пустому месту уходят в CanvasHostView (deselect), hover не ломают.
            // Полоса под перетаскиваемой работой подсвечена — цель переноса.
            let drop = dragNode.flatMap { drag in
                dropTarget(for: drag.current, excluding: drag.id, geometry: geometry)
            }
            ForEach(Array(graph.levels.enumerated()), id: \.element.id) { index, _ in
                bandBackground(
                    index: index,
                    width: size.width,
                    // Целится в область — подсвечена её рамка, не вся полоса.
                    isDropTarget: index == drop?.levelIndex && drop?.zoneID == nil
                )
                .allowsHitTesting(false)
            }

            // Рамки областей: та же полоса, но отдельная область — работы
            // того же уровня, которые продукт не выполняет.
            ForEach(graph.levels) { level in
                ForEach(level.zones) { zone in
                    if let span = geometry.zones[zone.id] {
                        zoneBackground(
                            zone,
                            span: span,
                            isDropTarget: drop?.zoneID == zone.id
                        )
                        .allowsHitTesting(false)
                    }
                }
            }

            // Рёбра: animatable Shape, интерполируются тем же spring, что и круги.
            // При призраке ушедшие рёбра приглушены, новые — пунктиром.
            ForEach(graph.edges, id: \.self) { edge in
                edgeView(
                    edge,
                    positions: positions,
                    graph: graph,
                    ghostStyle: ghost.flatMap { overlay in
                        if overlay.removedEdges.contains(edge) { return .removed }
                        if overlay.addedEdges.contains(edge) { return .added }
                        return nil
                    }
                )
            }

            // Узлы. Работа свёрнутой цепочки позиции не имеет — раскладка
            // её не разместила, значит на канвасе её нет.
            ForEach(Array(graph.levels.enumerated()), id: \.element.id) { levelIndex, level in
                ForEach(level.jobs) { job in
                    if let position = positions[job.id] {
                        nodeView(job, level: levelIndex, at: point(position), fate: ghost?.fates[job.id])
                    }
                }
            }

            // Контролы и карточка при призраке спрятаны: они читают
            // document.graph, а на экране union — их клики врали бы.
            if ghost == nil {
                // Контролы уровней: добавить работу/область, вставить/удалить уровень.
                ForEach(Array(graph.levels.enumerated()), id: \.element.id) { index, level in
                    bandControls(index: index, level: level, geometry: geometry)
                }

                // Карточка работы — поверх узлов, справа от открытой работы.
                if let detailsId, let detailsJob = graph.job(detailsId),
                   let detailsLevel = graph.levelIndex(of: detailsId),
                   let detailsPoint = positions[detailsId] {
                    detailsCard(detailsJob, level: detailsLevel, at: point(detailsPoint))
                }
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
    private func bandBackground(index: Int, width: CGFloat, isDropTarget: Bool = false) -> some View {
        let top = bandTop(index)
        // Цвет полосы — из стиля уровня: у core-уровня он свой и не едет
        // по шкале, когда сверху вставляют новую полосу.
        let style = document.graph.style(atLevel: index)

        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(LevelColors.fill(style).opacity(isDropTarget ? 0.16 : 0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LevelColors.stroke(style).opacity(isDropTarget ? 0.55 : 0.18),
                        lineWidth: isDropTarget ? 1.5 : 1
                    )
            )
            .frame(width: width - bandInset * 2, height: bandHeight)
            .offset(x: bandInset, y: top)
            .animation(.easeOut(duration: 0.15), value: isDropTarget)
    }

    // MARK: Области уровня

    /// Вертикальные отступы рамки области от кромок полосы уровня.
    private let zoneInset: CGFloat = 7
    private var zoneHeight: CGFloat { bandHeight - zoneInset * 2 }

    private func zoneRect(_ span: GraphLayout.ZoneSpan) -> CGRect {
        CGRect(
            x: span.minX + contentPadding,
            y: bandTop(span.levelIndex) + zoneInset,
            width: span.width,
            height: zoneHeight
        )
    }

    /// Рамка области внутри полосы уровня: тот же ряд (уровень тот же),
    /// но отдельная область с собственным именем и пунктирным контуром —
    /// работы, которые продукт не выполняет.
    @ViewBuilder
    private func zoneBackground(
        _ zone: LevelZone,
        span: GraphLayout.ZoneSpan,
        isDropTarget: Bool
    ) -> some View {
        let rect = zoneRect(span)

        RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(LevelColors.zoneFill.opacity(isDropTarget ? 0.2 : 0.1))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(
                        LevelColors.zoneStroke.opacity(isDropTarget ? 0.85 : 0.5),
                        style: StrokeStyle(
                            lineWidth: isDropTarget ? 1.8 : 1.3,
                            dash: [6, 5]
                        )
                    )
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .animation(.easeOut(duration: 0.15), value: isDropTarget)
    }

    /// Имя области — горизонтально у верхней кромки её рамки.
    /// Двойной клик — переименование (как у уровня).
    @ViewBuilder
    private func zoneLabel(_ zone: LevelZone, span: GraphLayout.ZoneSpan) -> some View {
        let rect = zoneRect(span)

        if editingZoneId == zone.id {
            TextField(LevelZone.defaultName, text: $zoneDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .multilineTextAlignment(.center)
                .focused($zoneEditorFocused)
                .onSubmit { commitZoneEditing() }
                .onExitCommand { cancelZoneEditing() }
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
                .position(x: rect.midX, y: rect.minY - 2)
        } else {
            // Метрики × zoom + обратный scaleEffect — резкий текст (см. nodeLabel).
            // События ловит только сама плашка: пустая часть контейнера
            // не перехватывает клики по канвасу.
            let badge = Text(zone.resolvedName.uppercased())
                .font(.system(size: 9 * scale, weight: .bold, design: .rounded))
                .tracking(1.2 * scale)
                .foregroundStyle(LevelColors.zoneStroke.opacity(0.95))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7 * scale)
                .padding(.vertical, 2.5 * scale)
                .background(
                    Capsule().fill(Color(nsColor: .textBackgroundColor).opacity(0.9))
                )
                .overlay(
                    Capsule().strokeBorder(LevelColors.zoneStroke.opacity(0.35), lineWidth: 1)
                )
                .contentShape(Capsule())
                .onTapGesture(count: 2) { beginZoneEditing(zone) }
                .contextMenu {
                    Button("Переименовать область") { beginZoneEditing(zone) }
                    Button("Убрать область (работы останутся на уровне)") {
                        commitEditingIfNeeded()
                        document.perform(.deleteZone(zone.id))
                    }
                }
                .help("Отдельная область уровня: работы того же уровня, "
                      + "которые продукт не выполняет целиком. "
                      + "Двойной клик — переименовать")

            // Контейнер известной ширины — плашка липнет к левому
            // верхнему углу рамки при любой её длине.
            badge
                .frame(width: rect.width * scale, alignment: .leading)
                .scaleEffect(1 / scale)
                .position(x: rect.midX, y: rect.minY)
        }
    }

    /// Имя уровня вертикально у левой кромки полосы — не пересекается
    /// ни с узлами, ни с подписями при любой плотности графа.
    /// Двойной клик — инлайн-переименование; рендерится в слое контролов
    /// (bandBackground events не принимает).
    /// Дефолтное имя уровня без пользовательского: core-уровень — всегда
    /// «CORE JOBS», остальные — по номеру.
    private func defaultLevelName(_ level: GraphLevel, index: Int) -> String {
        level.isCore ? "CORE JOBS" : "УРОВЕНЬ \(index + 1)"
    }

    @ViewBuilder
    private func levelLabel(index: Int, level: GraphLevel, top: CGFloat) -> some View {
        if editingLevelId == level.id {
            TextField(defaultLevelName(level, index: index), text: $levelDraft)
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
            // Метрики × zoom + обратный scaleEffect — резкий текст при
            // приближении (см. nodeLabel).
            Text(level.name?.uppercased() ?? defaultLevelName(level, index: index))
                .font(.system(size: 9 * scale, weight: .bold, design: .rounded))
                .tracking(1.4 * scale)
                .foregroundStyle(LevelColors.stroke(document.graph.style(atLevel: index)).opacity(level.isCore ? 0.95 : 0.65))
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: bandHeight * scale)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { beginLevelEditing(level) }
                .contextMenu {
                    Button("Переименовать") { beginLevelEditing(level) }
                    if !level.isCore {
                        Button("Сделать уровнем Core Jobs") {
                            document.perform(.setCoreLevel(level.id))
                        }
                    }
                    // Область — разметка «рядом с кóровыми»: только на core.
                    if level.isCore {
                        Divider()
                        Button("Добавить область (тот же уровень, продукт не выполняет)") {
                            commitEditingIfNeeded()
                            if let newId = document.perform(.addZone(level: level.id)) {
                                startEditingNew(newId)
                            }
                        }
                    }
                }
                .scaleEffect(1 / scale)
                .rotationEffect(.degrees(-90))
                .position(x: bandInset - 12, y: top + bandHeight / 2)
                .help(level.isCore
                    ? "Core Jobs — работы, которые продукт выполняет целиком. Двойной клик — переименовать"
                    : "Двойной клик — переименовать уровень")
        }
    }

    /// Кнопки полосы: «+ работа» в конце ряда, вставка уровня на стыках,
    /// удаление пустого уровня. Появляются только рядом с курсором
    /// (proximity-reveal) — канвас остаётся чистым, кнопка находится
    /// движением в её сторону.
    @ViewBuilder
    private func bandControls(index: Int, level: GraphLevel, geometry: GraphLayout.Geometry) -> some View {
        let positions = geometry.positions
        let top = bandTop(index)
        let nodeY = top + nodeOffsetInBand
        // Правый край занятого места на полосе: работы и рамки областей.
        let lastJobX = level.jobs(in: nil).compactMap { positions[$0.id]?.x }.max()
            .map { $0 + contentPadding }
        let zoneEdges = level.zones.compactMap { zone in
            geometry.zones[zone.id].map { $0.maxX + contentPadding }
        }
        let lastX = ([lastJobX].compactMap { $0 } + zoneEdges).max()

        levelLabel(index: index, level: level, top: top)

        // Автономная работа — в конец основной области уровня. Кнопка
        // не заезжает на рамку области: иначе клик по ней читается как
        // «добавить работу в эту область», а работа уходит в основную.
        // Места слева от первой рамки нет (у уровня нет своих работ) —
        // кнопка уходит правее всего содержимого полосы.
        let firstZoneMinX = level.zones
            .compactMap { geometry.zones[$0.id]?.minX }
            .min()
            .map { $0 + contentPadding }
        let mainSpot = (lastJobX ?? contentPadding - 40) + 96
        let collidesWithZone = firstZoneMinX.map { mainSpot + 45 > $0 } ?? false
        let addJobPoint = CGPoint(
            x: collidesWithZone ? (lastX ?? contentPadding - 40) + 96 : mainSpot,
            y: nodeY
        )
        addJobButton(level: level)
            .proximityReveal(reveal(near: addJobPoint))
            .position(addJobPoint)

        // Новая область уровня — правее всего содержимого полосы.
        // Только у core: малые работы — соседи кóровых, на других
        // уровнях области не заводятся.
        if level.isCore {
            let addZonePoint = CGPoint(x: (lastX ?? contentPadding - 40) + 220, y: nodeY)
            addZoneButton(level: level)
                .proximityReveal(reveal(near: addZonePoint))
                .position(addZonePoint)
        }

        // Контролы каждой области: имя, «+ работа» внутри рамки, удаление.
        ForEach(level.zones) { zone in
            if let span = geometry.zones[zone.id] {
                zoneControls(zone, span: span, levelIndex: index)
            }
        }

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

        // Пустой уровень можно убрать; core-уровень — нельзя.
        if level.jobs.isEmpty, !level.isCore, document.graph.levels.count > 1 {
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
        plusCapsule(
            title: "работа",
            tint: .accentColor,
            help: "Добавить отдельную работу на этот уровень"
        ) {
            commitEditingIfNeeded()
            if let newId = document.perform(.addJob(level: level.id)) {
                startEditingNew(newId)
            }
        }
    }

    /// Новая область уровня: та же полоса, отдельная рамка — малые работы
    /// рядом с кóровыми. Показывается только у core-уровня.
    private func addZoneButton(level: GraphLevel) -> some View {
        plusCapsule(
            title: "область",
            tint: LevelColors.zoneStroke,
            labelColor: LevelColors.zoneStroke,
            help:"Добавить область на уровне Core Jobs — работы того же "
                + "уровня, которые продукт не выполняет целиком "
                + "(малые работы рядом с кóровыми). Новая область встаёт "
                + "справа от всего содержимого полосы, не внутри существующей"
        ) {
            commitEditingIfNeeded()
            if let newId = document.perform(.addZone(level: level.id)) {
                startEditingNew(newId)
            }
        }
    }

    /// Контролы области: имя сверху, «+ работа» у правой кромки рамки,
    /// корзина у пустой области.
    @ViewBuilder
    private func zoneControls(
        _ zone: LevelZone,
        span: GraphLayout.ZoneSpan,
        levelIndex: Int
    ) -> some View {
        let rect = zoneRect(span)
        let isEmpty = document.graph.levels[levelIndex].jobs(in: zone.id).isEmpty

        zoneLabel(zone, span: span)

        let addPoint = CGPoint(x: rect.maxX + 46, y: rect.midY)
        plusCapsule(
            title: "работа",
            tint: LevelColors.zoneStroke,
            labelColor: LevelColors.zoneStroke,
            help:"Добавить работу в область «\(zone.resolvedName)»"
        ) {
            commitEditingIfNeeded()
            if let newId = document.perform(.addJob(
                level: document.graph.levels[levelIndex].id,
                zone: zone.id
            )) {
                startEditingNew(newId)
            }
        }
        .proximityReveal(reveal(near: addPoint))
        .position(addPoint)

        if isEmpty {
            let trashPoint = CGPoint(x: rect.maxX + 120, y: rect.midY)
            Button {
                document.perform(.deleteZone(zone.id))
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
            .help("Убрать пустую область")
            .proximityReveal(reveal(near: trashPoint))
            .position(trashPoint)
        }
    }

    /// Капсула «+ что-то» — общий вид кнопок добавления на полосе.
    /// `tint` красит контур; текст области — тем же цветом, чтобы кнопка
    /// читалась как относящаяся к рамке, а не к уровню.
    private func plusCapsule(
        title: String,
        tint: Color,
        labelColor: Color? = nil,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(labelColor ?? Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(tint.opacity(0.4), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(HoverPulse(idleOpacity: 0.9))
        .help(help)
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

    /// Стиль ребра при живом призраке.
    private enum GhostEdgeStyle {
        /// Ушло в превью — приглушено.
        case removed
        /// Появилось в превью — пунктир акцентным цветом.
        case added
    }

    @ViewBuilder
    private func edgeView(
        _ edge: JobEdge,
        positions: [UUID: CGPoint],
        graph: WorkGraph,
        ghostStyle: GhostEdgeStyle? = nil
    ) -> some View {
        // Конец в свёрнутой цепочке — позиции нет, линию рисовать некуда.
        // При призраке graph = union: рёбра к добавленным работам ищут
        // уровни в нём, а не в document.graph, где этих работ ещё нет.
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
                ? detourWaypoints(start: start, end: end, fromLevel: fromLevel,
                                  toLevel: toLevel, positions: positions, graph: graph)
                : []
            let shape = EdgeShape(from: start, to: end, vertical: vertical, waypoints: waypoints)
            let isSelected = selectedEdge == edge
            // Ребро приглушается, если хотя бы один конец вне подсветки.
            let isDimmed = highlightedJobs.map {
                !($0.contains(edge.from) && $0.contains(edge.to))
            } ?? false

            shape
                .stroke(
                    ghostStyle == .added
                        ? Color.accentColor
                        : (isSelected ? Color.accentColor : Color.gray.opacity(0.5)),
                    style: StrokeStyle(
                        lineWidth: isSelected ? 2.5 : 1.5,
                        lineCap: .round,
                        dash: ghostStyle == .added ? [5, 4] : []
                    )
                )
                .opacity(ghostStyle == .removed ? 0.2 : (isDimmed ? 0.2 : 1))
                // Хит-зона — сама линия, раздутая до 16pt; клики мимо линии
                // проходят дальше (пустота, узлы).
                .contentShape(EdgeHitShape(base: shape))
                .onTapGesture {
                    if armedMechanic != nil {
                        fireArmedMechanic(atEdge: edge)
                    } else {
                        selectEdge(edge)
                    }
                }
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
        positions: [UUID: CGPoint],
        graph: WorkGraph? = nil
    ) -> [CGPoint] {
        GraphLayout.detourWaypoints(
            graph: graph ?? document.graph, positions: positions,
            start: start, end: end,
            fromLevel: fromLevel, toLevel: toLevel,
            padding: contentPadding
        )
    }

    // MARK: Узлы

    @ViewBuilder
    private func nodeView(
        _ job: JobNode,
        level: Int,
        at basePosition: CGPoint,
        fate: MechanicGhost.JobFate? = nil
    ) -> some View {
        let style = document.graph.style(atLevel: level)
        let diameter = style.diameter
        let isSelected = selection == job.id
        // Перетаскиваемая работа следует за курсором; остальные — на местах.
        let isDragging = dragNode?.id == job.id
        let position = isDragging ? (dragNode?.current ?? basePosition) : basePosition
        // Ховер — от позиции курсора, не от onHover: тот теряет exit-события
        // при частых пересборках канваса и «залипает».
        let isHovered = cursorWithin(position, diameter / 2 + 8)
        let plusRight = CGPoint(x: position.x + diameter / 2 + 18, y: position.y)
        let plusBelow = CGPoint(x: position.x - diameter / 2 - 14, y: position.y + diameter / 2 + 14)
        // Кнопка сворачивания — над плюсом справа: обе про то, что
        // происходит справа от работы, но по разным делам.
        let collapseControl = CGPoint(x: position.x + diameter / 2 + 16, y: position.y - diameter / 2 - 12)
        // Цепочка работ уровня справа от этой: пока её нет, сворачивать нечего.
        let chain = document.graph.chain(after: job.id)
        let isCollapsed = job.isCollapsed && !chain.isEmpty
        // Зоны плюсов держат кнопки видимыми по пути от круга до клика;
        // источник активного связывания не должен исчезнуть посреди drag.
        // Во время переноса работы плюсы спрятаны.
        let showsPlus = dragNode == nil && (isSelected || isHovered || dragLink?.from == job.id
            || cursorWithin(plusRight, 20) || cursorWithin(plusBelow, 20)
            || cursorWithin(collapseControl, 20))
        // Узел под резиновой линией — подсветка цели связывания.
        let isLinkTarget = dragLink.map {
            $0.from != job.id
                && hypot($0.current.x - position.x, $0.current.y - position.y) <= diameter / 2 + 12
        } ?? false
        // Работа вне подсвеченного поддерева — приглушена.
        let isDimmed = highlightedJobs.map { !$0.contains(job.id) } ?? false

        // Работа в области уровня: размер тот же (уровень тот же),
        // контур пунктирный — продукт её не выполняет.
        let inZone = job.zoneID != nil

        // Стикеры механик, повешенные на эту работу (Enter в палитре на
        // механике без структурной формы).
        let nodeStickers = document.stickers.filter { $0.anchor == .node(job.id) }

        // Круг рендерится в размере × zoom и сжимается обратно — резкие
        // контуры при приближении (тот же приём, что у подписей).
        Circle()
            .fill(LevelColors.fill(style))
            .overlay(
                Circle().strokeBorder(
                    fate == .added
                        ? Color.accentColor
                        : (inZone ? LevelColors.zoneStroke : LevelColors.stroke(style)),
                    style: StrokeStyle(
                        lineWidth: 2 * scale,
                        dash: (inZone || fate == .added) ? [4 * scale, 3 * scale] : []
                    )
                )
            )
            .overlay {
                if isSelected || isLinkTarget {
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2.5 * scale)
                        .padding(-5 * scale)
                        .shadow(color: Color.accentColor.opacity(0.45), radius: 6 * scale)
                }
            }
            .overlay {
                switch fate {
                case .removed:
                    // Фантом: перечёркнут — «эту работу механика убивает».
                    Path { path in
                        let inset = diameter * scale * 0.18
                        path.move(to: CGPoint(x: inset, y: inset))
                        path.addLine(to: CGPoint(
                            x: diameter * scale - inset, y: diameter * scale - inset
                        ))
                    }
                    .stroke(Color.secondary.opacity(0.8), lineWidth: 2 * scale)
                case .changed:
                    // Работа изменилась (переехала из области, слилась):
                    // мягкое кольцо-подсветка.
                    Circle()
                        .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 2 * scale)
                        .padding(-4 * scale)
                default:
                    EmptyView()
                }
            }
            .shadow(
                color: .black.opacity(isDragging ? 0.32 : 0.16),
                radius: (isDragging ? 9 : 3) * scale,
                y: (isDragging ? 4 : 1.5) * scale
            )
            .frame(width: diameter * scale, height: diameter * scale)
            .scaleEffect(1 / scale)
            .scaleEffect(isDragging ? 1.12 : (isHovered ? 1.06 : 1))
            .animation(.spring(duration: 0.25), value: isHovered)
            .animation(.spring(duration: 0.2), value: isDragging)
            // Фантом гаснет до 25% — как узлы вне подсветки поддерева.
            .opacity((isDimmed || fate == .removed) ? 0.25 : 1)
            .zIndex(isDragging ? 10 : 0)
            .overlay(alignment: .topTrailing) {
                if !nodeStickers.isEmpty {
                    // Бейдж механик-заметок: видно, что на работе висит
                    // гипотеза ценности; тултип называет какие.
                    Image(systemName: "note.text")
                        .font(.system(size: 8 * scale, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(3 * scale)
                        .background(Circle().fill(Color.orange.gradient))
                        .scaleEffect(1 / scale)
                        .offset(x: 4, y: -4)
                        .help(stickerHelp(nodeStickers))
                }
            }
            .position(position)
            .onTapGesture(count: 2) {
                guard armedMechanic == nil else { return }
                openDetails(job)
            }
            // ⌘ проверяется внутри обычного тапа: отдельный
            // TapGesture().modifiers(.command) блокирует ВСЕ клики узла.
            .onTapGesture {
                if armedMechanic != nil {
                    // Взведённая механика стреляет по кликнутой работе.
                    fireArmedMechanic(atNode: job.id)
                } else if NSEvent.modifierFlags.contains(.command) {
                    toggleEdgeWithSelection(job.id)
                } else {
                    select(job.id)
                }
            }
            .contextMenu {
                Button("Редактировать") { beginEditing(job) }
                Button("Карточка работы (двойной клик)") { openDetails(job) }
                if !nodeStickers.isEmpty {
                    Divider()
                    ForEach(nodeStickers) { sticker in
                        Button("Убрать заметку «\(mechanicTitle(sticker.slug))»") {
                            document.removeMechanicSticker(sticker.id)
                        }
                    }
                }
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
                if !chain.isEmpty {
                    Button(isCollapsed
                           ? "Развернуть цепочку — \(chain.count) (⌥→)"
                           : "Свернуть цепочку — \(chain.count) (⌥←)") {
                        toggleChain(job)
                    }
                }
                zoneMenuItems(for: job, level: level)
                Divider()
                Button("Выделить работы ниже") {
                    highlightedJobs = document.graph.jobsBelow(job.id)
                }
                // Копируется подсветка, если работа в неё входит, иначе
                // сама работа с декомпозицией — то же правило, что у ⌘C.
                Button(copyMenuTitle(for: job)) { copyJobs(from: job) }
                if ExportImport.hasJobsInClipboard {
                    // Верх копии ложится на уровень этой работы: меню
                    // открыто, курсора на канвасе уже нет.
                    Button("Вставить (⌘V)") { pasteJobs(anchorLevel: level) }
                }
                if let highlighted = highlightedJobs, highlighted.contains(job.id) {
                    Button("Экспортировать PNG выделенных работ…") {
                        exportHighlightedPNG(highlighted)
                    }
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
            .gesture(nodeDragGesture(job))

        // Свёрнутая цепочка: вместо плюса справа — счётчик скрытых работ.
        // Плюс здесь спрятан намеренно: новая работа встала бы внутрь
        // свёрнутой цепочки и исчезла с глаз.
        if isCollapsed {
            collapsedChainChip(count: chain.count) { toggleChain(job) }
                .position(plusRight)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        }

        if showsPlus, !chain.isEmpty, !isCollapsed {
            // Свернуть цепочку — работы справа уходят под счётчик.
            chainControl(
                systemImage: "chevron.left.2",
                help: "Свернуть цепочку работ уровня (⌥←)"
            ) { toggleChain(job) }
                .position(collapseControl)
                .transition(.scale(scale: 0.5).combined(with: .opacity))
        }

        if showsPlus {
            if !isCollapsed {
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
            }

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
            // Двойной клик по подписи — правка текста работы
            // (по кругу — карточка).
            nodeLabel(job, style: style)
                .opacity((isDimmed || fate == .removed) ? 0.25 : 1)
                .position(x: position.x, y: position.y + diameter / 2 + 32)
                .onTapGesture(count: 2) { beginEditing(job) }
                .onTapGesture { select(job.id) }
                .help("Двойной клик — изменить текст работы")
        }
    }

    /// Пункты меню про области уровня: перенести работу в область
    /// (уровень тот же, продукт её не выполняет) или вернуть в основную.
    @ViewBuilder
    private func zoneMenuItems(for job: JobNode, level: Int) -> some View {
        let zones = document.graph.levels[level].zones
        if !zones.isEmpty || job.zoneID != nil {
            Divider()
            ForEach(zones) { zone in
                if zone.id != job.zoneID {
                    Button("Перенести в область «\(zone.resolvedName)»") {
                        commitEditingIfNeeded()
                        document.perform(.setJobZone(job.id, zone: zone.id))
                    }
                }
            }
            if job.zoneID != nil {
                Button("Вернуть в основную область уровня") {
                    commitEditingIfNeeded()
                    document.perform(.setJobZone(job.id, zone: nil))
                }
            }
        }
    }

    /// Счётчик свёрнутой цепочки: сколько работ уровня скрыто справа.
    /// Виден всегда (а не по ховеру) — иначе цепочка выглядела бы
    /// оборванной, и потерянные работы было бы нечем вернуть.
    private func collapsedChainChip(count: Int, action: @escaping () -> Void) -> some View {
        HStack(spacing: 2) {
            Text("\(count)")
                .font(.system(size: 10 * scale, weight: .semibold))
            Image(systemName: "chevron.right.2")
                .font(.system(size: 8 * scale, weight: .bold))
        }
        .foregroundStyle(Color.accentColor)
        .padding(.horizontal, 7 * scale)
        .padding(.vertical, 4 * scale)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1 * scale))
        .scaleEffect(1 / scale)
        .contentShape(Capsule())
        .modifier(HoverPulse(idleOpacity: 0.95))
        .help("Развернуть цепочку: \(count) скрытых работ уровня (⌥→)")
        .onTapGesture(perform: action)
    }

    /// Кнопка сворачивания цепочки — того же размера и веса, что плюсы узла.
    private func chainControl(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 22, height: 22)
            .background(Circle().fill(.ultraThinMaterial))
            .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
            .contentShape(Circle())
            .modifier(HoverPulse(idleOpacity: 0.85))
            .help(help)
            .onTapGesture(perform: action)
    }

    /// Свернуть/развернуть цепочку работы. Выделение и открытая карточка,
    /// оказавшиеся внутри свёрнутой цепочки, переезжают на её голову —
    /// иначе они остались бы на невидимом узле.
    private func toggleChain(_ job: JobNode) {
        commitEditingIfNeeded()
        guard document.perform(.setCollapsed(job.id, !job.isCollapsed)) != nil else { return }
        let hidden = document.graph.hiddenJobs()
        if let current = detailsId, hidden.contains(current) { closeDetails() }
        if let current = selection, hidden.contains(current) { selection = job.id }
        focusBridge.focusCanvas()
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

    /// Перенос работы: нажал левой кнопкой на узел и повёл — работа
    /// «поднимается» и следует за курсором без паузы; отпускание —
    /// перенос на уровень, в область и на позицию под курсором.
    /// Тот же уровень — смена порядка внутри полосы (управление
    /// пространством). Порог 6pt отделяет перенос от клика и двойного
    /// клика по узлу — порог считается в экранных точках, поэтому
    /// одинаков при любом масштабе.
    private func nodeDragGesture(_ job: JobNode) -> some Gesture {
        DragGesture(minimumDistance: 6 / max(scale, 0.01), coordinateSpace: .named(Self.contentSpace))
            .onChanged { value in
                if dragNode?.id != job.id {
                    // Первое движение: работа поднята.
                    commitEditingIfNeeded()
                    selection = job.id
                    selectedEdge = nil
                }
                dragNode = NodeDrag(id: job.id, current: value.location)
            }
            .onEnded { value in
                defer { dragNode = nil }
                let geometry = GraphLayout.geometry(document.graph)
                if let target = dropTarget(for: value.location, excluding: job.id, geometry: geometry) {
                    document.perform(.move(
                        job.id,
                        toLevel: target.levelIndex,
                        zone: target.zoneID,
                        at: target.index
                    ))
                }
                focusBridge.focusCanvas()
            }
    }

    /// Целевая позиция точки канваса — уровень, область и место в ней.
    /// Геометрия в GraphCore (та же семантика у интентов move и addJob);
    /// вью только переводит координаты контента в координаты раскладки.
    /// `excluding` = nil — точка под новую работу (двойной клик).
    private func dropTarget(
        for location: CGPoint,
        excluding dragged: UUID?,
        geometry: GraphLayout.Geometry
    ) -> GraphLayout.DropTarget? {
        GraphLayout.dropTarget(
            graph: document.graph,
            geometry: geometry,
            at: CGPoint(x: location.x - contentPadding, y: location.y - contentPadding),
            bandOffset: nodeOffsetInBand,
            excluding: dragged
        )
    }

    /// Узел, чей круг (с небольшим допуском) накрывает точку контента.
    private func nodeID(at pointInContent: CGPoint) -> UUID? {
        let positions = GraphLayout.layout(document.graph)
        for (levelIndex, level) in document.graph.levels.enumerated() {
            let radius = document.graph.style(atLevel: levelIndex).diameter / 2 + 12
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
    private func nodeLabel(_ job: JobNode, style: LevelStyle) -> some View {
        // Шрифты и ширина умножены на zoom + обратный scaleEffect: текст
        // растрируется в натуральном размере и остаётся резким при любом
        // приближении (иначе внешний scaleEffect канваса растит растр 1x).
        VStack(spacing: 0) {
            if let role = job.role {
                Text("\(role):")
                    .font(.system(size: 10.5 * scale, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(job.verb)
                // Подпись следует за размером кружка, а не за номером
                // полосы: кóровая работа на любом месте графа подписана
                // одинаково.
                .font(.system(
                    size: (style.isTopScale ? 12 : 11) * scale,
                    weight: style.isTopScale ? .semibold : .regular
                ))
                // Резерв 3 строки — совпадает с labelReserve раскладки;
                // длиннее — truncation, полный текст в редакторе.
                .lineLimit(job.role == nil ? 3 : 2)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
        }
        .frame(width: (LayoutMetrics.columnWidth - 6) * scale)
        .scaleEffect(1 / scale)
    }

    private func point(_ position: CGPoint?) -> CGPoint {
        guard let position else { return .zero }
        return CGPoint(x: position.x + contentPadding, y: position.y + contentPadding)
    }

    /// Ширину задаёт самое правое содержимое: работа или рамка области.
    private func contentSize(_ geometry: GraphLayout.Geometry) -> CGSize {
        let rightEdge = max(
            geometry.positions.values.map(\.x).max() ?? 0,
            geometry.zones.values.map(\.maxX).max() ?? 0
        )
        let maxX = rightEdge + contentPadding * 2 + 220
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
        if highlightedJobs != nil {
            return "⌘C — копировать выделенные · ⌘V — вставить · правый клик — экспорт PNG · Esc — снять выделение"
        }
        if dragNode != nil {
            return "Отпустите работу: другой уровень — перенос, та же полоса — новое место, рамка области — в область"
        }
        if detailsId != nil {
            return "Карточка работы: Esc или ✕ — закрыть и сохранить"
        }
        if let selection, !document.graph.chain(after: selection).isEmpty {
            return document.graph.job(selection)?.isCollapsed == true
                ? "⌥→ — развернуть цепочку · Tab — декомпозиция · Delete — удалить"
                : "⌥← — свернуть цепочку · Tab — декомпозиция · Delete — удалить"
        }
        if selection != nil {
            return "Двойной клик — карточка · по подписи — текст · тянуть — перенос · Tab — декомпозиция · Delete — удалить"
        }
        return "Двойной клик — новая работа (внутри рамки — в её области) · тянуть работу — перенос · драг по пустому — панорама"
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
        let content = contentSize(GraphLayout.geometry(document.graph))
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

    /// Двойной клик по пустому месту — работа там, куда кликнули
    /// (конвенция Freeform/MindNode: пустое место + двойной клик = узел).
    /// Точка задаёт всё: уровень по y, область по рамке под курсором
    /// (клик внутри рамки создаёт работу в этой области), позицию
    /// внутри области — по x.
    private func createJobAtEmptyPoint(_ location: CGPoint) {
        commitEditingIfNeeded()
        let content = CGPoint(
            x: (location.x - offset.width) / scale,
            y: (location.y - offset.height) / scale
        )
        let geometry = GraphLayout.geometry(document.graph)
        guard let target = dropTarget(for: content, excluding: nil, geometry: geometry) else { return }
        if let newId = document.perform(.addJob(
            level: document.graph.levels[target.levelIndex].id,
            zone: target.zoneID,
            at: target.index
        )) {
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
        case .cmdCopy:
            guard copyableJobs != nil else { return false }
            copySelectedJobs()
            return true
        case .cmdPaste:
            guard ExportImport.hasJobsInClipboard else { return false }
            pasteJobs()
            return true
        case .escape:
            if armedMechanic != nil {
                // Отбой взведённой механики — раньше всего остального.
                disarmMechanic()
                return true
            }
            if detailsId != nil {
                closeDetails()
                return true
            }
            if highlightedJobs != nil {
                highlightedJobs = nil
                return true
            }
            selection = nil
            selectedEdge = nil
            return true
        case .optionLeft, .optionRight:
            guard let selection else { return false }
            commitEditingIfNeeded()
            document.perform(.setCollapsed(selection, key == .optionLeft))
            // Голова цепочки видна всегда — выделение никуда не уезжает,
            // но карточка работы, ушедшей под счётчик, закрывается.
            if let current = detailsId, document.graph.hiddenJobs().contains(current) {
                closeDetails()
            }
            return true
        case .left, .right:
            return moveSelectionInLevel(key == .right ? 1 : -1)
        case .up:
            return moveSelectionAcrossLevels(-1)
        case .down:
            return moveSelectionAcrossLevels(1)
        }
    }

    /// Состояние цепочки выделенной работы — для пунктов меню «Граф».
    private var chainState: (hasChain: Bool, isCollapsed: Bool) {
        guard let selection, let job = document.graph.job(selection) else { return (false, false) }
        return (!document.graph.chain(after: selection).isEmpty, job.isCollapsed)
    }

    /// Работы уровня, которые видно на канвасе: работы свёрнутых цепочек
    /// стрелками не выбираются — их на экране нет.
    private func visibleJobs(level: Int, hidden: Set<UUID>) -> [JobNode] {
        document.graph.levels[level].jobs.filter { !hidden.contains($0.id) }
    }

    private func moveSelectionInLevel(_ delta: Int) -> Bool {
        guard let selection,
              let levelIndex = document.graph.levelIndex(of: selection)
        else { return false }
        let jobs = visibleJobs(level: levelIndex, hidden: document.graph.hiddenJobs())
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
        let hidden = document.graph.hiddenJobs()
        let jobs = visibleJobs(level: levelIndex, hidden: hidden)
        let index = jobs.firstIndex(where: { $0.id == selection }) ?? 0
        var target = levelIndex + delta
        while target >= 0, target < document.graph.levels.count {
            let targetJobs = visibleJobs(level: target, hidden: hidden)
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
        // Клик по другой работе — тоже клик мимо карточки: она закрывается.
        // Карточка самой выбранной работы остаётся (её открыл двойной клик,
        // а он приходит вместе с одиночным).
        if let detailsId, detailsId != id { closeDetails() }
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

    // MARK: - Копирование и вставка работ

    /// Что уедет в буфер по ⌘C: подсвеченное поддерево («Выделить работы
    /// ниже»), а без подсветки — выделенная работа со своей декомпозицией.
    /// Копируется всегда цепочка целиком: одинокий узел без связей
    /// пользы почти не несёт, а поддерево — готовый кусок графа.
    /// nil — копировать нечего.
    private var copyableJobs: Set<UUID>? {
        if let highlightedJobs, !highlightedJobs.isEmpty { return highlightedJobs }
        guard let selection, document.graph.job(selection) != nil else { return nil }
        return document.graph.jobsBelow(selection)
    }

    private func copySelectedJobs() {
        guard let ids = copyableJobs else { return }
        copyJobs(ids)
    }

    /// Правый клик по узлу выделение не меняет, поэтому меню узла
    /// копирует от себя: подсветку, если работа в неё входит, иначе
    /// работу с её декомпозицией.
    private func jobsToCopy(from job: JobNode) -> Set<UUID> {
        if let highlightedJobs, highlightedJobs.contains(job.id) { return highlightedJobs }
        return document.graph.jobsBelow(job.id)
    }

    private func copyMenuTitle(for job: JobNode) -> String {
        let ids = jobsToCopy(from: job)
        if let highlightedJobs, highlightedJobs.contains(job.id) {
            return "Копировать выделенные работы — \(highlightedJobs.count) (⌘C)"
        }
        return ids.count > 1
            ? "Копировать работу с декомпозицией — \(ids.count) (⌘C)"
            : "Копировать работу (⌘C)"
    }

    private func copyJobs(from job: JobNode) {
        copyJobs(jobsToCopy(from: job))
    }

    private func copyJobs(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        commitEditingIfNeeded()
        ExportImport.copyJobs(document.graph.clipboard(keeping: ids))
    }

    /// Куда ложится верхняя работа копии: уровень под курсором. Курсор
    /// ушёл с канваса (вставка из строки меню) — уровень выделенной
    /// работы; нет и её — уровни копии остаются исходными.
    private var pasteAnchorLevel: Int? {
        if let cursorPosition, let level = levelIndex(atContentPoint: cursorPosition) {
            return level
        }
        if let selection { return document.graph.levelIndex(of: selection) }
        return nil
    }

    /// Уровень под точкой в координатах вью (клик мышью).
    private func levelIndex(atViewPoint location: CGPoint) -> Int? {
        levelIndex(atContentPoint: CGPoint(
            x: (location.x - offset.width) / scale,
            y: (location.y - offset.height) / scale
        ))
    }

    private func levelIndex(atContentPoint location: CGPoint) -> Int? {
        dropTarget(
            for: location,
            excluding: nil,
            geometry: GraphLayout.geometry(document.graph)
        )?.levelIndex
    }

    /// Вставка копии: верхняя работа ложится на уровень под курсором,
    /// её декомпозиция — на уровни ниже (недостающие создаются).
    /// Выделение и подсветка переезжают на вставленное — видно, что именно
    /// появилось, и следующий ⌘C копирует уже копию.
    private func pasteJobs() {
        pasteJobs(anchorLevel: pasteAnchorLevel)
    }

    private func pasteJobs(anchorLevel: Int?) {
        guard let clipboard = ExportImport.readJobs(), !clipboard.isEmpty else { return }
        commitEditingIfNeeded()
        let before = Set(document.graph.allJobs.map(\.id))
        guard let focus = document.perform(.paste(clipboard, atLevel: anchorLevel)) else { return }
        let pasted = Set(document.graph.allJobs.map(\.id)).subtracting(before)
        selection = focus
        selectedEdge = nil
        highlightedJobs = pasted.isEmpty ? nil : pasted
        focusBridge.focusCanvas()
    }

    /// PNG только из подсвеченных работ: подграф рендерится тем же
    /// снапшотом, что и полный экспорт.
    private func exportHighlightedPNG(_ ids: Set<UUID>) {
        let stageName = document.graphStages
            .first { $0.id == document.selectedGraphID }?.name ?? "Граф"
        ExportImport.exportGraphPNG(
            name: "\(stageName) — выделенные работы",
            graph: document.graph.subgraph(keeping: ids)
        )
    }

    private func edgeExists(_ a: UUID, _ b: UUID) -> Bool {
        document.graph.edges.contains {
            ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a)
        }
    }

    // MARK: - Карточка работы

    private var detailsCardSize: CGSize { CGSize(width: 340, height: 480) }

    /// Карточка описания работы по AJTBD: «когда / хочу / чтобы» + частота.
    /// Открывается справа от узла в режиме просмотра (отформатированный
    /// текст с буллетами); карандаш в шапке переключает в редактор.
    /// Закрытие (✕, Esc, двойной клик по другому узлу) и выход из
    /// редактора коммитят черновик одним интентом.
    @ViewBuilder
    private func detailsCard(_ job: JobNode, level: Int, at position: CGPoint) -> some View {
        let diameter = document.graph.style(atLevel: level).diameter
        let x = position.x + diameter / 2 + detailsCardSize.width / 2 + 26
        // Верх карточки — у верха узла; у верхней кромки контента прижимается.
        let y = max(
            position.y - diameter / 2 - 10 + detailsCardSize.height / 2,
            detailsCardSize.height / 2 + 12
        )

        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(job.displayText.isEmpty ? "Карточка работы" : job.displayText)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                detailsHeaderButton(
                    icon: detailsEditing ? "checkmark" : "pencil",
                    help: detailsEditing ? "Готово — сохранить и вернуться к просмотру" : "Редактировать карточку"
                ) {
                    toggleDetailsEditing()
                }
                detailsHeaderButton(icon: "xmark", help: "Закрыть карточку (Esc)") {
                    closeDetails()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                if detailsEditing {
                    detailsEditForm
                } else {
                    detailsReadView(for: job)
                }
            }
        }
        .frame(width: detailsCardSize.width, height: detailsCardSize.height)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        // Esc закрывает карточку из любого места: onExitCommand ловит его,
        // пока фокус в полях редактора, onKeyPress — когда фокус на самой
        // карточке (кнопки шапки, скролл просмотра). Фокус на канвасе
        // закрывает карточку через handleKey.
        .onExitCommand { closeDetails() }
        .onKeyPress(.escape) {
            closeDetails()
            return .handled
        }
        .position(x: x, y: y)
        .transition(.scale(scale: 0.95, anchor: .leading).combined(with: .opacity))
    }

    private func detailsHeaderButton(
        icon: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(0.08)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Карточка — просмотр

    /// Отформатированный вид карточки: жирные «когда/хочу/чтобы»,
    /// подписи полей, элементы — буллеты. Все секции видны всегда;
    /// пустые поля показываются с плейсхолдером «—». Заголовок «хочу»
    /// включает название работы без её собственного префикса «хочу».
    @ViewBuilder
    private func detailsReadView(for job: JobNode) -> some View {
        let details = detailsDraft

        VStack(alignment: .leading, spacing: 14) {
            detailsReadSection("когда") {
                detailsReadField("я в контексте:", items: details.context)
                detailsReadField("испытываю негативные эмоции:", items: details.negativeEmotions)
                detailsReadField("случился триггер:", items: details.trigger)
            }
            detailsReadSection(wantsSectionTitle(for: job)) {
                detailsReadField("с такими критериями успеха:", items: details.successCriteria)
            }
            detailsReadSection("чтобы") {
                detailsReadField(nil, items: details.inOrderTo)
                detailsReadField("и чувствовать себя:", items: details.positiveEmotions)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Частота выполнения работы: ").bold()
                    .font(.system(size: 11.5))
                if details.frequency.isEmpty {
                    Text("—")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(details.frequency)
                        .font(.system(size: 11.5))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    /// Заголовок секции «хочу»: «хочу {название работы без ведущего „хочу"}».
    /// Если после отрезания префикса ничего не осталось — просто «хочу».
    private func wantsSectionTitle(for job: JobNode) -> String {
        var name = job.verb.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = name.range(of: "хочу", options: [.caseInsensitive, .anchored]) {
            name = String(name[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return name.isEmpty ? "хочу" : "хочу \(name)"
    }

    @ViewBuilder
    private func detailsReadSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5, weight: .bold))
            content()
        }
    }

    /// Подпись поля + элементы-буллеты. Пустой список — плейсхолдер «—».
    @ViewBuilder
    private func detailsReadField(_ label: String?, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let label {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Text("—")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 10)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(item)
                            .font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, 10)
                }
            }
        }
    }

    // MARK: Карточка — редактор

    private var detailsEditForm: some View {
        VStack(alignment: .leading, spacing: 16) {
            detailsEditSection("Когда") {
                detailsListEditor("я в контексте", items: $detailsDraft.context)
                detailsListEditor("испытываю негативные эмоции", items: $detailsDraft.negativeEmotions)
                detailsListEditor("случился триггер", items: $detailsDraft.trigger)
            }
            detailsEditSection("Хочу") {
                detailsListEditor("с такими критериями успеха", items: $detailsDraft.successCriteria)
            }
            detailsEditSection("Чтобы") {
                detailsListEditor("ради чего выполняется работа", items: $detailsDraft.inOrderTo)
                detailsListEditor("и чувствовать себя", items: $detailsDraft.positiveEmotions)
            }
            detailsEditSection("Частота выполнения работы") {
                TextField("5 раз/год", text: $detailsDraft.frequency)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func detailsEditSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// Редактор поля-списка: каждый элемент — строка с буллетом,
    /// ✕ удаляет элемент, «+ элемент» добавляет пустой в конец,
    /// Return в строке — тоже добавляет следующий элемент.
    private func detailsListEditor(_ label: String, items: Binding<[String]>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            ForEach(items.wrappedValue.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("элемент", text: itemBinding(items, index), axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .lineLimit(1...6)
                        .onSubmit { items.wrappedValue.append("") }
                    Button {
                        guard index < items.wrappedValue.count else { return }
                        items.wrappedValue.remove(at: index)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 14, height: 14)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Удалить элемент")
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
            }
            Button {
                items.wrappedValue.append("")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .bold))
                    Text("элемент")
                        .font(.system(size: 10.5))
                }
                .foregroundStyle(Color.accentColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Биндинг элемента списка с защитой от гонки индексов: ForEach
    /// может дёрнуть строку в момент удаления элемента.
    private func itemBinding(_ items: Binding<[String]>, _ index: Int) -> Binding<String> {
        Binding(
            get: { index < items.wrappedValue.count ? items.wrappedValue[index] : "" },
            set: { if index < items.wrappedValue.count { items.wrappedValue[index] = $0 } }
        )
    }

    // MARK: Карточка — открытие/коммит

    private func openDetails(_ job: JobNode) {
        commitEditingIfNeeded()
        guard detailsId != job.id else { return }
        commitDetailsIfNeeded()
        selection = job.id
        detailsDraft = job.details
        // Пустую карточку форматировать нечего — сразу редактор.
        detailsEditing = job.details.isEmpty
        detailsId = job.id
        // Просмотр не требует ввода — фокус остаётся на канвасе, чтобы
        // Esc и стрелки работали сразу после открытия карточки.
        if !detailsEditing { focusBridge.focusCanvas() }
    }

    /// Карандаш/галочка в шапке: выход из редактора коммитит черновик
    /// (карточка остаётся открытой в режиме просмотра).
    private func toggleDetailsEditing() {
        if detailsEditing {
            detailsDraft = detailsDraft.normalized()
            if let id = detailsId {
                document.perform(.setDetails(id, details: detailsDraft))
            }
        }
        detailsEditing.toggle()
    }

    private func closeDetails() {
        commitDetailsIfNeeded()
        focusBridge.focusCanvas()
    }

    /// Коммит черновика карточки: одна запись в undo-стеке на карточку;
    /// без изменений (или работа удалена) — движок вернёт no-op.
    private func commitDetailsIfNeeded() {
        guard let id = detailsId else { return }
        detailsId = nil
        detailsEditing = false
        document.perform(.setDetails(id, details: detailsDraft))
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

    // MARK: - Переименование области уровня

    private func beginZoneEditing(_ zone: LevelZone) {
        commitEditingIfNeeded()
        zoneDraft = zone.name ?? ""
        editingZoneId = zone.id
        zoneEditorFocused = true
    }

    private func commitZoneEditing() {
        guard let id = editingZoneId else { return }
        editingZoneId = nil
        // Движок сам решает: пустое имя → сброс к «SMALL JOBS», без изменений → no-op.
        document.perform(.renameZone(id, name: zoneDraft))
        focusBridge.focusCanvas()
    }

    private func commitZoneEditingIfNeeded() {
        if editingZoneId != nil { commitZoneEditing() }
    }

    private func cancelZoneEditing() {
        editingZoneId = nil
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
    /// У выделенной работы есть развёрнутая цепочка справа.
    let canCollapse: Bool
    /// Выделенная работа — голова свёрнутой цепочки.
    let canExpand: Bool
    let collapseChain: () -> Void
    let expandChain: () -> Void
    /// Есть что копировать: подсветка «работы ниже» или выделенная работа.
    let canCopy: Bool
    let copyJobs: () -> Void
    let pasteJobs: () -> Void
    /// Палитра механик ценности (⌘K).
    let showMechanics: () -> Void
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
