import Foundation

/// Грамматика `role:`: строка сплитится по ПЕРВОМУ двоеточию, и только если
/// префикс — сплошные буквы, а после двоеточия есть пробел (`^[\p{L}]+:\s`).
/// «https://…» (нет пробела), «12:30» (цифры) и технические префиксы ролью
/// не становятся — вся строка остаётся verb'ом.
public enum RoleParser {
    /// Разбирает сырой ввод редактора в (role, verb).
    public static func parse(_ raw: String) -> (role: String?, verb: String) {
        let rolePattern = /^([\p{L}]+):\s+(\S.*)$/.dotMatchesNewlines()
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = trimmed.wholeMatch(of: rolePattern) else {
            return (nil, trimmed)
        }
        return (String(match.1), String(match.2).trimmingCharacters(in: .whitespaces))
    }
}
