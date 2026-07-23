import Foundation

/// Раздел «Сегменты» документа: сегментация по методологии AJTBD.
///
/// Сегмент — группа людей со схожими кóровыми работами, схожими
/// критериями успеха и одинаковым порядком их приоритетов. Корень
/// сегментации — работы и критерии, не демография: демографические
/// признаки допустимы только как каузальные критерии второго порядка.
public struct Segmentation: Codable, Equatable, Sendable {
    public var segments: [Segment]

    public init(segments: [Segment] = []) {
        self.segments = segments
    }
}

/// Сегмент: кóровые работы + критерии успеха + порядок приоритетов
/// (корень), каузальные критерии, квалификационные вопросы и экран
/// отбора — четыре вопроса экономики go/no-go.
public struct Segment: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var modifiedAt: Date?
    /// Кто создал сегмент; nil (старые файлы) = человек.
    public var origin: ArtifactOrigin?
    /// Кóровые работы сегмента с критериями успеха — корень сегментации.
    public var coreJobs: [SegmentCoreJob]
    /// Доминирующий порядок приоритетов критериев (8 канонических).
    public var priority: CriteriaPriority?
    /// Каузальные критерии: свойства человека и ситуации, из которых
    /// следует, как создавать ценность, зарабатывать маржу и создавать
    /// спрос. Симптомы («потратил $1000», «enterprise») — не критерии.
    public var causalCriteria: [SegmentListItem]
    /// Квалификационные вопросы лидам — каузальные критерии,
    /// превращённые в 4–5 вопросов для маршрутизации за 60 секунд.
    public var qualificationQuestions: [SegmentListItem]
    /// Экран отбора: четыре вопроса экономики + жёсткий блокер.
    public var economics: SegmentEconomics
    /// Вердикт по сегменту; nil — ещё не решено.
    public var verdict: SegmentVerdict?
    public var notes: String

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        modifiedAt: Date? = nil,
        origin: ArtifactOrigin? = nil,
        coreJobs: [SegmentCoreJob] = [],
        priority: CriteriaPriority? = nil,
        causalCriteria: [SegmentListItem] = [],
        qualificationQuestions: [SegmentListItem] = [],
        economics: SegmentEconomics = SegmentEconomics(),
        verdict: SegmentVerdict? = nil,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.origin = origin
        self.coreJobs = coreJobs
        self.priority = priority
        self.causalCriteria = causalCriteria
        self.qualificationQuestions = qualificationQuestions
        self.economics = economics
        self.verdict = verdict
        self.notes = notes
    }

    /// Происхождение с учётом старых файлов без поля.
    public var resolvedOrigin: ArtifactOrigin { origin ?? .human }
}

/// Кóровая работа сегмента: глагольная формулировка + критерии успеха
/// в порядке приоритета сегмента (первый — доминирующий). Один глагол —
/// одна работа; тот же результат с другими критериями — другая работа
/// и, как правило, другой сегмент.
public struct SegmentCoreJob: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// «хочу + глагол (+ объект)».
    public var statement: String
    /// Конкретные критерии: у каждого ось (направление) и порог.
    public var successCriteria: [SegmentListItem]

    public init(id: UUID = UUID(), statement: String = "", successCriteria: [SegmentListItem] = []) {
        self.id = id
        self.statement = statement
        self.successCriteria = successCriteria
    }
}

/// Элемент редактируемого списка (критерий, вопрос) — текст с
/// собственным id, чтобы SwiftUI-списки не теряли фокус при правке.
public struct SegmentListItem: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String

    public init(id: UUID = UUID(), text: String = "") {
        self.id = id
        self.text = text
    }
}

/// Восемь канонических порядков приоритетов критериев успеха.
/// Один и тот же результат с разным первым приоритетом — разные сегменты.
public enum CriteriaPriority: String, Codable, CaseIterable, Sendable {
    case speedFirst
    case priceFirst
    case doneForMeFirst
    case noStressFirst
    case reliabilityFirst
    case controlFirst
    case statusFirst
    case privacyFirst

    /// Название для UI.
    public var title: String {
        switch self {
        case .speedFirst: return "Сначала скорость"
        case .priceFirst: return "Сначала цена"
        case .doneForMeFirst: return "Сделайте за меня"
        case .noStressFirst: return "Без стресса"
        case .reliabilityFirst: return "Сначала надёжность"
        case .controlFirst: return "Сначала контроль"
        case .statusFirst: return "Сначала статус"
        case .privacyFirst: return "Сначала приватность"
        }
    }
}

/// Экран отбора сегмента: четыре вопроса, на которые описание сегмента
/// обязано отвечать с доказательствами, плюс жёсткий блокер.
/// Не отвечает — фейковая сегментация.
public struct SegmentEconomics: Codable, Equatable, Sendable {
    /// 1. Можем ли создать добавленную ценность?
    public var addedValue: SegmentEconomicsAnswer
    /// 2. Можем ли зарабатывать целевую юнит-маржу?
    public var targetMargin: SegmentEconomicsAnswer
    /// 3. Можем ли создать или захватить спрос?
    public var demand: SegmentEconomicsAnswer
    /// 4. Достаточно ли сегмент велик для масштабирования?
    public var scale: SegmentEconomicsAnswer
    /// Жёсткий блокер (регуляторика, невозможная технология);
    /// пустая строка — блокера нет.
    public var hardBlocker: String

    public init(
        addedValue: SegmentEconomicsAnswer = SegmentEconomicsAnswer(),
        targetMargin: SegmentEconomicsAnswer = SegmentEconomicsAnswer(),
        demand: SegmentEconomicsAnswer = SegmentEconomicsAnswer(),
        scale: SegmentEconomicsAnswer = SegmentEconomicsAnswer(),
        hardBlocker: String = ""
    ) {
        self.addedValue = addedValue
        self.targetMargin = targetMargin
        self.demand = demand
        self.scale = scale
        self.hardBlocker = hardBlocker
    }
}

/// Ответ на вопрос экономики: оценка + доказательство.
/// Оценка без доказательства — мнение, не ответ.
public struct SegmentEconomicsAnswer: Codable, Equatable, Sendable {
    public var rating: SegmentEconomicsRating?
    public var evidence: String

    public init(rating: SegmentEconomicsRating? = nil, evidence: String = "") {
        self.rating = rating
        self.evidence = evidence
    }
}

public enum SegmentEconomicsRating: String, Codable, CaseIterable, Sendable {
    case strong
    case medium
    case weak

    public var title: String {
        switch self {
        case .strong: return "Сильно"
        case .medium: return "Средне"
        case .weak: return "Слабо"
        }
    }
}

/// Вердикт по сегменту на Карте сегментов.
public enum SegmentVerdict: String, Codable, CaseIterable, Sendable {
    case focus
    case hold
    case notOurs

    public var title: String {
        switch self {
        case .focus: return "В фокус"
        case .hold: return "Подождать"
        case .notOurs: return "Не наш"
        }
    }

    /// Символ для строк списка и Карты сегментов.
    public var badge: String {
        switch self {
        case .focus: return "✅"
        case .hold: return "⚠️"
        case .notOurs: return "❌"
        }
    }
}
