import XCTest

/// Палитра механик ценности (⌘K) + регрессия рендера канваса после
/// изменения сигнатуры nodeView (параметр fate).
/// НЕ запускать, пока за машиной работает человек — UI-тест перехватывает
/// фокус. Работает в НОВОМ документе, живые файлы не трогает.
final class MechanicPaletteUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Изолированная копия приложения через TEST_RUNNER_PETABLE_UITEST_APP:
    /// голый XCUIApplication() цепляется к уже запущенной рабочей копии
    /// и правит живой документ (паттерн CopyPasteUITests).
    private func launchApp() -> XCUIApplication {
        let path = ProcessInfo.processInfo.environment["PETABLE_UITEST_APP"]
        let app = path.map { XCUIApplication(url: URL(fileURLWithPath: $0)) } ?? XCUIApplication()
        app.launch()
        app.activate()
        // Свежая копия открывает хаб «Проекты» — документ создаётся
        // первым пунктом меню «Файл» (⌘N до хаба не доходит).
        if !app.textFields.firstMatch.waitForExistence(timeout: 2) {
            let fileMenu = app.menuBars.menuBarItems["Файл"]
            XCTAssertTrue(fileMenu.waitForExistence(timeout: 8))
            fileMenu.click()
            fileMenu.menuItems.element(boundBy: 0).click()
        }
        return app
    }

    /// Регрессия nodeView: рендер узлов не сломан добавлением параметра
    /// судьбы. Строим три работы, проверяем что все подписи на канвасе.
    func testCanvasStillRendersAfterGhostParameter() {
        let app = launchApp()

        let editor = app.textFields.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.typeText("Закрыть месяц")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Закрыть месяц"].waitForExistence(timeout: 3))

        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 3))
        app.typeText("бухгалтер: хочу собрать транзакции")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["хочу собрать транзакции"].waitForExistence(timeout: 3))

        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 3))
        app.typeText("контролёр: хочу сверить отчёты")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["хочу сверить отчёты"].waitForExistence(timeout: 3))

        // Все три работы одновременно на канвасе — рендер цел.
        XCTAssertTrue(app.staticTexts["Закрыть месяц"].exists)
        XCTAssertTrue(app.staticTexts["хочу собрать транзакции"].exists)
    }

    /// Жест палитры целиком: ⌘K → список открыт → поиск фильтрует →
    /// Enter применяет топологическую механику → ⌘Z откатывает → Esc.
    func testPaletteApplyAndUndo() {
        let app = launchApp()

        // Цепочка из двух работ: голова и продолжение.
        let editor = app.textFields.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.typeText("Закрыть месяц")
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 3))
        app.typeText("хочу лишний шаг")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["хочу лишний шаг"].waitForExistence(timeout: 3))

        // Выделение осталось на «хочу лишний шаг» — открываем палитру.
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["Механика ценности…"]
        XCTAssertTrue(search.waitForExistence(timeout: 3), "⌘K должен открыть палитру")

        // Поиск сужает список до «убить работу».
        app.typeText("убить")
        XCTAssertTrue(app.staticTexts["Убить работу"].waitForExistence(timeout: 3))

        // Enter — применить: работа НЕ исчезает с канваса — остаётся
        // перечёркнутой (v13), палитра закрывается.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(search.waitForExistence(timeout: 2), "Enter должен закрыть палитру")
        XCTAssertTrue(
            app.staticTexts["хочу лишний шаг"].exists,
            "убитая работа должна остаться на графе перечёркнутой"
        )

        // ⌘Z — крестик снят (одна undo-группа), работа на месте.
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(
            app.staticTexts["хочу лишний шаг"].waitForExistence(timeout: 3),
            "после ⌘Z работа остаётся на канвасе"
        )

        // Esc закрывает палитру, граф не тронут.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(search.exists, "Esc должен закрыть палитру")
        XCTAssertTrue(app.staticTexts["хочу лишний шаг"].exists)
    }

    /// Взведённый режим: клик по механике в палитре → чип-подсказка →
    /// клик по работе применяет → Esc отбивает взвод.
    func testArmedMechanicFlow() {
        let app = launchApp()

        let editor = app.textFields.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.typeText("Закрыть месяц")
        app.typeKey(.return, modifierFlags: [])
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 3))
        app.typeText("хочу цель для клика")
        app.typeKey(.return, modifierFlags: [])
        let target = app.staticTexts["хочу цель для клика"]
        XCTAssertTrue(target.waitForExistence(timeout: 3))

        // ⌘K → найти механику → КЛИК по строке взводит.
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["Механика ценности…"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        app.typeText("убить")
        let row = app.staticTexts["Убить работу"]
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.click()

        // Палитра закрылась, чип взведённого режима на экране.
        XCTAssertFalse(search.exists, "клик по механике должен закрыть палитру")
        XCTAssertTrue(
            app.staticTexts
                .containing(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "кликните", "кликните"))
                .firstMatch
                .waitForExistence(timeout: 3),
            "чип должен подсказывать, куда кликать"
        )

        // Esc — отбой: чип исчезает, работа на месте.
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(target.exists)

        // Взводим снова и стреляем по работе — она остаётся на графе
        // перечёркнутой (v13), а запись механики появляется в комментариях.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        app.typeText("убить")
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.click()
        target.click()
        XCTAssertTrue(
            app.staticTexts["хочу цель для клика"].waitForExistence(timeout: 2),
            "убитая работа должна остаться на графе перечёркнутой"
        )

        // ⌘Z снимает крестик — работа на месте.
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(
            app.staticTexts["хочу цель для клика"].waitForExistence(timeout: 3),
            "после ⌘Z работа остаётся на канвасе"
        )
    }

    /// Запись механики персистентна: применённый стикер не исчезает после
    /// следующего действия — счётчик комментариев жив, сайдбар показывает
    /// запись с заголовком механики.
    func testAppliedMechanicPersistsAsComment() {
        let app = launchApp()

        let editor = app.textFields.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        app.typeText("Закрыть месяц")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Закрыть месяц"].waitForExistence(timeout: 3))

        // Выделение осталось на работе — применяем стикерную механику Enter'ом.
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["Механика ценности…"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        app.typeText("снизить цену")
        XCTAssertTrue(app.staticTexts["Снизить цену"].waitForExistence(timeout: 3))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(search.exists, "Enter должен применить механику и закрыть палитру")

        // Любое следующее действие: декомпозиция уровнем ниже.
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 3))
        app.typeText("хочу собрать транзакции")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["хочу собрать транзакции"].waitForExistence(timeout: 3))

        // Запись не исчезла: сайдбар комментариев показывает её.
        let toggle = app.buttons["commentsToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3), "кнопка комментариев должна быть на канвасе")
        toggle.click()
        XCTAssertTrue(
            app.staticTexts["Снизить цену"].waitForExistence(timeout: 3),
            "запись применённой механики должна остаться в сайдбаре комментариев"
        )
    }
}
