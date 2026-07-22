import SwiftUI
import GraphCore

/// Маппинг цветовых токенов уровня (GraphCore) на реальные цвета.
enum LevelColors {
    static func fill(for level: Int) -> Color {
        switch LevelStyle.style(for: level).colorToken {
        case "level0": return Color(red: 0.34, green: 0.78, blue: 0.91)
        case "level1": return Color(nsColor: .windowBackgroundColor)
        case "level2": return Color(red: 0.94, green: 0.75, blue: 0.29).opacity(0.35)
        case "level3": return Color(red: 0.55, green: 0.78, blue: 0.55).opacity(0.4)
        default: return Color.gray.opacity(0.3)
        }
    }

    static func stroke(for level: Int) -> Color {
        switch LevelStyle.style(for: level).colorToken {
        case "level0": return Color(red: 0.23, green: 0.66, blue: 0.78)
        case "level1": return Color.gray
        case "level2": return Color(red: 0.78, green: 0.6, blue: 0.19)
        case "level3": return Color(red: 0.36, green: 0.6, blue: 0.36)
        default: return Color.gray
        }
    }
}
