import SwiftUI
import GraphCore

@main
struct PetableApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // Первая сцена — то, что открывается при запуске: хаб проектов,
        // а не системный диалог открытия файла от DocumentGroup.
        Window("Проекты", id: ProjectsView.windowID) {
            ProjectsView()
        }
        .defaultSize(width: 520, height: 420)

        DocumentGroup(newDocument: { PetableDocument() }) { configuration in
            AppShellView(document: configuration.document)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Проекты…") {
                    openWindow(id: ProjectsView.windowID)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CanvasZoomMenuCommands()
            CanvasGraphMenuCommands()
        }

        // Настройки (⌘,): токены и конфигурация ИИ-агента.
        Settings {
            AgentSettingsView()
        }
    }
}

/// Меню «Вид»: стандартные zoom-команды macOS (⌘+/⌘−/⌘0/⇧⌘0),
/// работают в окне с канвасом через focusedSceneValue.
struct CanvasZoomMenuCommands: Commands {
    @FocusedValue(\.canvasZoom) private var canvasZoom

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Увеличить") { canvasZoom?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(canvasZoom == nil)
            Button("Уменьшить") { canvasZoom?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(canvasZoom == nil)
            Button("Реальный размер") { canvasZoom?.actualSize() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(canvasZoom == nil)
            Button("Вписать граф в окно") { canvasZoom?.zoomToFit() }
                .keyboardShortcut("0", modifiers: [.command, .shift])
                .disabled(canvasZoom == nil)
            Divider()
        }
    }
}

/// Меню «Граф»: все действия канваса в строке меню — HIG называет её
/// главным местом обнаружения команд. Клавиши (Tab, Return, ⌘←…)
/// перехватывает сам канвас, поэтому в пунктах они показаны текстом,
/// а не key equivalents — иначе меню отняло бы Tab у текстовых полей.
struct CanvasGraphMenuCommands: Commands {
    @FocusedValue(\.canvasGraph) private var graph

    var body: some Commands {
        CommandMenu("Граф") {
            Button("Новая работа на верхнем уровне") { graph?.addJobTop() }
                .disabled(graph == nil)
            Button("Декомпозиция ниже (Tab)") { graph?.addBelow() }
                .disabled(graph?.hasSelection != true)
            Button("Работа справа (⌘Return)") { graph?.addRight() }
                .disabled(graph?.hasSelection != true)
            Divider()
            Button("Редактировать текст (Return)") { graph?.editText() }
                .disabled(graph?.hasSelection != true)
            Button("Сдвинуть влево (⌘←)") { graph?.moveLeft() }
                .disabled(graph?.hasSelection != true)
            Button("Сдвинуть вправо (⌘→)") { graph?.moveRight() }
                .disabled(graph?.hasSelection != true)
            Divider()
            // Без выделения ⌘C копирует граф целиком, поэтому подпись
            // без слова «работы»: пункт про то и другое.
            Button("Копировать (⌘C)") { graph?.copyJobs() }
                .disabled(graph?.canCopy != true)
            Button("Вставить (⌘V)") { graph?.pasteJobs() }
                .disabled(graph?.canPaste != true)
            Divider()
            Button("Свернуть цепочку (⌥←)") { graph?.collapseChain() }
                .disabled(graph?.canCollapse != true)
            Button("Развернуть цепочку (⌥→)") { graph?.expandChain() }
                .disabled(graph?.canExpand != true)
            Divider()
            Button("Механики ценности…") { graph?.showMechanics() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(graph == nil)
            Divider()
            Button("Удалить работу (Delete)") { graph?.deleteSelection() }
                .disabled(graph?.hasSelection != true)
        }
    }
}

/// Без делегата NSDocumentController при запуске/реактивации требует
/// untitled-документ — SwiftUI отвечает на это диалогом открытия файла.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }
}

/// Оболочка окна проекта: сайдбар с разделами слева + detail справа.
/// Разделы: «Граф работ» (канвас) и «Интервью» (исследования AJTBD —
/// список интервью, шаблоны, форма интервью).
struct AppShellView: View {
    @ObservedObject var document: PetableDocument

    /// Единый тип выбора в сайдбаре: граф, интервью, шаблон,
    /// сегмент или Карта сегментов.
    enum SidebarItem: Hashable {
        case graph(UUID)
        case interview(UUID)
        case template(UUID)
        case segment(UUID)
        case segmentMap
    }

    /// Фильтр артефактов по происхождению: все / человек / агент.
    enum OriginFilter: String, CaseIterable {
        case all = "Все"
        case human = "Человек"
        case agent = "Агент"

        func matches(_ origin: ArtifactOrigin) -> Bool {
            switch self {
            case .all: return true
            case .human: return origin == .human
            case .agent: return origin == .agent
            }
        }
    }

    @State private var graphsExpanded = true
    @State private var interviewsExpanded = true
    @State private var templatesExpanded = false
    @State private var segmentsExpanded = true
    @State private var hoveredRow: UUID?
    @State private var renamingID: UUID?
    @State private var renameDraft = ""
    @State private var templatePickerShown = false
    @State private var agentSheetShown = false
    @State private var chatShown = false
    /// Ширина панели агента; тянется за сплиттер, запоминается между запусками.
    @AppStorage("agent.chatWidth") private var chatWidth = 340.0
    @StateObject private var chatController = AgentChatController()
    @State private var graphFilter: OriginFilter = .all
    @State private var interviewFilter: OriginFilter = .all
    /// Свёрнутые группы графов; пустое множество = все раскрыты
    /// (группу создают, чтобы её видеть).
    @State private var collapsedGraphs: Set<UUID> = []
    /// Граф, над которым сейчас висит перетаскиваемый — подсветка цели.
    @State private var graphDropTarget: UUID?
    @FocusState private var renameFocused: Bool

    var body: some View {
        NavigationSplitView {
            List(selection: selectionBinding) {
                DisclosureGroup(isExpanded: $graphsExpanded) {
                    ForEach(graphOutlineRows) { row in
                        graphRow(row)
                            .tag(SidebarItem.graph(row.stage.id))
                    }
                    newItemRow("Создать новый", help: "Добавить граф работ в проект") {
                        document.addGraph()
                    }
                    Menu {
                        Button("Из файла…") {
                            ExportImport.importGraph(into: document)
                        }
                        Button("Вставить из буфера") {
                            ExportImport.importGraphFromClipboard(into: document)
                        }
                    } label: {
                        Label("Импортировать…", systemImage: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .help("Импортировать граф работ из JSON: файл или буфер обмена")
                } label: {
                    sectionLabel(
                        "Граф работ",
                        systemImage: "point.3.connected.trianglepath.dotted",
                        filter: $graphFilter
                    )
                }

                DisclosureGroup(isExpanded: $interviewsExpanded) {
                    ForEach(document.research.interviews.filter { interviewFilter.matches($0.resolvedOrigin) }) { interview in
                        interviewRow(interview)
                            .tag(SidebarItem.interview(interview.id))
                    }
                    newItemRow("Создать интервью", help: "Новое интервью по шаблону AJTBD") {
                        templatePickerShown = true
                    }
                    newItemRow(
                        "Исследовать агентом…",
                        systemImage: "sparkles",
                        help: "ИИ-агент раскопает работы по решению и построит интервью + граф работ"
                    ) {
                        agentSheetShown = true
                    }
                    DisclosureGroup(isExpanded: $templatesExpanded) {
                        ForEach(document.research.templates) { template in
                            templateRow(template)
                                .tag(SidebarItem.template(template.id))
                        }
                        newItemRow("Создать шаблон", help: "Новый шаблон интервью") {
                            document.addTemplate()
                        }
                        Menu {
                            Button("Из файла…") {
                                ExportImport.importTemplate(into: document)
                            }
                            Button("Вставить из буфера") {
                                ExportImport.importTemplateFromClipboard(into: document)
                            }
                        } label: {
                            Label("Импортировать…", systemImage: "square.and.arrow.down")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .help("Импортировать шаблон интервью из JSON: файл или буфер обмена")
                    } label: {
                        Label("Шаблоны", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                    }
                } label: {
                    sectionLabel(
                        "Интервью",
                        systemImage: "person.wave.2",
                        filter: $interviewFilter
                    )
                }

                DisclosureGroup(isExpanded: $segmentsExpanded) {
                    if !document.segmentation.segments.isEmpty {
                        HStack {
                            Label("Карта сегментов", systemImage: "tablecells")
                            Spacer()
                        }
                        .tag(SidebarItem.segmentMap)
                        .help("Сравнительная таблица сегментов: экономика, блокеры, вердикты")
                    }
                    ForEach(document.segmentation.segments) { segment in
                        segmentRow(segment)
                            .tag(SidebarItem.segment(segment.id))
                    }
                    newItemRow("Создать сегмент", help: "Новый сегмент: кóровые работы + критерии + экономика") {
                        document.addSegment()
                    }
                } label: {
                    Label("Сегменты", systemImage: "person.3")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
            // ⌘C/⌘V по выбранному графу. Пункты меню «Правка» здесь
            // выключены (сайдбар копирование не реализует), поэтому
            // клавиши доходят сюда сами — перехватывать меню не нужно.
            .onKeyPress(phases: .down) { press in handleSidebarKey(press) }
        } detail: {
            // Панель агента живёт внутри detail-колонки (как AI-панель
            // в Cursor): контент ужимается, окно размер не меняет.
            // GeometryReader не запрашивает размер у окна — панель капится
            // долей доступной ширины, окну расти не из-за чего.
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    detailContent
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if chatShown {
                        ChatPanelSplitter(
                            width: $chatWidth,
                            maxWidth: geometry.size.width / 2,
                            onCollapse: { chatShown = false }
                        )
                        AgentChatPanel(
                            document: document,
                            controller: chatController,
                            onClose: { chatShown = false }
                        )
                        .frame(width: panelWidth(available: geometry.size.width))
                        .frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    withAnimation(.spring(duration: 0.25)) { chatShown.toggle() }
                } label: {
                    Label("Агент", systemImage: chatShown ? "sparkles.rectangle.stack.fill" : "sparkles.rectangle.stack")
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .help("Чат с агентом: вопросы по AJTBD, создание и правка артефактов (⇧⌘A)")
            }
            ToolbarItem(placement: .primaryAction) {
                exportToolbarMenu
            }
        }
        .sheet(isPresented: $templatePickerShown) {
            TemplatePickerSheet(document: document)
        }
        .sheet(isPresented: $agentSheetShown) {
            AgentRunSheet(document: document)
        }
    }

    /// Фактическая ширина панели: пользовательская, но не шире половины
    /// доступного места — панель никогда не заставляет окно расти.
    private func panelWidth(available: CGFloat) -> CGFloat {
        let cap = max(ChatPanelSplitter.minWidth, available / 2)
        return min(max(ChatPanelSplitter.minWidth, chatWidth), cap)
    }

    /// Вертикальный сплиттер панели агента: тянется мышью, курсор ↔.
    /// Влево — до половины окна; вправо — до минимума, дальше панель
    /// сворачивается (как AI-панель в Cursor).
    private struct ChatPanelSplitter: View {
        @Binding var width: Double
        /// Предел расширения: половина текущей ширины detail-колонки.
        var maxWidth: Double
        /// Панель утянули почти в ноль — закрыть её.
        var onCollapse: () -> Void

        @State private var widthAtDragStart: Double?

        static let minWidth = 220.0
        /// Утащили заметно правее минимума — считаем жестом «свернуть».
        private static let collapseThreshold = 160.0
        /// Ширина при следующем открытии после сворачивания — удобная,
        /// а не минимальная.
        private static let reopenWidth = 300.0

        var body: some View {
            // Сплиттер — полноценный ребёнок HStack со своей 8-pt зоной
            // захвата: overlay поверх 1-px Divider перекрывался соседями
            // и не ловил мышь. Видимая линия — по центру зоны.
            ZStack {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(width: 1)
            }
            .frame(width: 8)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = widthAtDragStart ?? width
                        widthAtDragStart = start
                        // Панель справа: движение влево = шире.
                        let proposed = start - value.translation.width
                        if proposed < Self.collapseThreshold {
                            widthAtDragStart = nil
                            width = Self.reopenWidth
                            onCollapse()
                            return
                        }
                        width = min(
                            max(proposed, Self.minWidth),
                            max(maxWidth, Self.minWidth)
                        )
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
        }
    }

    /// Содержимое detail-колонки: канвас графа или открытый элемент
    /// исследований (вынесено из body ради панели чата рядом).
    @ViewBuilder
    private var detailContent: some View {
        switch document.selectedResearchItem {
        case .interview(let id):
            InterviewFormView(document: document, interviewID: id)
        case .template(let id):
            TemplateEditorView(document: document, templateID: id)
        case .segment(let id):
            SegmentEditorView(document: document, segmentID: id)
        case .segmentMap:
            SegmentMapView(document: document)
        case nil:
            CanvasRootView(document: document)
        }
    }

    /// Кнопка «Экспорт» в правом верхнем углу окна: меню под то, что
    /// открыто в detail — интервью (JSON/Markdown/PDF в файл, JSON/Markdown
    /// в буфер) или выбранный граф (JSON в файл / в буфер). Для редактора
    /// шаблона экспорта нет — кнопка скрывается.
    @ViewBuilder
    private var exportToolbarMenu: some View {
        switch document.selectedResearchItem {
        case .interview(let id):
            if let interview = document.research.interviews.first(where: { $0.id == id }) {
                Menu {
                    Button("Экспортировать в JSON…") { ExportImport.exportInterviewJSON(interview) }
                    Button("Экспортировать в Markdown…") { ExportImport.exportInterviewMarkdown(interview) }
                    Button("Экспортировать в PDF…") { ExportImport.exportInterviewPDF(interview) }
                    Divider()
                    Button("Скопировать JSON") { ExportImport.copyInterviewJSON(interview) }
                    Button("Скопировать Markdown") { ExportImport.copyInterviewMarkdown(interview) }
                } label: {
                    Label("Экспорт", systemImage: "square.and.arrow.up")
                }
                .help("Экспортировать интервью: в файл или в буфер обмена")
            }
        case .template(let id):
            if let template = document.research.templates.first(where: { $0.id == id }) {
                Menu {
                    templateShareLink(template)
                    Divider()
                    Button("Экспортировать в JSON…") { ExportImport.exportTemplateJSON(template) }
                    Button("Скопировать JSON") { ExportImport.copyTemplateJSON(template) }
                } label: {
                    Label("Экспорт", systemImage: "square.and.arrow.up")
                }
                .help("Поделиться шаблоном или экспортировать: файл, буфер обмена")
            }
        case .segment, .segmentMap:
            EmptyView()
        case nil:
            if let stage = document.graphStages.first(where: { $0.id == document.selectedGraphID }) {
                Menu {
                    Button("Экспортировать в JSON…") { ExportImport.exportGraphJSON(stage) }
                    Button("Экспортировать в PNG…") { ExportImport.exportGraphPNG(stage) }
                    Divider()
                    Button("Скопировать JSON") { ExportImport.copyGraphJSON(stage) }
                } label: {
                    Label("Экспорт", systemImage: "square.and.arrow.up")
                }
                .help("Экспортировать граф работ: в файл или в буфер обмена")
            }
        }
    }

    /// Заголовок раздела с меню фильтра по происхождению; активный
    /// фильтр подсвечивается залитой иконкой.
    private func sectionLabel(
        _ title: String,
        systemImage: String,
        filter: Binding<OriginFilter>
    ) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Menu {
                Picker("Показывать", selection: filter) {
                    ForEach(OriginFilter.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
            } label: {
                Image(systemName: filter.wrappedValue == .all
                    ? "line.3.horizontal.decrease.circle"
                    : "line.3.horizontal.decrease.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(filter.wrappedValue == .all ? Color.secondary : Color.accentColor)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Фильтр: созданы человеком или агентом")
        }
    }

    private func newItemRow(
        _ title: String,
        systemImage: String = "plus",
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// Выбор в списке ↔ состояние документа (граф или элемент исследований).
    private var selectionBinding: Binding<SidebarItem?> {
        Binding(
            get: {
                switch document.selectedResearchItem {
                case .interview(let id): return .interview(id)
                case .template(let id): return .template(id)
                case .segment(let id): return .segment(id)
                case .segmentMap: return .segmentMap
                case nil: return document.selectedGraphID.map(SidebarItem.graph)
                }
            },
            set: { item in
                switch item {
                case .graph(let id): document.selectGraph(id)
                case .interview(let id): document.selectResearch(.interview(id))
                case .template(let id): document.selectResearch(.template(id))
                case .segment(let id): document.selectResearch(.segment(id))
                case .segmentMap: document.selectResearch(.segmentMap)
                case nil: break
                }
            }
        )
    }

    /// Дерево графов проекта в плоском виде: свёрнутые группы скрыты,
    /// фильтр по происхождению не рвёт группу (родитель виден, если
    /// подходит кто-то в его поддереве).
    private var graphOutlineRows: [Envelope.GraphOutlineRow] {
        document.stages.graphOutline(collapsed: collapsedGraphs) { stage in
            graphFilter.matches(stage.resolvedOrigin)
        }
    }

    /// Русский заголовок механики по слагу; слаг как есть, если каталог
    /// не загрузился — бейдж всё равно осмысленный.
    private func mechanicTitle(_ slug: String) -> String {
        guard case let .success(catalog) = MechanicCatalogStore.result,
              let mechanic = catalog.mechanic(slug)
        else { return slug }
        return mechanic.title
    }

    @ViewBuilder
    private func graphRow(_ row: Envelope.GraphOutlineRow) -> some View {
        let stage = row.stage
        if renamingID == stage.id {
            renameField("Название графа") { document.renameGraph(stage.id, to: $0) }
                .padding(.leading, graphIndent(row))
        } else {
            sidebarRow(
                id: stage.id,
                name: stage.name,
                icon: "circle.hexagonpath",
                isAgent: stage.resolvedOrigin == .agent,
                deletable: document.canDeleteGraph(stage.id),
                deleteHelp: row.hasChildren
                    ? "Удалить граф вместе с вложенными"
                    : "Удалить граф",
                onSelect: { document.selectGraph(stage.id) },
                onDelete: { document.deleteGraph(stage.id) },
                onRename: { beginRename(id: stage.id, name: stage.name) },
                exportItems: [
                    ("Экспортировать в JSON…", { ExportImport.exportGraphJSON(stage) }),
                    ("Экспортировать в PNG…", { ExportImport.exportGraphPNG(stage) }),
                    ("Скопировать JSON", { ExportImport.copyGraphJSON(stage) }),
                ],
                leadingContextItems: AnyView(graphContextItems(stage)),
                indent: graphIndent(row),
                disclosure: row.hasChildren
                    ? RowDisclosure(
                        isExpanded: !collapsedGraphs.contains(stage.id),
                        toggle: { toggleGraphGroup(stage.id) }
                    )
                    : nil,
                mechanicBadge: stage.mechanicOrigin.map { origin in
                    let title = mechanicTitle(origin.slug)
                    return origin.anchorLabels.isEmpty
                        ? title
                        : "\(title) — \(origin.anchorLabels.joined(separator: ", "))"
                }
            )
            // Перетащить граф на граф — положить его в эту группу:
            // прямой жест группировки, меню «Переместить» дублирует
            // его для клавиатуры и длинных списков.
            .draggable(stage.id.uuidString) {
                Label(stage.name, systemImage: "circle.hexagonpath")
            }
            .dropDestination(for: String.self) { items, _ in
                dropGraph(items, onto: stage.id)
            } isTargeted: { targeted in
                graphDropTarget = targeted
                    ? stage.id
                    : (graphDropTarget == stage.id ? nil : graphDropTarget)
            }
            .listRowBackground(
                graphDropTarget == stage.id
                    ? Color.accentColor.opacity(0.18)
                    : nil
            )
            // Опора UI-тестов: строк графа в сайдбаре может быть много,
            // а имена совпадают с именем секции.
            .accessibilityIdentifier("graphRow")
        }
    }

    /// ⌘C — копия выбранного графа в буфер, ⌘V — вставка графа из буфера.
    /// Вставка всегда даёт граф верхнего уровня: копия не должна заезжать
    /// внутрь исходного (вложенность — отдельный жест, «Создать новый
    /// внутри» или перетаскивание).
    private func handleSidebarKey(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command), renamingID == nil else { return .ignored }
        switch press.characters.lowercased() {
        case "c":
            guard document.selectedResearchItem == nil,
                  let stage = document.graphStages.first(where: { $0.id == document.selectedGraphID })
            else { return .ignored }
            ExportImport.copyGraphJSON(stage)
            return .handled
        case "v":
            return ExportImport.pasteGraph(into: document) ? .handled : .ignored
        default:
            return .ignored
        }
    }

    /// Пункты меню графа: копирование и вставка целого графа, создание
    /// вложенного и перенос в другую группу.
    @ViewBuilder
    private func graphContextItems(_ stage: Envelope.Stage) -> some View {
        Button("Скопировать граф (⌘C)") { ExportImport.copyGraphJSON(stage) }
        if ExportImport.hasGraphInClipboard {
            Button("Вставить граф (⌘V)") { ExportImport.pasteGraph(into: document) }
        }
        Divider()
        Button("Создать новый внутри") {
            collapsedGraphs.remove(stage.id) // новый граф должен быть виден
            document.addGraph(parent: stage.id)
        }
        Menu("Переместить") {
            if stage.parentID != nil {
                Button("На верхний уровень") {
                    document.nestGraph(stage.id, under: nil)
                }
                Divider()
            }
            ForEach(nestTargets(for: stage), id: \.id) { target in
                Button(target.name) {
                    collapsedGraphs.remove(target.id)
                    document.nestGraph(stage.id, under: target.id)
                }
            }
        }
        .disabled(stage.parentID == nil && nestTargets(for: stage).isEmpty)
    }

    /// Куда можно вложить граф: любой другой граф, кроме текущего
    /// родителя и собственного поддерева (цикл спрятал бы группу).
    private func nestTargets(for stage: Envelope.Stage) -> [Envelope.Stage] {
        document.graphStages.filter { candidate in
            candidate.id != stage.parentID
                && document.stages.canNestGraph(stage.id, under: candidate.id)
        }
    }

    /// Отступ строки по глубине вложенности.
    private func graphIndent(_ row: Envelope.GraphOutlineRow) -> CGFloat {
        CGFloat(row.depth) * 14
    }

    private func toggleGraphGroup(_ id: UUID) {
        if collapsedGraphs.contains(id) {
            collapsedGraphs.remove(id)
        } else {
            collapsedGraphs.insert(id)
        }
    }

    /// Дроп графа в группу. Возвращает, принят ли он: чужие строки
    /// (интервью, текст) и циклы отбрасываются.
    private func dropGraph(_ items: [String], onto parent: UUID) -> Bool {
        graphDropTarget = nil
        guard let raw = items.first,
              let dragged = UUID(uuidString: raw),
              document.stages.canNestGraph(dragged, under: parent)
        else { return false }
        collapsedGraphs.remove(parent)
        document.nestGraph(dragged, under: parent)
        return true
    }

    @ViewBuilder
    private func interviewRow(_ interview: Interview) -> some View {
        if renamingID == interview.id {
            renameField("Название интервью") { document.renameInterview(interview.id, to: $0) }
        } else {
            sidebarRow(
                id: interview.id,
                name: interview.name,
                icon: "text.bubble",
                isAgent: interview.resolvedOrigin == .agent,
                deletable: true,
                deleteHelp: "Удалить интервью",
                onSelect: { document.selectResearch(.interview(interview.id)) },
                onDelete: { document.deleteInterview(interview.id) },
                onRename: { beginRename(id: interview.id, name: interview.name) },
                exportItems: [
                    ("Экспортировать в JSON…", { ExportImport.exportInterviewJSON(interview) }),
                    ("Экспортировать в Markdown…", { ExportImport.exportInterviewMarkdown(interview) }),
                    ("Экспортировать в PDF…", { ExportImport.exportInterviewPDF(interview) }),
                    ("Скопировать JSON", { ExportImport.copyInterviewJSON(interview) }),
                    ("Скопировать Markdown", { ExportImport.copyInterviewMarkdown(interview) }),
                ]
            )
        }
    }

    @ViewBuilder
    private func segmentRow(_ segment: Segment) -> some View {
        if renamingID == segment.id {
            renameField("Название сегмента") { document.renameSegment(segment.id, to: $0) }
        } else {
            HStack(spacing: 6) {
                sidebarRow(
                    id: segment.id,
                    name: segment.name,
                    icon: "person.3",
                    isAgent: segment.resolvedOrigin == .agent,
                    deletable: true,
                    deleteHelp: "Удалить сегмент",
                    onSelect: { document.selectResearch(.segment(segment.id)) },
                    onDelete: { document.deleteSegment(segment.id) },
                    onRename: { beginRename(id: segment.id, name: segment.name) }
                )
                if let verdict = segment.verdict {
                    Text(verdict.badge)
                        .font(.system(size: 9))
                        .help(verdict.title)
                }
            }
        }
    }

    @ViewBuilder
    private func templateRow(_ template: InterviewTemplate) -> some View {
        sidebarRow(
            id: template.id,
            name: template.name,
            icon: "doc.text",
            isAgent: false,
            deletable: true,
            deleteHelp: "Удалить шаблон",
            onSelect: { document.selectResearch(.template(template.id)) },
            onDelete: { document.deleteTemplate(template.id) },
            onRename: nil,
            exportItems: [
                ("Экспортировать в JSON…", { ExportImport.exportTemplateJSON(template) }),
                ("Скопировать JSON", { ExportImport.copyTemplateJSON(template) }),
            ],
            extraContextItems: AnyView(templateShareLink(template))
        )
    }

    /// Системная кнопка «Поделиться» шаблоном: Mail, Сообщения, AirDrop,
    /// Telegram, WhatsApp — все установленные share-расширения.
    private func templateShareLink(_ template: InterviewTemplate) -> some View {
        ShareLink(
            item: TemplateShareItem(template: template),
            preview: SharePreview(
                "Шаблон AJTBD — \(template.name)",
                image: Image(systemName: "doc.text")
            )
        ) {
            Label("Поделиться…", systemImage: "square.and.arrow.up")
        }
    }

    /// Треугольник раскрытия группы у строки сайдбара.
    private struct RowDisclosure {
        var isExpanded: Bool
        var toggle: () -> Void
    }

    /// Строка сайдбара: имя + бейдж «агент» + корзина при наведении
    /// + контекстное меню (переименовать, экспорт, удалить).
    /// `indent` и `disclosure` рисуют вложенность групп графов.
    private func sidebarRow(
        id: UUID,
        name: String,
        icon: String,
        isAgent: Bool,
        deletable: Bool,
        deleteHelp: String,
        onSelect: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onRename: (() -> Void)?,
        exportItems: [(title: String, action: () -> Void)] = [],
        extraContextItems: AnyView? = nil,
        leadingContextItems: AnyView? = nil,
        indent: CGFloat = 0,
        disclosure: RowDisclosure? = nil,
        mechanicBadge: String? = nil
    ) -> some View {
        HStack(spacing: 2) {
            // Место под треугольник занято всегда — иначе имена строк
            // с потомками и без разъезжаются по горизонтали.
            Group {
                if let disclosure {
                    Button(action: disclosure.toggle) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(disclosure.isExpanded ? 90 : 0))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(disclosure.isExpanded ? "Свернуть группу" : "Развернуть группу")
                    // Опора UI-тестов: «у этого графа есть группа».
                    .accessibilityIdentifier("graphGroupToggle")
                } else {
                    Color.clear
                }
            }
            .frame(width: 12, height: 12)
            Label(name, systemImage: icon)
            if isAgent {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.purple)
                    .help("Создано ИИ-агентом")
            }
            if let mechanicBadge {
                // Граф-потомок, рождённый механикой (⌥Enter): происхождение
                // видно без чтения имени — имя переименуют, бейдж останется.
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
                    .help(mechanicBadge)
            }
            Spacer()
            if hoveredRow == id, deletable {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(deleteHelp)
            }
        }
        .padding(.leading, indent)
        .onHover { inside in
            if inside {
                hoveredRow = id
            } else if hoveredRow == id {
                hoveredRow = nil
            }
        }
        // Двойной клик — переименование (конвенция Finder/Xcode). Жест
        // перехватывает клики у List, поэтому одиночный клик выбирает
        // строку явно — simultaneousGesture, иначе выбор ломается.
        .gesture(TapGesture(count: 2).onEnded { onRename?() })
        .simultaneousGesture(TapGesture().onEnded { onSelect() })
        .contextMenu {
            if let leadingContextItems {
                leadingContextItems
                Divider()
            }
            if let onRename {
                Button("Переименовать", action: onRename)
            }
            if let extraContextItems {
                Divider()
                extraContextItems
            }
            if !exportItems.isEmpty {
                Divider()
                ForEach(exportItems, id: \.title) { item in
                    Button(item.title, action: item.action)
                }
            }
            Divider()
            Button("Удалить", role: .destructive, action: onDelete)
                .disabled(!deletable)
        }
    }

    private func renameField(_ prompt: String, commit: @escaping (String) -> Void) -> some View {
        TextField(prompt, text: $renameDraft)
            .textFieldStyle(.plain)
            .focused($renameFocused)
            .onSubmit {
                commit(renameDraft)
                renamingID = nil
            }
            .onExitCommand { renamingID = nil }
            .onChange(of: renameFocused) { _, focused in
                if !focused, renamingID != nil {
                    commit(renameDraft)
                    renamingID = nil
                }
            }
    }

    private func beginRename(id: UUID, name: String) {
        renameDraft = name
        renamingID = id
        renameFocused = true
    }
}
