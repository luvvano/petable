import Foundation

/// Чем механика выражается в модели petable.
///
/// Класс определяет механизм, а не важность: у топологической есть превью
/// нового графа, у карточной — превью изменённой `JobDetails`, у стикера
/// показывать нечего, поэтому она вешается аннотацией на якорь.
/// Мёртвых механик нет: каждая из 25 попадает ровно в один класс.
public enum MechanicClass: String, Codable, CaseIterable, Sendable {
    /// Превью нового графа: узлы, рёбра, области. 7 механик.
    case topology
    /// Превью изменённой карточки работы через `.setDetails`. 4 механики.
    case jobCard
    /// Аннотация на якоре плюс заметка. 14 механик.
    case sticker

    public var title: String {
        switch self {
        case .topology: return "Меняет граф"
        case .jobCard: return "Меняет карточку работы"
        case .sticker: return "Заметка на графе"
        }
    }
}

/// Запись словаря: связь стабильного слага с заголовком канона.
///
/// Слаг НЕ выводится из заголовка автоматически. У 5 из 7 топологических
/// заголовков наивный kebab-case не сходится: там скобки, `—`, `/` и
/// кавычки-звёздочки. Плюс слаг попадает в файл документа как ключ
/// происхождения и стикера — он обязан пережить переименование в апстриме
/// канона. Рассинхрон ловит тест на резолв всех 25, а не тихая потеря.
struct MechanicEntry {
    let slug: String
    /// Заголовок канона ДОСЛОВНО — по нему идёт сопоставление с ресурсом.
    let canonTitle: String
    /// Русский заголовок для UI. Тезис и примеры остаются английскими:
    /// перевод канона — производная работа, её пришлось бы поддерживать
    /// при каждом обновлении файла.
    let title: String
    let mechanicClass: MechanicClass
}

extension MechanicCatalog {
    /// Все 25 механик канона в порядке файла.
    static let entries: [MechanicEntry] = [
        .init(
            slug: "kill-a-job",
            canonTitle: "Kill a Job",
            title: "Убить работу",
            mechanicClass: .topology
        ),
        .init(
            slug: "reduce-time-gaps",
            canonTitle: "Reduce time-gaps between Jobs → reach the Big Job faster",
            title: "Сократить паузы между работами",
            mechanicClass: .sticker
        ),
        .init(
            slug: "more-jobs-one-solution",
            canonTitle: "Perform more Jobs with one Solution",
            title: "Выполнять больше работ одним решением",
            mechanicClass: .topology
        ),
        .init(
            slug: "connect-to-higher-big-jobs",
            canonTitle: "Create new connections to higher-level Big Jobs",
            title: "Связать с новыми большими работами",
            mechanicClass: .sticker
        ),
        .init(
            slug: "calibrate-expectations",
            canonTitle: "Adjust the customer's expectations",
            title: "Настроить ожидания клиента",
            mechanicClass: .jobCard
        ),
        .init(
            slug: "ecosystem",
            canonTitle: "Ecosystem — combine products for unique combined value, raise switching cost",
            title: "Экосистема: связать продукты между собой",
            mechanicClass: .sticker
        ),
        .init(
            slug: "lower-the-price",
            canonTitle: "Lower the price",
            title: "Снизить цену",
            mechanicClass: .sticker
        ),
        .init(
            slug: "remove-negative-emotions",
            canonTitle: "Remove negative emotions and bring them to positive ones",
            title: "Убрать негативные эмоции",
            mechanicClass: .jobCard
        ),
        .init(
            slug: "reduce-hand-offs",
            canonTitle: "Reduce role-to-role hand-offs in Critical Chains of Jobs",
            title: "Сократить передачи между ролями",
            mechanicClass: .topology
        ),
        .init(
            slug: "lower-cost-before-value",
            canonTitle: "Lower Job/Solution Cost before the value lands",
            title: "Удешевить путь до первой ценности",
            mechanicClass: .sticker
        ),
        .init(
            slug: "exclusive-value",
            canonTitle: "*\"This value is only available with us\"* — exclusive value",
            title: "Эксклюзивная ценность",
            mechanicClass: .sticker
        ),
        .init(
            slug: "core-job-at-expectations",
            canonTitle: "Perform the Core Job at the level of the segment's expectations",
            title: "Выполнять кóровую работу на уровне ожиданий",
            mechanicClass: .jobCard
        ),
        .init(
            slug: "unserved-job",
            canonTitle: "Start performing a Job that nobody currently performs well",
            title: "Взяться за работу, которую никто не делает хорошо",
            mechanicClass: .sticker
        ),
        .init(
            slug: "fix-problems",
            canonTitle: "Fix the Problems",
            title: "Починить проблемы",
            mechanicClass: .sticker
        ),
        .init(
            slug: "fix-unperformed-jobs-in-chain",
            canonTitle: "Fix unperformed Jobs in the Critical Chain of Jobs (including Jobs outside our Core Jobs)",
            title: "Починить невыполняемые работы цепочки",
            mechanicClass: .topology
        ),
        .init(
            slug: "take-job-off-customer",
            canonTitle: "Take the Job off the customer entirely (done-for-you)",
            title: "Взять работу на себя целиком",
            mechanicClass: .topology
        ),
        .init(
            slug: "next-job-in-chain",
            canonTitle: "Perform the Next Job in the Critical Chain of Jobs (cross-sell into adjacency)",
            title: "Выполнять следующую работу цепочки",
            mechanicClass: .sticker
        ),
        .init(
            slug: "orientation-jobs",
            canonTitle: "Perform Orientation Jobs (including explaining what the Job Graph looks like)",
            title: "Выполнять ориентационные работы",
            mechanicClass: .sticker
        ),
        .init(
            slug: "value-slices-earlier",
            canonTitle: "Break value into slices and deliver parts of it earlier in the Critical Chain of Jobs",
            title: "Нарезать ценность и отдавать раньше",
            mechanicClass: .sticker
        ),
        .init(
            slug: "deeper-needs",
            canonTitle: "Perform Jobs while simultaneously satisfying deeper needs",
            title: "Закрывать глубинные потребности заодно",
            mechanicClass: .sticker
        ),
        .init(
            slug: "raise-success-criteria",
            canonTitle: "Better meet the success criteria of Core Jobs / Big Jobs",
            title: "Лучше попадать в критерии успеха",
            mechanicClass: .jobCard
        ),
        .init(
            slug: "small-jobs-for-emergent-big-jobs",
            canonTitle: "Perform Small Jobs for additional Big Jobs that emerged in the process",
            title: "Выполнять малые работы возникших больших",
            mechanicClass: .sticker
        ),
        .init(
            slug: "bundle",
            canonTitle: "Bundle multiple products / services together",
            title: "Собрать бандл",
            mechanicClass: .sticker
        ),
        .init(
            slug: "kill-cycles",
            canonTitle: "Kill cycles in the Critical Chain of Jobs — including across different people",
            title: "Убить циклы в цепочке",
            mechanicClass: .topology
        ),
        .init(
            slug: "fix-chain-breaks-between-people",
            canonTitle: "Fix Critical Chain of Jobs breaks between different people",
            title: "Починить разрывы цепочки между людьми",
            mechanicClass: .topology
        ),
    ]
}
