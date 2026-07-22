import Foundation

/// Стиль узла определяется уровнем: выше уровень (меньше номер) — крупнее круг.
/// Предварительные значения из дизайн-дока; цвет — токен, маппится на
/// реальный Color на стороне приложения.
public struct LevelStyle: Equatable, Sendable {
    public let diameter: CGFloat
    public let colorToken: String

    static let table: [LevelStyle] = [
        LevelStyle(diameter: 56, colorToken: "level0"),
        LevelStyle(diameter: 34, colorToken: "level1"),
        LevelStyle(diameter: 22, colorToken: "level2"),
        LevelStyle(diameter: 16, colorToken: "level3"),
    ]

    public static func style(for level: Int) -> LevelStyle {
        guard level >= 0 else { return table[0] }
        return level < table.count ? table[level] : LevelStyle(diameter: 12, colorToken: "level4plus")
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
}
