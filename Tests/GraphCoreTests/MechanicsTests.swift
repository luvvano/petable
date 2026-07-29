import Foundation
import Testing
@testable import GraphCore

@Suite("Справочник механик")
struct MechanicsTests {
    // MARK: - Ресурс и резолв словаря

    @Test("1. Канон читается из ресурсов и разбирается целиком")
    func catalogLoads() throws {
        let catalog = try MechanicCatalog.load().get()
        #expect(catalog.mechanics.count == MechanicCatalog.expectedSectionCount)
    }

    @Test("2. Все 25 слагов резолвятся против реальных заголовков канона")
    func allSlugsResolve() throws {
        // Главный тест словаря: падает после `git pull` канона, если
        // заголовок переименовали. Молча потерять механику нельзя —
        // слаг лежит в документах как ключ стикера и происхождения.
        let catalog = try MechanicCatalog.load().get()
        for entry in MechanicCatalog.entries {
            #expect(
                catalog.mechanic(entry.slug) != nil,
                "слаг \(entry.slug) не разрезолвился — заголовок «\(entry.canonTitle)» пропал из канона"
            )
        }
    }

    @Test("3. Слаги уникальны")
    func slugsAreUnique() {
        let slugs = MechanicCatalog.entries.map(\.slug)
        #expect(Set(slugs).count == slugs.count)
    }

    @Test("4. Классы распределены 7/4/14")
    func classDistribution() throws {
        let catalog = try MechanicCatalog.load().get()
        #expect(catalog.mechanics(of: .topology).count == 7)
        #expect(catalog.mechanics(of: .jobCard).count == 4)
        #expect(catalog.mechanics(of: .sticker).count == 14)
    }

    @Test("5. Атрибуция автора канона не потерялась")
    func attributionSurvives() throws {
        let catalog = try MechanicCatalog.load().get()
        #expect(catalog.attribution.contains("Ivan Zamesin"))
        #expect(catalog.attribution.contains("CC BY-NC-SA 4.0"))
    }

    @Test("6. У каждой механики есть тезис, у каждой — примеры")
    func sectionsCarryContent() throws {
        let catalog = try MechanicCatalog.load().get()
        for mechanic in catalog.mechanics {
            #expect(!mechanic.thesis.isEmpty, "пустой тезис у \(mechanic.slug)")
            #expect(
                mechanic.examples.hasPrefix("Examples:"),
                "нет блока примеров у \(mechanic.slug)"
            )
        }
    }

    @Test("7. Ссылки Deeper: и разделители --- не попадают в тело")
    func deeperLinksDropped() throws {
        let catalog = try MechanicCatalog.load().get()
        for mechanic in catalog.mechanics {
            #expect(!mechanic.body.contains("Deeper:"), "Deeper: в теле \(mechanic.slug)")
            #expect(!mechanic.thesis.hasPrefix("---"))
        }
    }

    // MARK: - Разбор без бандла

    @Test("8. Текст без секций «### » — не канон")
    func parseRejectsNonCanon() {
        let result = MechanicCatalog.parse("# Заголовок\n\nпросто текст\n")
        #expect(result == .failure(.malformed("ноль секций «### » — это не файл канона")))
    }

    @Test("9. Пропавший заголовок — явная ошибка со слагом, а не тихая потеря")
    func missingHeadingReported() {
        // Канон, где есть только одна секция: остальные 24 записи словаря
        // не резолвятся, и разбор обязан назвать их поимённо.
        let result = MechanicCatalog.parse("### Kill a Job\n\n**Тезис.**\n\nExamples: x.\n")
        guard case let .failure(.unresolvedEntries(slugs)) = result else {
            Issue.record("ожидалась .unresolvedEntries, получено \(result)")
            return
        }
        #expect(slugs.count == MechanicCatalog.entries.count - 1)
        #expect(!slugs.contains("kill-a-job"))
    }

    @Test("10. «### » в середине строки секцией не считается")
    func headingOnlyAtLineStart() {
        let sections = MechanicCatalog.sections(
            in: "### Первая\n\nтекст со словами ### не в начале\n\n### Вторая\n\nтело\n"
        )
        #expect(sections.count == 2)
        #expect(sections["Первая"] != nil)
        #expect(sections["Вторая"] != nil)
    }

    @Test("11. Первый абзац — тезис, Examples: — блоком, Deeper: отброшен")
    func sectionRoles() {
        let section = MechanicCatalog.section(from: [
            "**Жирный тезис.** Продолжение тезиса.",
            "",
            "Второй абзац — тело.",
            "",
            "Examples: пример один; пример два. И ещё пример.",
            "",
            "Deeper: [ссылка](file.md).",
            "",
            "---",
        ])
        #expect(section.thesis == "**Жирный тезис.** Продолжение тезиса.")
        #expect(section.body == "Второй абзац — тело.")
        #expect(section.examples == "Examples: пример один; пример два. И ещё пример.")
    }
}
