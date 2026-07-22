import Foundation

/// Раздел «Исследования» документа: шаблоны интервью + проведённые
/// интервью по методологии AJTBD (Next Move Theory).
///
/// Интервью хранит снапшот шаблона, по которому создано: правка или
/// удаление шаблона не ломает уже заполненные формы.
public struct Research: Codable, Equatable, Sendable {
    public var templates: [InterviewTemplate]
    public var interviews: [Interview]

    public init(templates: [InterviewTemplate] = [], interviews: [Interview] = []) {
        self.templates = templates
        self.interviews = interviews
    }
}

/// Шаблон интервью: секции с вопросами. Текст вопроса может содержать
/// плейсхолдеры вида `{решение}` — при заполнении интервью значения
/// подставляются во все вопросы формы (см. InterviewPlaceholders).
public struct InterviewTemplate: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var sections: [Section]

    public init(id: UUID = UUID(), name: String, sections: [Section] = []) {
        self.id = id
        self.name = name
        self.sections = sections
    }

    public struct Section: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var title: String
        public var fields: [Field]

        public init(id: UUID = UUID(), title: String, fields: [Field] = []) {
            self.id = id
            self.title = title
            self.fields = fields
        }
    }

    public struct Field: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        /// Короткое имя элемента («Критерии успеха»).
        public var title: String
        /// Вопрос респонденту; может содержать `{плейсхолдеры}`.
        public var question: String
        /// Подсказка интервьюеру (курсивом под вопросом).
        public var hint: String?
        /// Ответ на это поле становится значением плейсхолдера с этим
        /// ключом и подставляется в остальные вопросы формы.
        public var fillsPlaceholder: String?

        public init(
            id: UUID = UUID(),
            title: String,
            question: String,
            hint: String? = nil,
            fillsPlaceholder: String? = nil
        ) {
            self.id = id
            self.title = title
            self.question = question
            self.hint = hint
            self.fillsPlaceholder = fillsPlaceholder
        }
    }

    /// Все ключи плейсхолдеров, встречающиеся в вопросах шаблона,
    /// в порядке первого появления.
    public var placeholderKeys: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for section in sections {
            for field in section.fields {
                for key in InterviewPlaceholders.keys(in: field.question) where seen.insert(key).inserted {
                    result.append(key)
                }
            }
        }
        return result
    }
}

/// Проведённое (или идущее) интервью: снапшот шаблона + ответы
/// по полям + значения плейсхолдеров.
public struct Interview: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Снапшот шаблона на момент создания интервью.
    public var template: InterviewTemplate
    public var createdAt: Date
    public var modifiedAt: Date?
    /// Ответы: id поля шаблона → текст.
    public var answers: [UUID: String]
    /// Значения плейсхолдеров: ключ → слова респондента.
    public var placeholderValues: [String: String]
    /// Кто создал интервью; nil (старые файлы) = человек.
    public var origin: ArtifactOrigin?

    public init(
        id: UUID = UUID(),
        name: String,
        template: InterviewTemplate,
        createdAt: Date = Date(),
        modifiedAt: Date? = nil,
        answers: [UUID: String] = [:],
        placeholderValues: [String: String] = [:],
        origin: ArtifactOrigin? = nil
    ) {
        self.id = id
        self.name = name
        self.template = template
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.answers = answers
        self.placeholderValues = placeholderValues
        self.origin = origin
    }

    /// Происхождение с учётом старых файлов без поля.
    public var resolvedOrigin: ArtifactOrigin { origin ?? .human }

    /// Записывает ответ поля; если поле питает плейсхолдер —
    /// обновляет и его значение (распространяется на все вопросы).
    public mutating func setAnswer(_ text: String, for fieldID: UUID) {
        answers[fieldID] = text
        guard let field = template.sections
            .flatMap(\.fields)
            .first(where: { $0.id == fieldID }),
            let key = field.fillsPlaceholder
        else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        placeholderValues[key] = value.isEmpty ? nil : value
    }

    /// Вопрос поля с подставленными значениями плейсхолдеров.
    public func resolvedQuestion(for field: InterviewTemplate.Field) -> String {
        InterviewPlaceholders.substitute(field.question, values: placeholderValues)
    }
}

/// Плейсхолдеры в текстах вопросов: `{ключ}`. Незаполненный ключ
/// остаётся в тексте как `{ключ}` — видно, что подставить.
public enum InterviewPlaceholders {
    /// Ключи в порядке появления, без дублей внутри одного текста.
    public static func keys(in text: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        var current: String?
        for character in text {
            switch character {
            case "{":
                current = ""
            case "}":
                if let key = current?.trimmingCharacters(in: .whitespaces),
                   !key.isEmpty, seen.insert(key).inserted {
                    result.append(key)
                }
                current = nil
            default:
                current?.append(character)
            }
        }
        return result
    }

    public static func substitute(_ text: String, values: [String: String]) -> String {
        var result = text
        for (key, value) in values where !value.isEmpty {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }
}

// MARK: - Дефолтные шаблоны (банк вопросов AJTBD-интервью)

public extension InterviewTemplate {
    static let solutionKey = "решение"
    static let outcomeKey = "ожидаемый результат"
    static let bigJobKey = "результат вышестоящей работы"

    /// Шаблоны нового проекта: разовая и регулярная работа —
    /// банк вопросов из гайда по AJTBD-интервью, время глаголов разное.
    static func defaultTemplates() -> [InterviewTemplate] {
        [oneOffJob(), recurringJob()]
    }

    /// Разовая/редкая работа: якорь — один конкретный прошлый случай,
    /// вопросы в прошедшем времени.
    static func oneOffJob() -> InterviewTemplate {
        InterviewTemplate(name: "AJTBD: разовая работа", sections: [
            Section(title: "Подготовка и контакт", fields: [
                Field(
                    title: "Респондент",
                    question: "Кто респондент: имя, роль, сегмент? Чем он уже платил за результат — деньги, время, усилия?",
                    hint: "Изучаем прошлые траты, не намерения: будущее без прошлой траты — фейковая работа."
                ),
                Field(
                    title: "Решение",
                    question: "Каким решением (продуктом, способом) респондент получал результат?",
                    hint: "Ответ подставится во все вопросы формы вместо {решение}.",
                    fillsPlaceholder: solutionKey
                ),
            ]),
            Section(title: "Карта графа работ", fields: [
                Field(
                    title: "Ожидаемые результаты",
                    question: "Какие результаты вы ожидали от использования {решение}? Что-то ещё?",
                    hint: "Исчерпать список; несколько глаголов в одном ответе — разные работы, разберите на уровни."
                ),
                Field(
                    title: "Вверх: большая работа",
                    question: "Зачем вам {ожидаемый результат}? Чтобы что?",
                    hint: "Подниматься минимум на уровень; повтор ответа — потолок. Ответ подставится вместо {результат вышестоящей работы}.",
                    fillsPlaceholder: bigJobKey
                ),
                Field(
                    title: "Предыдущие работы",
                    question: "Какие задачи по шагам вы делали для {результат вышестоящей работы} до {ожидаемый результат}?"
                ),
                Field(
                    title: "Следующие работы",
                    question: "Какие задачи вы делаете для {результат вышестоящей работы} после {ожидаемый результат}?"
                ),
                Field(
                    title: "Параллельные работы",
                    question: "Какие ещё задачи вы делаете для {результат вышестоящей работы}, кроме {ожидаемый результат}?"
                ),
            ]),
            Section(title: "Работа в деталях: 8 элементов", fields: [
                Field(
                    title: "Ожидаемый результат",
                    question: "Какой результат вы ожидали от {решение}? Какие были цели?",
                    hint: "Глагольная фраза, не существительное. Ответ подставится вместо {ожидаемый результат}.",
                    fillsPlaceholder: outcomeKey
                ),
                Field(
                    title: "Критерии успеха",
                    question: "Думая про {ожидаемый результат}: по каким конкретным критериям вы поняли, что достигли его достаточно хорошо? Как хотелось бы идеально?",
                    hint: "Не принимать абстракции: «быстро» → «за 4 минуты». У критерия есть направление (ось) и уровень (порог)."
                ),
                Field(
                    title: "Активирующее знание",
                    question: "Вы узнали что-то, из-за чего захотели {ожидаемый результат}? Это случилось после какого-то опыта?"
                ),
                Field(
                    title: "Контекст",
                    question: "В какой ситуации вы были, когда решили использовать {решение}, чтобы получить {ожидаемый результат}?",
                    hint: "Контекст — причина критериев, а не фон. «Была пятница» — не контекст, если пятница не меняет критерий."
                ),
                Field(
                    title: "Триггер",
                    question: "Расскажите про момент, когда вы начали что-то делать, чтобы получить {ожидаемый результат} — что вас подтолкнуло?",
                    hint: "Ответ — конкретный момент во времени, не «когда созрел»."
                ),
                Field(
                    title: "Вышестоящая работа",
                    question: "Почему вы хотели {ожидаемый результат}? Почему это было важно для вас?"
                ),
                Field(
                    title: "Положительные эмоции",
                    question: "Как вы хотели себя чувствовать после получения {результат вышестоящей работы}?",
                    hint: "Докопаться до названной эмоции — сначала обычно возвращают факты и метафоры."
                ),
                Field(
                    title: "Отрицательные эмоции",
                    question: "Пока вы не получили {результат вышестоящей работы} — чувствовали ли вы негативные эмоции?",
                    hint: "Нужны эмоции до использования решения, не проблемы во время. Плоское «ничего» — не доказательство: дать пример, добрать безопасности."
                ),
            ]),
            Section(title: "Вес работы", fields: [
                Field(
                    title: "Важность (1–10)",
                    question: "Насколько важно получить {ожидаемый результат}, где 10 — вопрос жизни и смерти или безопасности семьи?",
                    hint: "Если 8–10: «помогите понять, почему так высоко»."
                ),
            ]),
            Section(title: "Выбранное решение", fields: [
                Field(
                    title: "Удовлетворённость (1–10)",
                    question: "Насколько вы довольны тем, как {решение} даёт вам {ожидаемый результат} — 10 идеально, 1 совсем нет?",
                    hint: "Если не 10 — почему?"
                ),
                Field(
                    title: "Ценность",
                    question: "В чём для вас ценность {решение} в контексте {ожидаемый результат}?"
                ),
                Field(
                    title: "Aha Moment",
                    question: "В какой момент вы поняли ценность {решение} — момент «о, это круто»?"
                ),
                Field(
                    title: "Цена и ценность",
                    question: "Сколько вы заплатили за {решение}? По шкале 1–10 — насколько цена соответствует ценности?"
                ),
                Field(
                    title: "Проблемы",
                    question: "Были ли сложности при получении {ожидаемый результат} с {решение}? Было ли, что получить вообще не удалось?",
                    hint: "Проблема — следствие работы: восстановить, какая работа выполнялась, когда она стрельнула."
                ),
                Field(
                    title: "Драйверы выбора",
                    question: "Что мотивировало вас начать пользоваться {решение}?"
                ),
                Field(
                    title: "Страхи",
                    question: "Был ли страх, что {решение} не даст вам {ожидаемый результат} так, как нужно? Какой?",
                    hint: "Страх — предсказание потери; барьер — объективный факт. Расширить на альтернативы: «что плохого могло случиться на этом пути?»"
                ),
                Field(
                    title: "Барьеры",
                    question: "Что-то мешало купить или начать пользоваться {решение}?"
                ),
                Field(
                    title: "Альтернативы",
                    question: "Вы рассматривали другие продукты, чтобы получить {ожидаемый результат}? Расскажите.",
                    hint: "Реальные конкуренты живут на уровне большой работы, не только прямые аналоги."
                ),
            ]),
            Section(title: "Продажа и рефералы", fields: [
                Field(
                    title: "Продажа",
                    question: "Сделайте оффер прямо сейчас. Что ответил респондент? Готов ли сделать шаг — оплата, встреча, подписка?",
                    hint: "Продажа — финальный тест: реальна ли работа, есть ли деньги, ложится ли ценность."
                ),
                Field(
                    title: "Реферал",
                    question: "Кого из коллег или знакомых вы порекомендуете для такого разговора?"
                ),
            ]),
        ])
    }

    /// Регулярная работа: типовой привычный паттерн,
    /// вопросы в настоящем времени + частота.
    static func recurringJob() -> InterviewTemplate {
        // Строится из разового шаблона; id секций и полей — свежие,
        // чтобы шаблоны не делили идентификаторы.
        var template = InterviewTemplate(
            name: "AJTBD: регулярная работа",
            sections: oneOffJob().sections.map { section in
                Section(title: section.title, fields: section.fields.map { field in
                    Field(
                        title: field.title,
                        question: field.question,
                        hint: field.hint,
                        fillsPlaceholder: field.fillsPlaceholder
                    )
                })
            }
        )
        // Точечные замены формулировок на настоящее/привычное время.
        replaceQuestion(
            in: &template, fieldTitle: "Ожидаемые результаты",
            with: "Какие результаты вы обычно ожидаете от использования {решение}? Что-то ещё?"
        )
        replaceQuestion(
            in: &template, fieldTitle: "Ожидаемый результат",
            with: "Какой результат вы обычно получаете от {решение}? Какие у вас цели?"
        )
        replaceQuestion(
            in: &template, fieldTitle: "Критерии успеха",
            with: "Думая про {ожидаемый результат}: по каким конкретным критериям вы понимаете, что достигли его достаточно хорошо? Как хотелось бы идеально?"
        )
        replaceQuestion(
            in: &template, fieldTitle: "Контекст",
            with: "В каких ситуациях вы обычно оказываетесь, когда решаете использовать {решение}, чтобы получить {ожидаемый результат}?"
        )
        replaceQuestion(
            in: &template, fieldTitle: "Триггер",
            with: "Расскажите про момент, когда вы начинаете что-то делать, чтобы получить {ожидаемый результат} — что обычно вас подталкивает?"
        )
        replaceQuestion(
            in: &template, fieldTitle: "Вышестоящая работа",
            with: "Почему вам нужен {ожидаемый результат}? Почему это важно для вас?"
        )
        replaceQuestion(
            in: &template, fieldTitle: "Положительные эмоции",
            with: "Как вы хотите себя чувствовать после получения {результат вышестоящей работы}?"
        )
        replaceQuestion(
            in: &template, fieldTitle: "Отрицательные эмоции",
            with: "Пока вы не получили {результат вышестоящей работы} — чувствуете ли вы негативные эмоции?"
        )
        // Частота — только у регулярной работы, перед важностью.
        if let index = template.sections.firstIndex(where: { $0.title == "Вес работы" }) {
            template.sections[index].fields.insert(
                Field(
                    title: "Частота",
                    question: "Сколько раз в месяц или в год вы используете {решение}, чтобы получить {ожидаемый результат}?"
                ),
                at: 0
            )
        }
        return template
    }

    private static func replaceQuestion(
        in template: inout InterviewTemplate,
        fieldTitle: String,
        with question: String
    ) {
        for sectionIndex in template.sections.indices {
            for fieldIndex in template.sections[sectionIndex].fields.indices
            where template.sections[sectionIndex].fields[fieldIndex].title == fieldTitle {
                template.sections[sectionIndex].fields[fieldIndex].question = question
            }
        }
    }
}
