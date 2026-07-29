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
    /// SF Symbol механики: у каждого комментария-записи своё изображение —
    /// бейдж на работе узнаётся без чтения тултипа. Уникальность всех 25
    /// держит тест.
    let symbol: String
    /// Заголовок канона ДОСЛОВНО — по нему идёт сопоставление с ресурсом.
    let canonTitle: String
    /// Русский заголовок для UI. Тезис и примеры остаются английскими:
    /// перевод канона — производная работа, её пришлось бы поддерживать
    /// при каждом обновлении файла.
    let title: String
    /// Русское описание для нижней панели палитры: своя формулировка
    /// сути механики, а не перевод текста канона.
    let summary: String
    let mechanicClass: MechanicClass
}

extension MechanicCatalog {
    /// Все 25 механик канона в порядке файла.
    static let entries: [MechanicEntry] = [
        .init(
            slug: "kill-a-job",
            symbol: "scissors",
            canonTitle: "Kill a Job",
            title: "Убить работу",
            summary: "Сделать так, чтобы работу вообще не нужно было выполнять: она исчезает из цепочки, а её соседи связываются напрямую. AirPods убили «распутать наушники», Face ID убил «ввести пароль».",
            mechanicClass: .topology
        ),
        .init(
            slug: "reduce-time-gaps",
            symbol: "timer",
            canonTitle: "Reduce time-gaps between Jobs → reach the Big Job faster",
            title: "Сократить паузы между работами",
            summary: "Убрать ожидание между шагами цепочки, чтобы клиент добирался до большой работы быстрее: мгновенная выдача вместо «ответим в течение трёх дней».",
            mechanicClass: .sticker
        ),
        .init(
            slug: "more-jobs-one-solution",
            symbol: "square.stack.3d.up.fill",
            canonTitle: "Perform more Jobs with one Solution",
            title: "Выполнять больше работ одним решением",
            summary: "Продукт забирает соседние работы, которые клиент сейчас делает другими инструментами: область «вне продукта» становится кóровой, переключения между решениями исчезают.",
            mechanicClass: .topology
        ),
        .init(
            slug: "connect-to-higher-big-jobs",
            symbol: "arrow.up.forward.circle.fill",
            canonTitle: "Create new connections to higher-level Big Jobs",
            title: "Связать с новыми большими работами",
            summary: "Показать, что продукт двигает и другие большие работы клиента, о которых он не думал в момент покупки: та же тренировка — ещё и «хочу выглядеть уверенно».",
            mechanicClass: .sticker
        ),
        .init(
            slug: "calibrate-expectations",
            symbol: "slider.horizontal.3",
            canonTitle: "Adjust the customer's expectations",
            title: "Настроить ожидания клиента",
            summary: "Явно проговорить, что и когда клиент получит, чтобы обещание совпало с реальностью: завышенное ожидание рождает проблему даже у хорошего продукта.",
            mechanicClass: .jobCard
        ),
        .init(
            slug: "ecosystem",
            symbol: "circle.hexagongrid.fill",
            canonTitle: "Ecosystem — combine products for unique combined value, raise switching cost",
            title: "Экосистема: связать продукты между собой",
            summary: "Несколько продуктов вместе дают ценность, которой нет по отдельности, и уходить из связки становится дорого: iPhone + Watch + AirPods.",
            mechanicClass: .sticker
        ),
        .init(
            slug: "lower-the-price",
            symbol: "tag.fill",
            canonTitle: "Lower the price",
            title: "Снизить цену",
            summary: "Уменьшить денежную цену выполнения работы — самая прямая из шести стоимостей. Работает, когда сегмент ранжирует цену первой, и опасна, когда нет.",
            mechanicClass: .sticker
        ),
        .init(
            slug: "remove-negative-emotions",
            symbol: "face.smiling.inverse",
            canonTitle: "Remove negative emotions and bring them to positive ones",
            title: "Убрать негативные эмоции",
            summary: "Найти страх, тревогу или раздражение в работе и убрать их источник: мозг ценит снятую проблему примерно вдвое дороже добавленной фичи.",
            mechanicClass: .jobCard
        ),
        .init(
            slug: "reduce-hand-offs",
            symbol: "arrow.triangle.merge",
            canonTitle: "Reduce role-to-role hand-offs in Critical Chains of Jobs",
            title: "Сократить передачи между ролями",
            summary: "Две работы разных ролей схлопываются в одну: передача «дизайнер → разработчик» исчезает вместе с потерями на стыке.",
            mechanicClass: .topology
        ),
        .init(
            slug: "lower-cost-before-value",
            symbol: "hare.fill",
            canonTitle: "Lower Job/Solution Cost before the value lands",
            title: "Удешевить путь до первой ценности",
            summary: "Снизить, сколько денег, времени и усилий клиент тратит ДО того, как ценность случилась: бесплатный период, простая регистрация, готовые шаблоны.",
            mechanicClass: .sticker
        ),
        .init(
            slug: "exclusive-value",
            symbol: "crown.fill",
            canonTitle: "*\"This value is only available with us\"* — exclusive value",
            title: "Эксклюзивная ценность",
            summary: "Дать ценность, которую нельзя получить ни у кого другого: уникальный контент, данные или условия, ради которых выбирают именно вас.",
            mechanicClass: .sticker
        ),
        .init(
            slug: "core-job-at-expectations",
            symbol: "target",
            canonTitle: "Perform the Core Job at the level of the segment's expectations",
            title: "Выполнять кóровую работу на уровне ожиданий",
            summary: "Дотянуть кóровую работу до критериев успеха сегмента, прежде чем добавлять что-то ещё: недовыполненная кóровая работа обнуляет остальные механики.",
            mechanicClass: .jobCard
        ),
        .init(
            slug: "unserved-job",
            symbol: "sparkle.magnifyingglass",
            canonTitle: "Start performing a Job that nobody currently performs well",
            title: "Взяться за работу, которую никто не делает хорошо",
            summary: "Найти работу, которую весь рынок выполняет плохо, и выполнить её на уровне критериев сегмента — прямой путь к «наконец-то кто-то это сделал».",
            mechanicClass: .sticker
        ),
        .init(
            slug: "fix-problems",
            symbol: "wrench.and.screwdriver.fill",
            canonTitle: "Fix the Problems",
            title: "Починить проблемы",
            summary: "Проблема — это работа, выполняемая ниже критериев успеха. Починить её в своём продукте или забрать чужую проблему себе и решить лучше.",
            mechanicClass: .sticker
        ),
        .init(
            slug: "fix-unperformed-jobs-in-chain",
            symbol: "link.badge.plus",
            canonTitle: "Fix unperformed Jobs in the Critical Chain of Jobs (including Jobs outside our Core Jobs)",
            title: "Починить невыполняемые работы цепочки",
            summary: "В цепочке есть шаг, который никто не выполняет, — и клиент не доходит до ценности. Вставить недостающую работу в разрыв, даже если она вне кóровых.",
            mechanicClass: .topology
        ),
        .init(
            slug: "take-job-off-customer",
            symbol: "gift.fill",
            canonTitle: "Take the Job off the customer entirely (done-for-you)",
            title: "Взять работу на себя целиком",
            summary: "Продукт выполняет работу за клиента, ему остаётся только одобрить результат: область «клиент делает сам» переезжает внутрь продукта (done-for-you).",
            mechanicClass: .topology
        ),
        .init(
            slug: "next-job-in-chain",
            symbol: "arrow.right.circle.fill",
            canonTitle: "Perform the Next Job in the Critical Chain of Jobs (cross-sell into adjacency)",
            title: "Выполнять следующую работу цепочки",
            summary: "После выполненной работы у клиента сразу возникает следующая — выполнить и её: купил билет → предложить отель (cross-sell в смежность).",
            mechanicClass: .sticker
        ),
        .init(
            slug: "orientation-jobs",
            symbol: "map.fill",
            canonTitle: "Perform Orientation Jobs (including explaining what the Job Graph looks like)",
            title: "Выполнять ориентационные работы",
            summary: "Помочь клиенту разобраться, что вообще делать и в каком порядке: гайды, диагностика, «с чего начать» — ориентация тоже работа, и её можно взять на себя.",
            mechanicClass: .sticker
        ),
        .init(
            slug: "value-slices-earlier",
            symbol: "chart.pie.fill",
            canonTitle: "Break value into slices and deliver parts of it earlier in the Critical Chain of Jobs",
            title: "Нарезать ценность и отдавать раньше",
            summary: "Не копить ценность до конца цепочки, а отдавать кусками по пути: черновик результата на первом шаге удерживает внимание до полного результата.",
            mechanicClass: .sticker
        ),
        .init(
            slug: "deeper-needs",
            symbol: "heart.fill",
            canonTitle: "Perform Jobs while simultaneously satisfying deeper needs",
            title: "Закрывать глубинные потребности заодно",
            summary: "Выполняя работу, заодно закрывать потребность под ней — статус, принадлежность, безопасность: Harley продаёт не мотоцикл, а свободу.",
            mechanicClass: .sticker
        ),
        .init(
            slug: "raise-success-criteria",
            symbol: "chart.line.uptrend.xyaxis",
            canonTitle: "Better meet the success criteria of Core Jobs / Big Jobs",
            title: "Лучше попадать в критерии успеха",
            summary: "Выполнять работу заметно лучше порогов, с которыми клиент пришёл: превышение критериев — это и есть ага-момент.",
            mechanicClass: .jobCard
        ),
        .init(
            slug: "small-jobs-for-emergent-big-jobs",
            symbol: "plus.square.on.square",
            canonTitle: "Perform Small Jobs for additional Big Jobs that emerged in the process",
            title: "Выполнять малые работы возникших больших",
            summary: "По ходу использования у клиента появляются новые большие работы — подхватить их малые работы, пока он не ушёл за ними к другим.",
            mechanicClass: .sticker
        ),
        .init(
            slug: "bundle",
            symbol: "shippingbox.fill",
            canonTitle: "Bundle multiple products / services together",
            title: "Собрать бандл",
            summary: "Собрать несколько продуктов или услуг в один пакет: одна покупка закрывает связку работ дешевле и проще, чем по отдельности.",
            mechanicClass: .sticker
        ),
        .init(
            slug: "kill-cycles",
            symbol: "repeat.circle.fill",
            canonTitle: "Kill cycles in the Critical Chain of Jobs — including across different people",
            title: "Убить циклы в цепочке",
            summary: "Убрать возвраты «переделай ещё раз» из цепочки: обратная связь-петля исчезает, работа идёт вперёд без кругов согласований.",
            mechanicClass: .topology
        ),
        .init(
            slug: "fix-chain-breaks-between-people",
            symbol: "person.line.dotted.person.fill",
            canonTitle: "Fix Critical Chain of Jobs breaks between different people",
            title: "Починить разрывы цепочки между людьми",
            summary: "Цепочка рвётся на стыке двух людей — результат одного не доходит до другого. Вставить недостающую работу-мост в этот разрыв.",
            mechanicClass: .topology
        ),
    ]
}
