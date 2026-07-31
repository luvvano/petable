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
    /// Раздел «Организация»: ИИ-сотрудники и флоу (v14); nil — не создана.
    @Published private(set) var organization: Organization?
    /// Что открыто в detail вместо канваса; nil — показывается граф.
    @Published private(set) var selectedResearchItem: ResearchSelection?

    enum ResearchSelection: Hashable {
        case interview(UUID)
        case template(UUID)
        case segment(UUID)
        /// Карта сегментов: сравнительная таблица всех сегментов проекта.
        case segmentMap
        /// Конвейер: задачи по статусам, флоу задачи, чат с этапом.
        case organization
        /// Настройки организации: типы задач · сотрудники · конвейер ·
        /// интеграции (правка автора №1/№4 — отделены от конвейера).
        case organizationSettings
        /// Дебаггер запусков (слайс 12): replay по event-log, fork,
        /// сравнение, тени.
        case organizationDebugger
    }

    /// Контроллер конвейера — ОДИН на документ, общий для «Конвейера» и
    /// «Организации»: один транспорт, одна подписка, один оркестратор.
    private var orgControllerStorage: OrganizationController?

    @MainActor
    var organizationController: OrganizationController {
        if let orgControllerStorage { return orgControllerStorage }
        let controller = OrganizationController()
        orgControllerStorage = controller
        return controller
    }

    /// Сессия на каждый граф, к которому прикасались. Живут, пока жив
    /// undoManager окна: undo-события ссылаются на сессию как на target,
    /// выбрасывать её из словаря при живом стеке нельзя.
    private var sessions: [UUID: GraphSession] = [:]
    private var windowUndoManager: UndoManager?

    static var readableContentTypes: [UTType] { [.petableDocument] }

    /// Новый проект = один граф с одной пустой работой на core-уровне,
    /// сразу в режиме редактирования.
    init() {
        let stage = Envelope.Stage(graph: WorkGraph(levels: [GraphLevel(jobs: [JobNode(verb: "")], isCore: true)]))
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
        // Файлы до v14 без организации — организации нет.
        organization = envelope.organization
        // Открывается последний граф по времени изменения;
        // без отметок (старые файлы) — первый.
        selectedGraphID = (graphs.max {
            ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast)
        } ?? graphs[0]).id
    }

    func snapshot(contentType: UTType) throws -> Envelope {
        Envelope(
            stages: stages,
            research: research,
            segmentation: segmentation,
            organization: organization
        )
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
        case .segmentMap, .organization, .organizationSettings, .organizationDebugger:
            break
        }
        selectedResearchItem = item
    }

    // MARK: - Организация

    /// Создаёт дефолтную организацию (линейный флоу «Разработка → Ревью →
    /// Тесты → Merge», слайс 1) и открывает её. Повторный вызов — только
    /// открывает: определение не перетирается.
    @MainActor
    func createOrganizationIfNeeded() {
        if organization == nil {
            organization = Organization.makeDefault()
            registerOrganizationUndo(restoring: nil)
        }
        selectedResearchItem = .organization
    }

    /// Правка определения организации (роли, флоу, задачи борда, реестр).
    /// Регистрирует undo — это же помечает документ изменённым: без
    /// undo-регистрации ReferenceFileDocument не автосейвит, и организация
    /// терялась при перезапуске (правка автора).
    @MainActor
    func updateOrganization(_ transform: (inout Organization) -> Void) {
        guard var org = organization else { return }
        let before = org
        transform(&org)
        guard org != before else { return }
        // Версия флоу (2A): содержательная правка бампает version —
        // бейдж «Запуск идёт по vN · текущий флоу vM» на канвасе.
        for index in org.flows.indices {
            if let old = before.flows.first(where: { $0.id == org.flows[index].id }),
               old.stages != org.flows[index].stages {
                org.flows[index].version = old.version + 1
            }
        }
        organization = org
        registerOrganizationUndo(restoring: before)
    }

    @MainActor
    private func registerOrganizationUndo(restoring state: Organization?) {
        guard let windowUndoManager else { return }
        windowUndoManager.beginUndoGrouping()
        windowUndoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                let current = document.organization
                document.organization = state
                document.registerOrganizationUndo(restoring: current)
            }
        }
        windowUndoManager.endUndoGrouping()
    }

    /// Реконсиляция саммари запусков (П1′): идемпотентно по runID,
    /// вне undo-стека — системная мутация, не правка человека.
    @MainActor
    func reconcileRunSummaries(_ summaries: [RunSummary]) {
        guard var org = organization else { return }
        org.reconcile(summaries: summaries)
        organization = org
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

    /// Новый граф с одной пустой работой на core-уровне; становится выбранным.
    /// `parent` — граф, под которым он ляжет (nil = верхний уровень).
    @MainActor
    @discardableResult
    func addGraph(parent: UUID? = nil) -> UUID {
        // Родителем может быть только существующий граф: иначе новый
        // граф не показался бы в дереве сайдбара.
        let parentID = parent.flatMap { id in
            graphStages.contains(where: { $0.id == id }) ? id : nil
        }
        let stage = Envelope.Stage(
            name: nextGraphName(),
            modifiedAt: Date(),
            parentID: parentID,
            graph: WorkGraph(levels: [GraphLevel(jobs: [JobNode(verb: "")], isCore: true)])
        )
        applyListChange {
            stages.append(stage)
            selectedGraphID = stage.id
            selectedResearchItem = nil
        }
        return stage.id
    }

    /// Перенос графа в другую группу: `parent` = nil — на верхний уровень.
    /// Вложение в себя или в собственный потомок отбрасывается — цикл
    /// спрятал бы всё поддерево из сайдбара.
    @MainActor
    func nestGraph(_ id: UUID, under parent: UUID?) {
        guard stages.canNestGraph(id, under: parent),
              let index = stages.firstIndex(where: { $0.id == id }),
              stages[index].parentID != parent
        else { return }
        applyListChange {
            stages[index].parentID = parent
        }
    }

    /// Потомки графа на любую глубину — уходят вместе с ним при удалении.
    func graphDescendants(of id: UUID) -> [UUID] {
        stages.graphDescendants(of: id)
    }

    /// Удалить можно, пока в проекте останется хотя бы один граф:
    /// группа уходит целиком, поэтому считаем и потомков.
    func canDeleteGraph(_ id: UUID) -> Bool {
        guard graphStages.contains(where: { $0.id == id }) else { return false }
        return graphStages.count > graphDescendants(of: id).count + 1
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

    /// Удаление группы: граф уходит со всеми вложенными — «оставшиеся
    /// без родителя» графы иначе молча всплыли бы наверх. Последний граф
    /// проекта удалить нельзя (⌘Z возвращает группу целиком).
    @MainActor
    func deleteGraph(_ id: UUID) {
        guard canDeleteGraph(id) else { return }
        let doomed = Set([id] + graphDescendants(of: id))
        applyListChange {
            stages.removeAll { doomed.contains($0.id) }
            if let selectedGraphID, doomed.contains(selectedGraphID) {
                self.selectedGraphID = graphStages.first?.id
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

    /// Импорт шаблона из файла или буфера (экспорт другого проекта или
    /// другого человека): id перегенерируются — один файл можно
    /// импортировать многократно; имя разрешается от коллизий.
    /// Открывается в редакторе шаблона.
    @MainActor
    @discardableResult
    func importTemplate(_ template: InterviewTemplate) -> UUID {
        var imported = template.withRegeneratedIDs()
        let base = imported.name.trimmingCharacters(in: .whitespacesAndNewlines)
        imported.name = uniqueName(
            base: base.isEmpty ? "Шаблон" : base,
            existing: Set(research.templates.map(\.name)),
            firstWithoutNumber: true
        )
        let importedID = imported.id
        applyListChange { [imported] in
            research.templates.append(imported)
            selectedResearchItem = .template(importedID)
        }
        return importedID
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

    // MARK: - Механики ценности

    /// Enter в палитре (топология): превью механики становится текущим
    /// графом. Та же пружина и тот же undo-стек, что у обычных интентов —
    /// ⌘Z откатывает одним шагом. Следа не остаётся by design: это
    /// правка, а не запись о ней; кто хочет след — жмёт ⌥Enter.
    @MainActor
    func applyMechanicPreview(_ preview: WorkGraph) {
        guard let selectedGraphID, let session = session(for: selectedGraphID) else { return }
        withAnimation(.spring(duration: 0.35)) {
            session.replace(with: preview)
        }
    }

    /// ⌥Enter в палитре: граф-потомок с применённой механикой. Происхождение
    /// снимается из графа ДО применения (kill-a-job удаляет свой якорь) и
    /// живёт в mechanicOrigin — переименование графа связь не рвёт.
    @MainActor
    @discardableResult
    func forkWithMechanic(
        preview: WorkGraph,
        origin: MechanicOrigin,
        mechanicTitle: String
    ) -> UUID? {
        guard let selectedGraphID,
              let parent = stages.first(where: { $0.id == selectedGraphID })
        else { return nil }
        let stage = Envelope.Stage(
            name: "\(parent.name) · \(mechanicTitle)",
            modifiedAt: Date(),
            parentID: parent.id,
            mechanicOrigin: origin,
            graph: preview
        )
        applyListChange {
            stages.append(stage)
            self.selectedGraphID = stage.id
            selectedResearchItem = nil
        }
        return stage.id
    }

    /// Enter на механике-стикере: аннотация вешается на текущий граф.
    /// Через applyListChange — тот же undo-стек, ⌘Z снимает стикер.
    @MainActor
    func addMechanicSticker(_ sticker: MechanicSticker) {
        guard let selectedGraphID,
              let index = stages.firstIndex(where: { $0.id == selectedGraphID })
        else { return }
        applyListChange {
            stages[index].stickers.append(sticker)
            stages[index].modifiedAt = Date()
        }
    }

    /// Применение механики с записью: трансформация графа (превью или
    /// правка карточки) и стикер-запись ложатся в ОДНУ undo-группу —
    /// ⌘Z откатывает применение целиком, как один шаг. Запись остаётся
    /// в документе всегда: применение механики — событие, его след не
    /// должен исчезать после следующего действия.
    @MainActor
    func applyMechanic(
        record: MechanicSticker,
        preview: WorkGraph? = nil,
        cardDetails: (jobID: UUID, details: JobDetails)? = nil
    ) {
        guard let selectedGraphID,
              stages.contains(where: { $0.id == selectedGraphID })
        else { return }
        windowUndoManager?.beginUndoGrouping()
        if let preview {
            applyMechanicPreview(preview)
        }
        if let cardDetails {
            perform(.setDetails(cardDetails.jobID, details: cardDetails.details))
        }
        addMechanicSticker(record)
        windowUndoManager?.endUndoGrouping()
    }

    /// Реплика в тред стикера-комментария (сайдбар комментариев или
    /// окно конвертика). Тот же undo-стек.
    @MainActor
    func addStickerMessage(_ stickerID: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let selectedGraphID,
              let index = stages.firstIndex(where: { $0.id == selectedGraphID }),
              let stickerIndex = stages[index].stickers.firstIndex(where: { $0.id == stickerID })
        else { return }
        applyListChange {
            stages[index].stickers[stickerIndex].messages.append(StickerMessage(text: trimmed))
            stages[index].modifiedAt = Date()
        }
    }

    /// Стикеры выбранного графа — бейджи на канвасе.
    var stickers: [MechanicSticker] {
        stages.first(where: { $0.id == selectedGraphID })?.stickers ?? []
    }

    @MainActor
    func removeMechanicSticker(_ id: UUID) {
        guard let selectedGraphID,
              let index = stages.firstIndex(where: { $0.id == selectedGraphID }),
              stages[index].stickers.contains(where: { $0.id == id })
        else { return }
        applyListChange {
            stages[index].stickers.removeAll { $0.id == id }
            stages[index].modifiedAt = Date()
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

    /// Команды чат-агента (создать/править граф или интервью).
    /// Возвращает человекочитаемый результат по каждой — для ленты чата.
    @MainActor
    func applyChatActions(_ actions: [AgentChatAction]) -> [String] {
        actions.map { applyChatAction($0) }
    }

    @MainActor
    private func applyChatAction(_ action: AgentChatAction) -> String {
        switch action {
        case .createGraph(let payloadGraph):
            let graph = payloadGraph.makeWorkGraph()
            guard graph.jobCount > 0 else {
                return "⚠️ Граф не создан: агент прислал пустую структуру"
            }
            let stage = Envelope.Stage(
                name: uniqueName(
                    base: payloadGraph.name.isEmpty ? "Граф работ агента" : payloadGraph.name,
                    existing: Set(graphStages.map(\.name)),
                    firstWithoutNumber: true
                ),
                modifiedAt: Date(),
                origin: .agent,
                graph: graph
            )
            applyListChange {
                stages.append(stage)
                selectedGraphID = stage.id
                selectedResearchItem = nil
            }
            return "Создан граф «\(stage.name)»"

        case .updateGraph(let id, let payloadGraph):
            guard let index = stages.firstIndex(where: {
                $0.id == id && $0.type == Envelope.jobGraphStageType
            }) else {
                return "⚠️ Граф не найден (id \(id.uuidString.prefix(8))…)"
            }
            // Перенос карточек/имён уровней: замена структуры не должна
            // стирать наработки на совпадающих узлах.
            let current = sessions[id]?.graph ?? stages[index].graph
            let graph = payloadGraph.makeWorkGraph(preservingFrom: current)
            guard graph.jobCount > 0 else {
                return "⚠️ Граф «\(stages[index].name)» не изменён: пустая структура"
            }
            let newName = payloadGraph.name.trimmingCharacters(in: .whitespacesAndNewlines)
            // Правка идёт через сессию графа, если она уже создана: у неё
            // свой снапшот, мимо неё изменение затёрлось бы следующим интентом.
            if let session = sessions[id] {
                session.replace(with: graph)
            } else {
                applyListChange {
                    stages[index].graph = graph
                    stages[index].modifiedAt = Date()
                }
            }
            if !newName.isEmpty, stages[index].name != newName {
                applyListChange { stages[index].name = newName }
            }
            return "Обновлён граф «\(stages[index].name)»"

        case .createInterview(let templateID, let name, let placeholders, let answers):
            guard let template = research.templates.first(where: { $0.id == templateID }) else {
                return "⚠️ Интервью не создано: шаблон не найден"
            }
            let payload = AgentArtifactsPayload(
                interviewName: name,
                placeholders: placeholders,
                answers: answers,
                graph: .init(name: "", levels: [])
            )
            var interview = payload.makeInterview(template: template)
            interview.name = uniqueName(
                base: interview.name,
                existing: Set(research.interviews.map(\.name)),
                firstWithoutNumber: true
            )
            let interviewID = interview.id
            applyListChange { [interview] in
                research.interviews.append(interview)
                selectedResearchItem = .interview(interviewID)
            }
            return "Создано интервью «\(interview.name)»"

        case .updateJob(let graphID, let level, let index, let card):
            guard let stageIndex = stages.firstIndex(where: {
                $0.id == graphID && $0.type == Envelope.jobGraphStageType
            }) else {
                return "⚠️ Граф не найден (id \(graphID.uuidString.prefix(8))…)"
            }
            let stageName = stages[stageIndex].name
            // У открытого графа актуальное состояние — в сессии.
            let graph = sessions[graphID]?.graph ?? stages[stageIndex].graph
            guard graph.levels.indices.contains(level),
                  graph.levels[level].jobs.indices.contains(index)
            else {
                return "⚠️ В графе «\(stageName)» нет работы \(level).\(index)"
            }
            let job = graph.levels[level].jobs[index]
            let merged = card.merged(into: job.details)
            guard merged != job.details else {
                return "Карточка «\(job.displayText)» уже в этом состоянии"
            }
            if let session = sessions[graphID] {
                session.perform(.setDetails(job.id, details: merged))
            } else {
                applyListChange {
                    stages[stageIndex].graph.levels[level].jobs[index].details = merged
                    stages[stageIndex].modifiedAt = Date()
                }
            }
            return "Обновлена карточка «\(job.displayText)» в графе «\(stageName)»"

        case .updateInterview(let id, let placeholders, let answers):
            guard let index = research.interviews.firstIndex(where: { $0.id == id }) else {
                return "⚠️ Интервью не найдено (id \(id.uuidString.prefix(8))…)"
            }
            let knownFieldIDs = Set(
                research.interviews[index].template.sections.flatMap(\.fields).map(\.id)
            )
            let knownAnswers = answers.filter { knownFieldIDs.contains($0.fieldID) }
            guard !knownAnswers.isEmpty || !placeholders.isEmpty else {
                return "⚠️ Интервью «\(research.interviews[index].name)» не изменено: нет валидных полей"
            }
            applyListChange {
                for answer in knownAnswers {
                    research.interviews[index].setAnswer(answer.answer, for: answer.fieldID)
                }
                for (key, value) in placeholders {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    research.interviews[index].placeholderValues[key] = trimmed.isEmpty ? nil : trimmed
                }
                research.interviews[index].modifiedAt = Date()
            }
            return "Обновлено интервью «\(research.interviews[index].name)»"
        }
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
