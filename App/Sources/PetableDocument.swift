import SwiftUI
import UniformTypeIdentifiers
import GraphCore

extension UTType {
    static let petableDocument = UTType(exportedAs: "com.egorproskurin.petable.document")
}

/// Документ приложения — проект: несколько именованных графов работ
/// (стадий конверта). Владелец GraphSession'ов — единственного канала
/// мутаций графа:
///
///   клавиша/клик → GraphIntent → document.perform(intent)
///                                    ├─ сессия выбранного графа
///                                    ├─ снапшот до правки → UndoManager (окна)
///                                    ├─ GraphEngine.apply (чистая функция)
///                                    └─ @Published stages → SwiftUI
///                                         └─ GraphLayout.layout → позиции → рендер
///
/// Операции над списком графов (добавить/переименовать/удалить) идут
/// мимо сессий — через снапшот всего списка стадий в тот же UndoManager.
final class PetableDocument: ReferenceFileDocument, ObservableObject {
    typealias Snapshot = Envelope

    @Published private(set) var stages: [Envelope.Stage]
    @Published private(set) var selectedGraphID: UUID?

    /// Раздел «Исследования»: шаблоны интервью + интервью.
    @Published private(set) var research: Research
    /// Раздел «Сегменты»: сегментация AJTBD.
    @Published private(set) var segmentation: Segmentation
    /// Что открыто в detail вместо канваса; nil — показывается граф.
    @Published private(set) var selectedResearchItem: ResearchSelection?

    enum ResearchSelection: Hashable {
        case interview(UUID)
        case template(UUID)
        case segment(UUID)
        /// Карта сегментов: сравнительная таблица всех сегментов проекта.
        case segmentMap
    }

    /// Сессия на каждый граф, к которому прикасались. Живут, пока жив
    /// undoManager окна: undo-события ссылаются на сессию как на target,
    /// выбрасывать её из словаря при живом стеке нельзя.
    private var sessions: [UUID: GraphSession] = [:]
    private var windowUndoManager: UndoManager?

    static var readableContentTypes: [UTType] { [.petableDocument] }

    /// Новый проект = один граф с одной пустой работой,
    /// сразу в режиме редактирования.
    init() {
        let stage = Envelope.Stage(graph: WorkGraph(levels: [GraphLevel(jobs: [JobNode(verb: "")])]))
        stages = [stage]
        selectedGraphID = stage.id
        research = Research(templates: InterviewTemplate.defaultTemplates())
        segmentation = Segmentation()
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let envelope = try Envelope.decode(data)
        let graphs = envelope.jobGraphStages
        guard !graphs.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        stages = envelope.stages
        // Файлы до v4 без исследований получают дефолтные шаблоны.
        research = envelope.research ?? Research(templates: InterviewTemplate.defaultTemplates())
        // Файлы до v6 без сегментов получают пустой список.
        segmentation = envelope.segmentation ?? Segmentation()
        // Открывается последний граф по времени изменения;
        // без отметок (старые файлы) — первый.
        selectedGraphID = (graphs.max {
            ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast)
        } ?? graphs[0]).id
    }

    func snapshot(contentType: UTType) throws -> Envelope {
        Envelope(stages: stages, research: research, segmentation: segmentation)
    }

    func fileWrapper(snapshot: Envelope, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try snapshot.encoded())
    }

    // MARK: - Выбранный граф

    /// Графы работ проекта в порядке файла.
    var graphStages: [Envelope.Stage] {
        stages.filter { $0.type == Envelope.jobGraphStageType }
    }

    /// Граф, который сейчас на канвасе.
    var graph: WorkGraph {
        stages.first(where: { $0.id == selectedGraphID })?.graph ?? WorkGraph()
    }

    @MainActor
    func selectGraph(_ id: UUID) {
        guard graphStages.contains(where: { $0.id == id }) else { return }
        // Клик по графу возвращает канвас, даже если граф тот же.
        if selectedResearchItem != nil { selectedResearchItem = nil }
        guard selectedGraphID != id else { return }
        selectedGraphID = id
    }

    @MainActor
    func selectResearch(_ item: ResearchSelection) {
        switch item {
        case .interview(let id):
            guard research.interviews.contains(where: { $0.id == id }) else { return }
        case .template(let id):
            guard research.templates.contains(where: { $0.id == id }) else { return }
        case .segment(let id):
            guard segmentation.segments.contains(where: { $0.id == id }) else { return }
        case .segmentMap:
            break
        }
        selectedResearchItem = item
    }

    // MARK: - Undo

    /// Подключает undoManager окна (environment). Вызывается вьюхой в
    /// onAppear/onChange — известный SwiftUI-момент: undoManager из
    /// environment бывает nil на раннем этапе и меняется при смене фокуса.
    @MainActor
    func attach(_ undoManager: UndoManager?) {
        guard let undoManager, undoManager !== windowUndoManager else { return }
        windowUndoManager = undoManager
        sessions = [:]
    }

    /// Единственная точка мутаций графа из UI. Возвращает узел для фокуса.
    @MainActor
    @discardableResult
    func perform(_ intent: GraphIntent) -> UUID? {
        assert(windowUndoManager != nil, "attach(undoManager:) не вызван — undo потеряется")
        guard let selectedGraphID, let session = session(for: selectedGraphID) else { return nil }
        var focus: UUID?
        withAnimation(.spring(duration: 0.35)) {
            focus = session.perform(intent)
        }
        return focus
    }

    @MainActor
    private func session(for stageID: UUID) -> GraphSession? {
        if let session = sessions[stageID] { return session }
        guard let windowUndoManager,
              let stage = stages.first(where: { $0.id == stageID })
        else { return nil }
        let session = GraphSession(graph: stage.graph, undoManager: windowUndoManager)
        session.onChange = { [weak self] newGraph in
            guard let self,
                  let index = self.stages.firstIndex(where: { $0.id == stageID })
            else { return }
            self.stages[index].graph = newGraph
            self.stages[index].modifiedAt = Date()
        }
        sessions[stageID] = session
        return session
    }

    // MARK: - Операции над списком графов

    /// Новый граф с одной пустой работой; становится выбранным.
    @MainActor
    @discardableResult
    func addGraph() -> UUID {
        let stage = Envelope.Stage(
            name: nextGraphName(),
            modifiedAt: Date(),
            graph: WorkGraph(levels: [GraphLevel(jobs: [JobNode(verb: "")])])
        )
        applyListChange {
            stages.append(stage)
            selectedGraphID = stage.id
        }
        return stage.id
    }

    /// Импортированный граф (из JSON-файла экспорта): id узлов
    /// перегенерируются — один файл можно импортировать многократно;
    /// имя разрешается от коллизий. Становится выбранным.
    @MainActor
    @discardableResult
    func importGraph(name: String, graph: WorkGraph) -> UUID {
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let stage = Envelope.Stage(
            name: uniqueName(
                base: base.isEmpty ? Envelope.defaultGraphName : base,
                existing: Set(graphStages.map(\.name)),
                firstWithoutNumber: true
            ),
            modifiedAt: Date(),
            graph: graph.withRegeneratedIDs()
        )
        applyListChange {
            stages.append(stage)
            selectedGraphID = stage.id
            selectedResearchItem = nil
        }
        return stage.id
    }

    @MainActor
    func renameGraph(_ id: UUID, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = stages.firstIndex(where: { $0.id == id }),
              stages[index].name != name
        else { return }
        applyListChange {
            stages[index].name = name
        }
    }

    /// Последний граф проекта удалить нельзя.
    @MainActor
    func deleteGraph(_ id: UUID) {
        guard graphStages.count > 1,
              let index = stages.firstIndex(where: { $0.id == id })
        else { return }
        applyListChange {
            stages.remove(at: index)
            if selectedGraphID == id {
                selectedGraphID = graphStages.first?.id
            }
        }
    }

    private func nextGraphName() -> String {
        let existing = Set(graphStages.map(\.name))
        var number = graphStages.count + 1
        var candidate = "\(Envelope.defaultGraphName) \(number)"
        while existing.contains(candidate) {
            number += 1
            candidate = "\(Envelope.defaultGraphName) \(number)"
        }
        return candidate
    }

    /// Снапшот списка стадий, исследований и выбора для undo
    /// структурных операций (вне правок графа через GraphSession).
    private struct ListState {
        var stages: [Envelope.Stage]
        var research: Research
        var segmentation: Segmentation
        var selection: UUID?
        var researchSelection: ResearchSelection?
    }

    /// Меняет список стадий с регистрацией undo. Снапшоты сессий и списка
    /// ложатся в один стек одного undoManager'а хронологически, поэтому
    /// полные копии списка не конфликтуют с пограничными правками графов.
    @MainActor
    private func applyListChange(_ change: () -> Void) {
        let before = ListState(
            stages: stages,
            research: research,
            segmentation: segmentation,
            selection: selectedGraphID,
            researchSelection: selectedResearchItem
        )
        change()
        registerListUndo(restoring: before)
    }

    @MainActor
    private func registerListUndo(restoring state: ListState) {
        guard let windowUndoManager else { return }
        // Менеджер окна настроен сессиями на groupsByEvent = false —
        // группу открываем/закрываем сами.
        windowUndoManager.beginUndoGrouping()
        windowUndoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated { document.restoreList(state) }
        }
        windowUndoManager.endUndoGrouping()
    }

    @MainActor
    private func restoreList(_ state: ListState) {
        let current = ListState(
            stages: stages,
            research: research,
            segmentation: segmentation,
            selection: selectedGraphID,
            researchSelection: selectedResearchItem
        )
        registerListUndo(restoring: current)
        stages = state.stages
        research = state.research
        segmentation = state.segmentation
        selectedGraphID = state.selection
        selectedResearchItem = state.researchSelection
    }

    // MARK: - Исследования: интервью

    /// Новое интервью по шаблону (снапшот шаблона копируется внутрь);
    /// становится выбранным.
    @MainActor
    @discardableResult
    func addInterview(templateID: UUID) -> UUID? {
        guard let template = research.templates.first(where: { $0.id == templateID }) else { return nil }
        let interview = Interview(
            name: nextInterviewName(),
            template: template,
            createdAt: Date()
        )
        applyListChange {
            research.interviews.append(interview)
            selectedResearchItem = .interview(interview.id)
        }
        return interview.id
    }

    @MainActor
    func renameInterview(_ id: UUID, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = research.interviews.firstIndex(where: { $0.id == id }),
              research.interviews[index].name != name
        else { return }
        applyListChange {
            research.interviews[index].name = name
        }
    }

    @MainActor
    func deleteInterview(_ id: UUID) {
        guard let index = research.interviews.firstIndex(where: { $0.id == id }) else { return }
        applyListChange {
            research.interviews.remove(at: index)
            if selectedResearchItem == .interview(id) {
                selectedResearchItem = nil
            }
        }
    }

    /// Ответ на поле формы интервью. Вью коммитит по потере фокуса,
    /// не по символу — одна запись в undo-стеке на правку поля; она же
    /// помечает документ изменённым для автосохранения. Плейсхолдер,
    /// который питает это поле, распространяется на все вопросы.
    @MainActor
    func setInterviewAnswer(_ interviewID: UUID, fieldID: UUID, text: String) {
        guard let index = research.interviews.firstIndex(where: { $0.id == interviewID }),
              research.interviews[index].answers[fieldID] ?? "" != text
        else { return }
        applyListChange {
            research.interviews[index].setAnswer(text, for: fieldID)
            research.interviews[index].modifiedAt = Date()
        }
    }

    /// Ручная правка значения плейсхолдера из панели формы.
    @MainActor
    func setInterviewPlaceholder(_ interviewID: UUID, key: String, value: String) {
        guard let index = research.interviews.firstIndex(where: { $0.id == interviewID }) else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard research.interviews[index].placeholderValues[key] ?? "" != trimmed else { return }
        applyListChange {
            research.interviews[index].placeholderValues[key] = trimmed.isEmpty ? nil : trimmed
            research.interviews[index].modifiedAt = Date()
        }
    }

    // MARK: - Исследования: шаблоны

    /// Новый пустой шаблон с одной секцией и одним вопросом; открывается
    /// в редакторе шаблона.
    @MainActor
    @discardableResult
    func addTemplate() -> UUID {
        let template = InterviewTemplate(
            name: nextTemplateName(),
            sections: [
                InterviewTemplate.Section(title: "Секция 1", fields: [
                    InterviewTemplate.Field(title: "Вопрос", question: "")
                ])
            ]
        )
        applyListChange {
            research.templates.append(template)
            selectedResearchItem = .template(template.id)
        }
        return template.id
    }

    /// Полная замена шаблона (редактор отдаёт целиком). Интервью,
    /// созданные раньше, не трогаются — у них свой снапшот.
    @MainActor
    func updateTemplate(_ template: InterviewTemplate) {
        guard let index = research.templates.firstIndex(where: { $0.id == template.id }),
              research.templates[index] != template
        else { return }
        applyListChange {
            research.templates[index] = template
        }
    }

    @MainActor
    func deleteTemplate(_ id: UUID) {
        guard let index = research.templates.firstIndex(where: { $0.id == id }) else { return }
        applyListChange {
            research.templates.remove(at: index)
            if selectedResearchItem == .template(id) {
                selectedResearchItem = nil
            }
        }
    }

    // MARK: - Сегменты

    /// Новый пустой сегмент с одной кóровой работой; открывается в редакторе.
    @MainActor
    @discardableResult
    func addSegment() -> UUID {
        let segment = Segment(
            name: nextSegmentName(),
            coreJobs: [SegmentCoreJob()]
        )
        applyListChange {
            segmentation.segments.append(segment)
            selectedResearchItem = .segment(segment.id)
        }
        return segment.id
    }

    @MainActor
    func renameSegment(_ id: UUID, to rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = segmentation.segments.firstIndex(where: { $0.id == id }),
              segmentation.segments[index].name != name
        else { return }
        applyListChange {
            segmentation.segments[index].name = name
        }
    }

    /// Полная замена сегмента (редактор отдаёт целиком) —
    /// тот же паттерн, что updateTemplate.
    @MainActor
    func updateSegment(_ segment: Segment) {
        guard let index = segmentation.segments.firstIndex(where: { $0.id == segment.id }),
              segmentation.segments[index] != segment
        else { return }
        applyListChange {
            var updated = segment
            updated.modifiedAt = Date()
            segmentation.segments[index] = updated
        }
    }

    @MainActor
    func deleteSegment(_ id: UUID) {
        guard let index = segmentation.segments.firstIndex(where: { $0.id == id }) else { return }
        applyListChange {
            segmentation.segments.remove(at: index)
            if selectedResearchItem == .segment(id) {
                selectedResearchItem = nil
            }
        }
    }

    private func nextSegmentName() -> String {
        uniqueName(base: "Сегмент", existing: Set(segmentation.segments.map(\.name)))
    }

    // MARK: - Артефакты ИИ-агента

    /// Результат исследования агента: интервью + граф работ, оба
    /// помечены origin == .agent. Открывается созданное интервью.
    @MainActor
    @discardableResult
    func addAgentResearch(payload: AgentArtifactsPayload, template: InterviewTemplate) -> UUID {
        var interview = payload.makeInterview(template: template)
        interview.name = uniqueName(
            base: interview.name,
            existing: Set(research.interviews.map(\.name)),
            firstWithoutNumber: true
        )
        let graph = payload.makeWorkGraph()
        let stage = Envelope.Stage(
            name: uniqueName(
                base: payload.graph.name.isEmpty ? "Граф работ агента" : payload.graph.name,
                existing: Set(graphStages.map(\.name)),
                firstWithoutNumber: true
            ),
            modifiedAt: Date(),
            origin: .agent,
            graph: graph
        )
        let interviewID = interview.id
        applyListChange { [interview] in
            stages.append(stage)
            research.interviews.append(interview)
            selectedGraphID = stage.id
            selectedResearchItem = .interview(interviewID)
        }
        return interviewID
    }

    private func nextInterviewName() -> String {
        uniqueName(base: "Интервью", existing: Set(research.interviews.map(\.name)))
    }

    private func nextTemplateName() -> String {
        uniqueName(base: "Шаблон", existing: Set(research.templates.map(\.name)))
    }

    /// Имя без коллизий. firstWithoutNumber: сначала пробуется само base
    /// (для имён от агента); иначе сразу «base N».
    private func uniqueName(
        base: String,
        existing: Set<String>,
        firstWithoutNumber: Bool = false
    ) -> String {
        if firstWithoutNumber, !existing.contains(base) { return base }
        var number = firstWithoutNumber ? 2 : existing.count + 1
        var candidate = "\(base) \(number)"
        while existing.contains(candidate) {
            number += 1
            candidate = "\(base) \(number)"
        }
        return candidate
    }
}
