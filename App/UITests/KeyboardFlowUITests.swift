import XCTest

/// Автоматизация ручной части тест-плана: клавиатурный ввод графа.
/// НЕ запускать, пока за машиной работает человек — UI-тест перехватывает
/// фокус. Запуск: xcodebuild test -project petable.xcodeproj -scheme petable
final class KeyboardFlowUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Критический путь тест-плана: новый документ → корень в режиме
    /// редактирования → ввод клавиатурой → ребёнок → сиблинг → undo.
    func testKeyboardEntryFlow() {
        let app = XCUIApplication()
        app.launch()

        // Новый документ открывается с корнем в инлайн-редакторе.
        let editor = app.textFields.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "корень должен быть в режиме редактирования")

        // Корень: заголовок.
        app.typeText("Проверить приёмку petable")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Проверить приёмку petable"].waitForExistence(timeout: 3))

        // Tab → ребёнок корня, редактор открыт.
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 3))
        app.typeText("бухгалтер: хочу первый шаг")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["хочу первый шаг"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["бухгалтер:"].exists)

        // ⌘Return → сиблинг после.
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 3))
        app.typeText("контролёр: хочу второй шаг")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["хочу второй шаг"].waitForExistence(timeout: 3))

        // ⌘Z ×2 → второй шаг исчезает (undo setText, undo addSibling).
        app.typeKey("z", modifierFlags: .command)
        app.typeKey("z", modifierFlags: .command)
        XCTAssertFalse(app.staticTexts["хочу второй шаг"].exists, "undo должен убрать сиблинга")

        // ⇧⌘Z ×2 → возвращается.
        app.typeKey("z", modifierFlags: [.command, .shift])
        app.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.staticTexts["хочу второй шаг"].waitForExistence(timeout: 3), "redo должен вернуть сиблинга")

        // Esc в редакторе нового узла — узел исчезает.
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 3))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.textFields.firstMatch.exists, "Esc должен закрыть редактор и удалить пустой узел")
    }
}
