import SwiftUI
import GraphCore

/// Маппинг цветовых токенов уровня (GraphCore) на реальные цвета.
/// Вход — сам стиль, а не номер полосы: у core-уровня стиль свой
/// и от номера не зависит (`LevelStyle.core`).
enum LevelColors {
    static func fill(_ style: LevelStyle) -> Color {
        switch style.colorToken {
        case "core": return coreFill
        case "level0": return Color(red: 0.34, green: 0.78, blue: 0.91)
        case "level1": return Color(nsColor: .windowBackgroundColor)
        case "level2": return Color(red: 0.94, green: 0.75, blue: 0.29).opacity(0.35)
        case "level3": return Color(red: 0.55, green: 0.78, blue: 0.55).opacity(0.4)
        default: return Color.gray.opacity(0.3)
        }
    }

    static func stroke(_ style: LevelStyle) -> Color {
        switch style.colorToken {
        case "core": return coreStroke
        case "level0": return Color(red: 0.23, green: 0.66, blue: 0.78)
        case "level1": return Color.gray
        case "level2": return Color(red: 0.78, green: 0.6, blue: 0.19)
        case "level3": return Color(red: 0.36, green: 0.6, blue: 0.36)
        default: return Color.gray
        }
    }

    /// Кóровые работы — тёмно-синий вне шкалы уровней: полоса Core Jobs
    /// узнаётся по цвету на любом месте графа. Контур СВЕТЛЕЕ заливки
    /// (у остальных уровней — темнее): на тёмной теме тёмно-синий кружок
    /// иначе слился бы с полосой, а имя полосы стало бы нечитаемым.
    static let coreFill = Color(red: 0.13, green: 0.28, blue: 0.62)
    static let coreStroke = Color(red: 0.30, green: 0.48, blue: 0.85)

    /// Область уровня (LevelZone) — работы того же уровня, которые
    /// продукт не выполняет. Цвет намеренно вне шкалы уровней: рамка
    /// читается как «другая область», а не «другой уровень».
    static let zoneFill = Color(red: 0.58, green: 0.51, blue: 0.85)
    static let zoneStroke = Color(red: 0.44, green: 0.36, blue: 0.74)
}
