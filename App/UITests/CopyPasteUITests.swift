import XCTest

/// Копирование и вставка работ: «Выделить работы ниже» → ⌘C (или пункт
/// контекстного меню) → ⌘V кладёт копию цепочки на те же уровни.
/// НЕ запускать, пока за машиной работает человек — UI-тест перехватывает
/// фокус. Приложение при этом не должно быть запущено: XCUIApplication()
/// цепляется к работающей копии вместе с открытыми в ней документами.
/// Запуск: xcodebuild test -project petable.xcodeproj -scheme petable
///   -only-testing:petableUITests/CopyPasteUITests
final class CopyPasteUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    private var app: XCUIApplication!
    private var window: XCUIElement!

    private let parentText = "хочу скопировать цепочку"
    private let childText = "хочу поехать копией"

    private func nodes(_ text: String) -> XCUIElementQuery {
        window.staticTexts.matching(NSPredicate(format: "label == %@", text))
    }

    /// Документ с цепочкой из двух работ: верхняя и её декомпозиция.
    private func launchWithChain() {
        let path = ProcessInfo.processInfo.environment["PETABLE_UITEST_APP"]
        app = path.map { XCUIApplication(url: URL(fileURLWithPath: $0)) } ?? XCUIApplication()
        app.launch()
        app.activate()
        let fileMenu = app.menuBars.menuBarItems["Файл"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 8))
        fileMenu.click()
        fileMenu.menuItems.element(boundBy: 0).click()

        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 8))
        app.typeText(parentText)
        // Tab — сохранить и сразу декомпозиция уровнем ниже.
        app.typeKey(.tab, modifierFlags: [])
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5))
        app.typeText(childText)
        app.typeKey(.return, modifierFlags: [])

        window = app.windows.firstMatch
        XCTAssertTrue(nodes(parentText).element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertEqual(nodes(parentText).count, 1)
        XCTAssertEqual(nodes(childText).count, 1)
    }

    /// Клик по подписи выделяет работу; ⌘C копирует её с декомпозицией,
    /// ⌘V кладёт копию — на канвасе по две работы каждого вида.
    func testKeyboardCopyPasteDuplicatesChain() {
        launchWithChain()
        nodes(parentText).element(boundBy: 0).click()

        app.typeKey("c", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)

        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: nodes(parentText))
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: nodes(childText))
        waitForExpectations(timeout: 5)
    }

    /// Тот же сценарий мышью: правый клик по работе → «Выделить работы
    /// ниже», ещё раз правый клик → «Копировать…», затем «Вставить».
    func testContextMenuCopyPasteDuplicatesChain() {
        launchWithChain()
        let label = nodes(parentText).element(boundBy: 0)
        // Меню висит на круге работы; подпись — под ним.
        let circle = label.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: -46))

        circle.rightClick()
        let highlight = app.menuItems["Выделить работы ниже"]
        XCTAssertTrue(highlight.waitForExistence(timeout: 3))
        highlight.click()

        circle.rightClick()
        let copyItem = app.menuItems.matching(
            NSPredicate(format: "title BEGINSWITH %@", "Копировать выделенные работы")
        ).firstMatch
        XCTAssertTrue(copyItem.waitForExistence(timeout: 3), "в меню работы должен быть пункт копирования")
        copyItem.click()

        circle.rightClick()
        let pasteItem = app.menuItems["Вставить (⌘V)"]
        XCTAssertTrue(pasteItem.waitForExistence(timeout: 3), "после копирования появляется пункт вставки")
        pasteItem.click()

        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: nodes(parentText))
        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: nodes(childText))
        waitForExpectations(timeout: 5)
    }

    /// Вставка ложится туда, куда смотрит курсор: копия цепочки с верхнего
    /// уровня, вставленная над нижней работой, уходит на её уровень,
    /// а её декомпозиция — на новый уровень ниже.
    func testPasteAnchorsAtCursorLevel() {
        launchWithChain()
        XCTAssertFalse(window.staticTexts["УРОВЕНЬ 3"].exists, "пока уровней два")

        nodes(parentText).element(boundBy: 0).click()
        app.typeKey("c", modifierFlags: .command)
        // Курсор над работой нижнего уровня — верх копии ляжет туда.
        nodes(childText).element(boundBy: 0).hover()
        app.typeKey("v", modifierFlags: .command)

        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: nodes(parentText))
        expectation(
            for: NSPredicate(format: "exists == true"),
            evaluatedWith: window.staticTexts["УРОВЕНЬ 3"]
        )
        waitForExpectations(timeout: 5)
    }

    /// ⌘C по графу в сайдбаре и ⌘V кладут копию графа рядом, на верхний
    /// уровень: вложенной группы не появляется.
    func testGraphCopyPasteStaysTopLevel() {
        launchWithChain()
        let graphRows = window.descendants(matching: .any).matching(identifier: "graphRow")
        let groupToggles = window.descendants(matching: .any).matching(identifier: "graphGroupToggle")
        XCTAssertEqual(graphRows.count, 1, "новый документ — один граф")

        graphRows.element(boundBy: 0).click()
        app.typeKey("c", modifierFlags: .command)
        app.typeKey("v", modifierFlags: .command)

        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: graphRows)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(groupToggles.count, 0, "копия графа не должна становиться вложенной")
    }

    /// Правый клик по пустому месту канваса — «Вставить работы».
    func testPasteFromEmptyCanvasMenu() {
        launchWithChain()
        nodes(parentText).element(boundBy: 0).click()
        app.typeKey("c", modifierFlags: .command)

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)).rightClick()
        let pasteItem = app.menuItems["Вставить работы"]
        XCTAssertTrue(pasteItem.waitForExistence(timeout: 3), "на пустом канвасе должно быть меню вставки")
        pasteItem.click()

        expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: nodes(parentText))
        waitForExpectations(timeout: 5)
    }
}
