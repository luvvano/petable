import Foundation

/// Справочник механик создания ценности (канон AJTBD).
///
/// Текст канона лежит ресурсом рядом с кодом и НЕ переписывается в Swift:
/// это чужая работа под CC BY-NC-SA 4.0, её обновляют копированием файла.
/// Из Swift приходят только слаги, русские заголовки и класс механики —
/// см. `MechanicCatalog.entries`.
///
/// Загрузка возвращает `Result`, а не падает и не отдаёт пустоту молча:
/// отсутствие ресурса — баг конфигурации сборки. `swift test` видит
/// `Bundle.module` всегда, а приложение собирается через xcodebuild с
/// локально подключённым пакетом — это разные пути, и пустая палитра
/// без объяснения стоит часа отладки при зелёных тестах.
public enum CatalogError: Error, Equatable, Sendable {
    /// Ресурс не доехал до бандла — проверить `resources:` в Package.swift.
    case resourceNotFound
    /// Ресурс найден, но не похож на канон (ноль секций `### `).
    case malformed(String)
    /// Заголовок из словаря не найден в каноне: файл обновили, слаги
    /// разъехались. Молча терять механику нельзя — она ключ в документе.
    case unresolvedEntries([String])
}

extension CatalogError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .resourceNotFound:
            return "Справочник механик не загружен: ресурс не найден в бандле приложения."
        case let .malformed(detail):
            return "Справочник механик повреждён: \(detail)"
        case let .unresolvedEntries(slugs):
            return "Справочник разошёлся с каноном, не найдены: \(slugs.joined(separator: ", "))."
        }
    }
}

/// Одна механика канона: стабильный слаг и класс из словаря плюс текст из
/// ресурса. Тезис, тело и примеры — английские as-is.
public struct Mechanic: Identifiable, Equatable, Sendable {
    public var id: String { slug }
    public let slug: String
    /// Заголовок канона дословно.
    public let canonTitle: String
    /// Русский заголовок для UI.
    public let title: String
    public let mechanicClass: MechanicClass
    /// Первый абзац секции — обычно жирный тезис. Может быть пустым.
    public let thesis: String
    /// Остальной текст без блока примеров и без ссылок `Deeper:`.
    public let body: String
    /// Блок `Examples: …` ЦЕЛИКОМ, без разбиения на элементы: в разных
    /// механиках примеры разделены то `;`, то точкой — резать нечем.
    public let examples: String

    public init(
        slug: String,
        canonTitle: String,
        title: String,
        mechanicClass: MechanicClass,
        thesis: String,
        body: String,
        examples: String
    ) {
        self.slug = slug
        self.canonTitle = canonTitle
        self.title = title
        self.mechanicClass = mechanicClass
        self.thesis = thesis
        self.body = body
        self.examples = examples
    }
}

/// Разобранный справочник.
public struct Catalog: Equatable, Sendable {
    public let mechanics: [Mechanic]
    /// Футер канона — показывается в UI как есть (условие CC BY-NC-SA).
    public let attribution: String

    public init(mechanics: [Mechanic], attribution: String) {
        self.mechanics = mechanics
        self.attribution = attribution
    }

    public func mechanic(_ slug: String) -> Mechanic? {
        mechanics.first { $0.slug == slug }
    }

    public func mechanics(of mechanicClass: MechanicClass) -> [Mechanic] {
        mechanics.filter { $0.mechanicClass == mechanicClass }
    }
}

public enum MechanicCatalog {
    static let resourceName = "value-creation-mechanics"
    static let resourceExtension = "md"

    /// Ожидаемое число секций. Расхождение — сигнал, что файл подменили.
    public static let expectedSectionCount = 25

    // MARK: - Загрузка

    /// Читает и разбирает канон из ресурсов пакета.
    public static func load() -> Result<Catalog, CatalogError> {
        guard let url = Bundle.module.url(
            forResource: resourceName,
            withExtension: resourceExtension
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .failure(.resourceNotFound)
        }
        return parse(text)
    }

    /// Отдельно от `load()`, чтобы разбор тестировался без бандла.
    static func parse(_ text: String) -> Result<Catalog, CatalogError> {
        let sections = sections(in: text)
        guard !sections.isEmpty else {
            return .failure(.malformed("ноль секций «### » — это не файл канона"))
        }

        var mechanics: [Mechanic] = []
        var unresolved: [String] = []
        for entry in entries {
            guard let section = sections[entry.canonTitle] else {
                unresolved.append(entry.slug)
                continue
            }
            mechanics.append(
                Mechanic(
                    slug: entry.slug,
                    canonTitle: entry.canonTitle,
                    title: entry.title,
                    mechanicClass: entry.mechanicClass,
                    thesis: section.thesis,
                    body: section.body,
                    examples: section.examples
                )
            )
        }
        guard unresolved.isEmpty else {
            return .failure(.unresolvedEntries(unresolved))
        }
        return .success(Catalog(mechanics: mechanics, attribution: attribution(in: text)))
    }

    // MARK: - Разбор markdown

    struct Section: Equatable {
        var thesis: String
        var body: String
        var examples: String
    }

    /// Секции канона по заголовку. Заголовок считается только в начале
    /// строки: `### ` внутри абзаца — часть текста, а не новая секция.
    static func sections(in text: String) -> [String: Section] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String: Section] = [:]
        var currentTitle: String?
        var buffer: [String] = []

        func flush() {
            guard let title = currentTitle else { return }
            result[title] = section(from: buffer)
            buffer = []
        }

        for line in lines {
            if line.hasPrefix("### ") {
                flush()
                currentTitle = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            } else if currentTitle != nil {
                buffer.append(line)
            }
        }
        flush()
        return result
    }

    /// Абзацы секции раскладываются по ролям: первый — тезис, блок
    /// `Examples:` — примеры целиком, `Deeper:` и разделители `---`
    /// отбрасываются, остальное — тело.
    static func section(from lines: [String]) -> Section {
        let paragraphs = paragraphs(in: lines)
        var thesis = ""
        var examples = ""
        var body: [String] = []

        for paragraph in paragraphs {
            if paragraph.hasPrefix("Examples:") {
                examples = paragraph
            } else if paragraph.hasPrefix("Deeper:") || paragraph == "---" {
                continue
            } else if thesis.isEmpty {
                thesis = paragraph
            } else {
                body.append(paragraph)
            }
        }
        return Section(
            thesis: thesis,
            body: body.joined(separator: "\n\n"),
            examples: examples
        )
    }

    /// Абзацы = группы непустых строк. Пустая строка — разделитель.
    static func paragraphs(in lines: [String]) -> [String] {
        var result: [String] = []
        var current: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty {
                    result.append(current.joined(separator: "\n"))
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { result.append(current.joined(separator: "\n")) }
        return result
    }

    /// Футер канона: строка, начинающаяся с `*Methodology`. Не найдена —
    /// пустая строка: UI не покажет подпись, но не упадёт.
    static func attribution(in text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .last { $0.hasPrefix("*Methodology") }
            .map { String($0) } ?? ""
    }
}
