import XCTest

/// Палитра механик ценности (⌘K) + регрессия рендера канваса после
/// изменения сигнатуры nodeView (параметр fate).
/// НЕ запускать, пока за машиной работает человек — UI-тест перехватывает
/// фокус. Работает в НОВОМ документе, живые файлы не трогает.
final class MechanicPaletteUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Регрессия nodeView: рендер узлов не сломан добавлением параметра
    /// судьбы. Строим три работы, проверяем что все подписи на канвасе.
    func testCanvasStillRendersAfterGhostParameter() {
        let app = XCUIApplication()
        app.launch()

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
        let app = XCUIApplication()
        app.launch()

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

        // Enter — применить: работа исчезает с канваса.
        app.typeKey(.return, modifierFlags: [])
        XCTAssertFalse(
            app.staticTexts["хочу лишний шаг"].waitForExistence(timeout: 2),
            "kill-a-job должен убрать работу"
        )

        // ⌘Z — работа возвращается (одна undo-группа).
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(
            app.staticTexts["хочу лишний шаг"].waitForExistence(timeout: 3),
            "⌘Z должен вернуть убитую работу одним шагом"
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
        let app = XCUIApplication()
        app.launch()

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

        // Взводим снова и стреляем по работе — она исчезает.
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        app.typeText("убить")
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.click()
        target.click()
        XCTAssertFalse(
            app.staticTexts["хочу цель для клика"].waitForExistence(timeout: 2),
            "клик по работе взведённой механикой должен её убить"
        )

        // ⌘Z возвращает.
        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(
            app.staticTexts["хочу цель для клика"].waitForExistence(timeout: 3),
            "⌘Z должен вернуть работу"
        )
    }
}
