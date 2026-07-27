import Foundation

/// Стиль узла определяется уровнем: выше уровень (меньше номер) — крупнее круг.
/// Предварительные значения из дизайн-дока; цвет — токен, маппится на
/// реальный Color на стороне приложения.
///
/// Исключение — core-уровень: у него собственный стиль, не зависящий
/// от номера полосы (см. `core`).
public struct LevelStyle: Equatable, Sendable {
    public let diameter: CGFloat
    public let colorToken: String

    static let table: [LevelStyle] = [
        LevelStyle(diameter: 56, colorToken: "level0"),
        LevelStyle(diameter: 34, colorToken: "level1"),
        LevelStyle(diameter: 22, colorToken: "level2"),
        LevelStyle(diameter: 16, colorToken: "level3"),
    ]

    /// Кóровые работы: продукт выполняет их целиком — это опора графа,
    /// и выглядит она всегда одинаково. Уровень, вставленный сверху,
    /// сдвигает номер полосы, но не меняет ни размер кружка, ни цвет:
    /// иначе тот же граф читался бы как другой. Размер — как у второй
    /// полосы шкалы, цвет — тёмно-синий (токен `core`).
    public static let core = LevelStyle(diameter: table[1].diameter, colorToken: "core")

    /// Верхняя ступень шкалы — самый крупный кружок. Подпись под ним
    /// крупнее и жирнее; у остальных (включая кóровые) — обычная.
    public var isTopScale: Bool { colorToken == "level0" }

    public static func style(for level: Int, isCore: Bool = false) -> LevelStyle {
        if isCore { return core }
        guard level >= 0 else { return table[0] }
        return level < table.count ? table[level] : LevelStyle(diameter: 12, colorToken: "level4plus")
    }
}

public extension WorkGraph {
    /// Стиль работ полосы по её номеру — единственный способ получить
    /// стиль в вьюхах: только граф знает, какая полоса кóровая.
    func style(atLevel index: Int) -> LevelStyle {
        let isCore = levels.indices.contains(index) && levels[index].isCore
        return LevelStyle.style(for: index, isCore: isCore)
    }
}

/// Константы раскладки. Ширина колонки узла фиксированная, в вертикальном
/// интервале уровня зарезервированы 3 строки подписи (layout остаётся чистой
/// функцией от дерева — измерять текст не нужно; длиннее — truncation с …).
public enum LayoutMetrics {
    public static let columnWidth: CGFloat = 130
    /// Резерв подписи: 3 строки × 14pt + отступ.
    public static let labelReserve: CGFloat = 50
    /// Полная высота ряда уровня: максимальный круг + подпись + зазор.
    public static let rowHeight: CGFloat = 150
    /// Зазор между занятым местом полосы (колонкой работы или рамкой
    /// соседней области) и следующей рамкой: соседние области читаются
    /// как «рядом, справа», а не как одна вложенная в другую. Ширины
    /// хватает под кнопку «+ работа» основной области — она не наезжает
    /// на рамку.
    public static let zoneGap: CGFloat = 96
    /// Отступ рамки области от крайних работ внутри неё.
    public static let zonePadding: CGFloat = 14
    /// Ширина рамки области без работ — место под неё резервируется,
    /// иначе пустая область схлопнулась бы под соседние узлы.
    public static let emptyZoneWidth: CGFloat = 150
}
