import Testing
@testable import GraphCore

@Suite("Грамматика role:")
struct RoleParserTests {
    @Test("3. «бухгалтер: хочу…» → role + verb")
    func basicRole() {
        let parsed = RoleParser.parse("бухгалтер: хочу категоризировать транзакции")
        #expect(parsed.role == "бухгалтер")
        #expect(parsed.verb == "хочу категоризировать транзакции")
    }

    @Test("3. Двоеточие внутри verb — «хочу: срочно…» это не роль? Роль: «хочу»")
    func firstColonOnly() {
        // Префикс «хочу» — сплошные буквы, значит формально роль по грамматике:
        // сплит строго по ПЕРВОМУ двоеточию.
        let parsed = RoleParser.parse("хочу: срочно закрыть месяц")
        #expect(parsed.role == "хочу")
        #expect(parsed.verb == "срочно закрыть месяц")
    }

    @Test("3. URL не становится ролью")
    func urlIsNotRole() {
        let parsed = RoleParser.parse("https://example.com — проверить")
        #expect(parsed.role == nil)
        #expect(parsed.verb == "https://example.com — проверить")
    }

    @Test("3. Время «12:30» не становится ролью")
    func timeIsNotRole() {
        let parsed = RoleParser.parse("12:30 стендап")
        #expect(parsed.role == nil)
        #expect(parsed.verb == "12:30 стендап")
    }

    @Test("3. Комбинированная строка для ре-редактирования")
    func displayText() {
        let job = Job(verb: "хочу сверить отчёты", role: "контролёр")
        #expect(job.displayText == "контролёр: хочу сверить отчёты")
        let reparsed = RoleParser.parse(job.displayText)
        #expect(reparsed.role == "контролёр")
        #expect(reparsed.verb == "хочу сверить отчёты")
    }

    @Test("Голое «роль:» без verb — вся строка остаётся verb'ом")
    func bareRolePrefix() {
        let parsed = RoleParser.parse("бухгалтер:")
        #expect(parsed.role == nil)
        #expect(parsed.verb == "бухгалтер:")
    }
}
