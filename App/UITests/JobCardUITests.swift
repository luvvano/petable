import XCTest

/// Карточка работы: открывается двойным кликом по узлу, закрывается
/// крестиком, Esc и кликом мимо неё.
/// НЕ запускать, пока за машиной работает человек — UI-тест перехватывает
/// фокус. Приложение при этом не должно быть запущено: XCUIApplication()
/// цепляется к работающей копии вместе с открытыми в ней документами.
/// Запуск: xcodebuild test -project petable.xcodeproj -scheme petable
///   -only-testing:petableUITests/JobCardUITests
final class JobCardUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private var app: XCUIApplication!
    private var window: XCUIElement!

    /// Кнопка закрытия карточки — признак того, что карточка на экране.
    private var closeButton: XCUIElement {
        window.buttons["Закрыть карточку (Esc)"].firstMatch
    }

    /// Документ с одной работой «хочу проверить карточку» и открытой
    /// на ней карточкой.
    private func openCardOnSingleJob() {
        let path = ProcessInfo.processInfo.environment["PETABLE_UITEST_APP"]
        app = path.map { XCUIApplication(url: URL(fileURLWithPath: $0)) } ?? XCUIApplication()
        app.launch()
        app.activate()
        let fileMenu = app.menuBars.menuBarItems["Файл"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 8))
        fileMenu.click()
        fileMenu.menuItems.element(boundBy: 0).click()

        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 8))
        app.typeText("хочу проверить карточку")
        app.typeKey(.return, modifierFlags: [])
        window = app.windows.firstMatch

        let node = window.staticTexts["хочу проверить карточку"].firstMatch
        XCTAssertTrue(node.waitForExistence(timeout: 5))
        node.doubleClick()
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "двойной клик открывает карточку")
    }

    func testCloseByButton() {
        openCardOnSingleJob()
        closeButton.click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: closeButton)
        waitForExpectations(timeout: 5)
    }

    func testCloseByEscape() {
        openCardOnSingleJob()
        app.typeKey(.escape, modifierFlags: [])
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: closeButton)
        waitForExpectations(timeout: 5)
    }

    func testCloseByClickOutside() {
        openCardOnSingleJob()
        // Пустое место канваса под работой — заведомо мимо карточки.
        let empty = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        empty.click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: closeButton)
        waitForExpectations(timeout: 5)
    }
}
