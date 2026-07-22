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
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let envelope = try Envelope.decode(data)
        guard let first = envelope.jobGraphStages.first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        stages = envelope.stages
        selectedGraphID = first.id
    }

    func snapshot(contentType: UTType) throws -> Envelope {
        Envelope(stages: stages)
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
        guard selectedGraphID != id, graphStages.contains(where: { $0.id == id }) else { return }
        selectedGraphID = id
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
            graph: WorkGraph(levels: [GraphLevel(jobs: [JobNode(verb: "")])])
        )
        applyListChange {
            stages.append(stage)
            selectedGraphID = stage.id
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

    /// Снапшот списка стадий + выбора для undo операций над списком.
    private struct ListState {
        var stages: [Envelope.Stage]
        var selection: UUID?
    }

    /// Меняет список стадий с регистрацией undo. Снапшоты сессий и списка
    /// ложатся в один стек одного undoManager'а хронологически, поэтому
    /// полные копии списка не конфликтуют с пограничными правками графов.
    @MainActor
    private func applyListChange(_ change: () -> Void) {
        let before = ListState(stages: stages, selection: selectedGraphID)
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
        let current = ListState(stages: stages, selection: selectedGraphID)
        registerListUndo(restoring: current)
        stages = state.stages
        selectedGraphID = state.selection
    }
}
