import XCTest

/// Группировка графов в сайдбаре: контекстное меню «Создать новый внутри»,
/// сворачивание группы, перенос перетаскиванием.
/// НЕ запускать, пока за машиной работает человек — UI-тест перехватывает
/// фокус. Приложение при этом не должно быть запущено: XCUIApplication()
/// цепляется к работающей копии вместе с открытыми в ней документами.
/// Запуск: xcodebuild test -project petable.xcodeproj -scheme petable
///   -only-testing:petableUITests/GraphGroupingUITests
final class GraphGroupingUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Окно документа, с которым работает тест, — свежесозданное,
    /// то есть фронтальное. Запросы идут внутри него: у приложения
    /// могут быть восстановлены окна прошлых сеансов.
    private var window: XCUIElement!

    /// Строки графов сайдбара сверху вниз (имя строки совпадает с именем
    /// секции, поэтому опора — идентификатор).
    private var graphRows: XCUIElementQuery {
        window.descendants(matching: .any).matching(identifier: "graphRow")
    }

    /// Треугольники групп: столько же, сколько графов с вложенными.
    private var groupToggles: XCUIElementQuery {
        window.descendants(matching: .any).matching(identifier: "graphGroupToggle")
    }

    /// Новый документ: единственный граф с пустой работой в редакторе.
    /// Esc закрывает редактор — дальше работаем с сайдбаром.
    @discardableResult
    private func launchWithSingleGraph() -> XCUIApplication {
        // XCUIApplication() цепляется к уже запущенной копии приложения —
        // на машине разработчика это его рабочий документ с реальными
        // данными. Прогон против отдельной сборки (свой bundle id, чтобы
        // не поднять чужой инстанс):
        //   TEST_RUNNER_PETABLE_UITEST_APP=/путь/до/petable.app
        let path = ProcessInfo.processInfo.environment["PETABLE_UITEST_APP"]
        let app = path.map { XCUIApplication(url: URL(fileURLWithPath: $0)) } ?? XCUIApplication()
        app.launch()
        app.activate()
        // При запуске открыт хаб проектов — документ создаём из меню
        // «Файл» (первый пункт), клавиатурный ⌘N до хаба не доходит.
        let fileMenu = app.menuBars.menuBarItems["Файл"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 8))
        fileMenu.click()
        fileMenu.menuItems.element(boundBy: 0).click()
        XCTAssertTrue(
            app.textFields.firstMatch.waitForExistence(timeout: 8),
            "новый документ должен открыться с работой в редакторе"
        )
        app.typeKey(.escape, modifierFlags: [])
        window = app.windows.firstMatch
        XCTAssertTrue(graphRows.element(boundBy: 0).waitForExistence(timeout: 5))
        XCTAssertEqual(graphRows.count, 1, "новый документ — один граф")
        return app
    }

    /// Правый клик по графу → «Создать новый внутри»: граф становится
    /// группой (появляется треугольник), внутри — новый граф.
    func testContextMenuCreatesNestedGraph() {
        let app = launchWithSingleGraph()
        XCTAssertEqual(groupToggles.count, 0, "пока групп нет")

        graphRows.element(boundBy: 0).rightClick()
        let nestItem = app.menuItems["Создать новый внутри"]
        XCTAssertTrue(nestItem.waitForExistence(timeout: 3), "в меню графа должен быть пункт вложения")
        nestItem.click()
        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(graphRows.element(boundBy: 1).waitForExistence(timeout: 3))
        XCTAssertEqual(graphRows.count, 2, "родитель + вложенный")
        XCTAssertEqual(groupToggles.count, 1, "родитель стал группой")

        // Свернуть группу — вложенный граф уходит из списка, родитель нет.
        groupToggles.element(boundBy: 0).click()
        expectation(for: NSPredicate(format: "count == 1"), evaluatedWith: graphRows)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(groupToggles.count, 1, "группа осталась группой — её можно развернуть")
    }

    // Перетаскивание графа на граф (перенос в группу) UI-тестом не
    // воспроизводится: синтетический drag XCUITest не поднимает
    // NSDraggingSession у SwiftUI-строки. Проверяется вручную;
    // клавиатурный путь — контекстное меню «Переместить».
}
