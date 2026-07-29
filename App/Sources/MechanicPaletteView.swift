import GraphCore
import SwiftUI

/// Справочник загружается один раз за запуск: файл вшит в бандл и не
/// меняется. Result, а не крэш и не пустота — отсутствие ресурса это
/// баг конфигурации сборки, и палитра называет его вслух.
enum MechanicCatalogStore {
    static let result = MechanicCatalog.load()
}

/// Палитра механик ценности (⌘K): все 25 механик канона, поиск, ↑/↓ с
/// живым призраком на канвасе, Enter — применить, ⌥Enter — форк, Esc —
/// закрыть. Мёртвых и серых плиток нет: все механики одного активного
/// цвета вне зависимости от выделения; Enter на механике, неприменимой
/// к текущему выделению, взводит её — цель выбирается кликом на канвасе.
/// Нижняя панель — русское описание и превью механики на примере графа.
struct MechanicPaletteView: View {
    let catalog: Catalog
    /// Якорь из выделения канваса — палитра его не меняет.
    let anchor: MechanicAnchor
    let graph: WorkGraph
    /// Потолок размера — видимая область канваса: палитра не должна
    /// вылезать за окно даже после ресайза на большом мониторе.
    var maxSize = CGSize(width: 900, height: 1000)
    /// Механика под курсором списка — канвас рисует по ней призрак.
    @Binding var highlighted: String?
    /// Заметка стикера — вводится прямо в палитре.
    @State private var stickerNote = ""
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    /// Размер палитры: тянется за грип в правом нижнем углу,
    /// запоминается между запусками (паттерн agent.chatWidth).
    @AppStorage("mechanics.paletteWidth") private var paletteWidth = 430.0
    @AppStorage("mechanics.paletteHeight") private var paletteHeight = 620.0
    @State private var sizeAtDragStart: CGSize?

    private static let minWidth = 360.0
    private static let minHeight = 420.0

    let onApply: (Mechanic, String) -> Void
    /// Клик по строке: взвести механику — палитра закрывается, курсор
    /// становится прицелом, клик по работе на канвасе применяет.
    let onArm: (Mechanic) -> Void
    let onFork: (Mechanic) -> Void
    let onClose: () -> Void

    private var filtered: [Mechanic] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return catalog.mechanics }
        return catalog.mechanics.filter {
            $0.title.lowercased().contains(trimmed)
                || $0.canonTitle.lowercased().contains(trimmed)
                || $0.slug.contains(trimmed)
        }
    }

    private var highlightedMechanic: Mechanic? {
        highlighted.flatMap { catalog.mechanic($0) }
    }

    /// Причина неприменимости выделенной механики; nil — применима.
    private func unavailability(_ mechanic: Mechanic) -> MechanicUnavailable? {
        switch mechanic.mechanicClass {
        case .topology:
            if case let .failure(reason) = MechanicTransform.preview(
                mechanic.slug, in: graph, anchor: anchor
            ) { return reason }
            return nil
        case .jobCard:
            if case let .failure(reason) = MechanicTransform.cardPreview(
                mechanic.slug, in: graph, anchor: anchor
            ) { return reason }
            return nil
        case .sticker:
            // Стикер применим всегда — даже без якоря (унесётся на граф).
            return nil
        }
    }

    /// Фактический размер: пользовательский, зажатый между минимумом
    /// (ниже — ломается вёрстка) и видимой областью канваса.
    private var displaySize: CGSize {
        CGSize(
            width: min(max(paletteWidth, Self.minWidth), max(maxSize.width, Self.minWidth)),
            height: min(max(paletteHeight, Self.minHeight), max(maxSize.height, Self.minHeight))
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            mechanicList
            Divider()
            detailPane
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator, lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) { resizeGrip }
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .onAppear {
            searchFocused = true
            if highlighted == nil { highlighted = filtered.first?.id }
        }
        .onChange(of: query) { _, _ in
            // Фильтр сузился — подсветка не должна указывать в пустоту.
            if let highlighted, !filtered.contains(where: { $0.id == highlighted }) {
                self.highlighted = filtered.first?.id
            } else if highlighted == nil {
                highlighted = filtered.first?.id
            }
        }
        .onChange(of: highlighted) { _, _ in stickerNote = "" }
    }

    // MARK: - Поиск и клавиатура

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .foregroundStyle(.secondary)
            TextField("Механика ценности…", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                // Поле поиска съедает ↑/↓ (на macOS они двигают каретку) —
                // перехват через onKeyPress, прецедент в CanvasRootView.
                .onKeyPress(.upArrow) { move(-1); return .handled }
                .onKeyPress(.downArrow) { move(1); return .handled }
                .onKeyPress(.return) {
                    commit(fork: NSEvent.modifierFlags.contains(.option))
                    return .handled
                }
                .onKeyPress(.escape) {
                    onClose()
                    return .handled
                }
            // ✕ — явный выход мышью; Esc и клик мимо палитры делают то же.
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Закрыть (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func move(_ delta: Int) {
        let list = filtered
        guard !list.isEmpty else { return }
        let currentIndex = highlighted.flatMap { id in list.firstIndex { $0.id == id } } ?? -1
        let next = min(max(currentIndex + delta, 0), list.count - 1)
        // Та же пружина, что у обычных мутаций графа (решение 11B):
        // один язык движения во всём приложении.
        withAnimation(.spring(duration: 0.35)) {
            highlighted = list[next].id
        }
    }

    private func commit(fork: Bool) {
        guard let mechanic = highlightedMechanic else { return }
        // Механика неприменима к текущему выделению — Enter не мёртвый:
        // взводит её, цель выбирается кликом на канвасе.
        guard unavailability(mechanic) == nil else {
            onArm(mechanic)
            return
        }
        if fork {
            onFork(mechanic)
        } else {
            onApply(mechanic, stickerNote)
        }
    }

    // MARK: - Список

    private var mechanicList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filtered) { mechanic in
                        row(mechanic)
                            .id(mechanic.id)
                    }
                }
                .padding(6)
            }
            // Список забирает всю высоту между поиском и нижней панелью —
            // именно он растёт при вертикальном ресайзе палитры.
            .frame(maxHeight: .infinity)
            .onChange(of: highlighted) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    @ViewBuilder
    private func row(_ mechanic: Mechanic) -> some View {
        let isHighlighted = highlighted == mechanic.id

        // Все плитки одного активного цвета вне зависимости от выделения:
        // клик всегда работает (взводит механику), значит и выглядеть
        // выключенной плитка не имеет права. Применимость к текущему
        // выделению объясняет нижняя панель, а не серость строки.
        HStack(spacing: 8) {
            // Изображение механики — то же, что у её комментария на графе:
            // одна картинка от палитры до бейджа на работе.
            Image(systemName: mechanic.symbol)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .frame(width: 16)
            Text(mechanic.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary)
            Spacer()
            Text(mechanic.mechanicClass.title)
                .font(.system(size: 9.5))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            isHighlighted ? Color.accentColor.opacity(0.14) : .clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .contentShape(Rectangle())
        // Клик — взвести: курсор станет прицелом, клик по работе на
        // канвасе применит механику к ней. Наведение — подсветка с
        // призраком по текущему выделению (если применима).
        .onTapGesture { onArm(mechanic) }
        .onHover { inside in
            guard inside, highlighted != mechanic.id else { return }
            withAnimation(.spring(duration: 0.35)) { highlighted = mechanic.id }
        }
        .help("Клик — выбрать цель на канвасе · Enter — применить к выделенному")
    }

    // MARK: - Ресайз

    /// Грип в правом нижнем углу: тянется по горизонтали и вертикали,
    /// размер зажимается в displaySize и живёт в AppStorage.
    private var resizeGrip: some View {
        Path { path in
            path.move(to: CGPoint(x: 13, y: 5))
            path.addLine(to: CGPoint(x: 5, y: 13))
            path.move(to: CGPoint(x: 13, y: 9))
            path.addLine(to: CGPoint(x: 9, y: 13))
        }
        .stroke(Color.secondary.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        .frame(width: 18, height: 18)
        .padding(4)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                resizeCursor.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = sizeAtDragStart ?? displaySize
                    sizeAtDragStart = start
                    paletteWidth = start.width + value.translation.width
                    paletteHeight = start.height + value.translation.height
                }
                .onEnded { _ in
                    sizeAtDragStart = nil
                    // Захлопнуть сохранённое значение в допустимые рамки:
                    // за пределами оно всё равно не отображается.
                    paletteWidth = displaySize.width
                    paletteHeight = displaySize.height
                }
        )
        .help("Потянуть — изменить размер палитры")
    }

    /// Диагональный курсор ресайза появился в macOS 15; на 14 — стрелки.
    private var resizeCursor: NSCursor {
        if #available(macOS 15.0, *) {
            return .frameResize(position: .bottomRight, directions: .all)
        }
        return .resizeLeftRight
    }

    // MARK: - Карточка механики: описание + превью на примере

    @ViewBuilder
    private var detailPane: some View {
        if let mechanic = highlightedMechanic {
            VStack(alignment: .leading, spacing: 6) {
                // Русское описание — своя формулировка из словаря; тезис
                // канона остаётся английским в самом файле канона (P7).
                Text(mechanic.summary.isEmpty ? mechanic.thesis : mechanic.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Превью механики на каноническом примере графа работ —
                // видно, что она делает, даже без выделения на канвасе.
                MechanicMiniPreview(mechanic: mechanic)
                    .id(mechanic.id)
                if mechanic.mechanicClass == .sticker, unavailability(mechanic) == nil {
                    TextField("Заметка: почему эта механика здесь…", text: $stickerNote)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                }
                HStack {
                    Text(hint(for: mechanic))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    // Атрибуция — условие CC BY-NC-SA, показывается всегда.
                    Text("Канон: Иван Замесин, CC BY-NC-SA 4.0")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
            }
            .padding(10)
        }
    }

    private func hint(for mechanic: Mechanic) -> String {
        // Клик работает всегда: цель выбирается на канвасе после взвода.
        guard unavailability(mechanic) == nil else {
            return "Клик или Enter — выбрать цель на канвасе"
        }
        switch mechanic.mechanicClass {
        case .topology: return "Клик — выбрать цель · Enter — применить · ⌥Enter — в новый граф"
        case .jobCard: return "Клик — выбрать цель · Enter — применить к карточке"
        case .sticker: return "Клик — выбрать цель · Enter — повесить заметку"
        }
    }
}

/// Ошибка загрузки справочника: показывается вместо палитры. Явный текст
/// вместо пустого списка — пустая палитра неотличима от «ничего не
/// применимо», а это два разных мира.
struct MechanicCatalogErrorView: View {
    let error: CatalogError
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.orange)
            Text(error.localizedDescription)
                .font(.callout)
                .multilineTextAlignment(.center)
            Button("Закрыть") { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
    }
}
