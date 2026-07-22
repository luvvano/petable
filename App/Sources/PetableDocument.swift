import SwiftUI
import UniformTypeIdentifiers
import GraphCore

extension UTType {
    static let petableDocument = UTType(exportedAs: "com.egorproskurin.petable.document")
}

/// Документ приложения. Владелец GraphSession — единственного канала мутаций:
///
///   клавиша/клик → GraphIntent → document.perform(intent)
///                                    ├─ снапшот до правки → UndoManager (окна)
///                                    ├─ GraphEngine.apply (чистая функция)
///                                    └─ @Published root → SwiftUI
///                                         └─ GraphLayout.layout → позиции → рендер
final class PetableDocument: ReferenceFileDocument, ObservableObject {
    typealias Snapshot = Envelope

    @Published private(set) var root: Job
    private var session: GraphSession?

    static var readableContentTypes: [UTType] { [.petableDocument] }

    /// Новый документ = один корневой узел, сразу в режиме редактирования.
    /// Пустого документа не бывает.
    init() {
        root = Job(verb: GraphEngine.rootPlaceholder)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let envelope = try Envelope.decode(data)
        guard let graph = envelope.jobGraph else {
            throw CocoaError(.fileReadCorruptFile)
        }
        root = graph
    }

    func snapshot(contentType: UTType) throws -> Envelope {
        Envelope(graph: root)
    }

    func fileWrapper(snapshot: Envelope, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try snapshot.encoded())
    }

    /// Подключает undoManager окна (environment). Вызывается вьюхой в
    /// onAppear/onChange — известный SwiftUI-момент: undoManager из
    /// environment бывает nil на раннем этапе и меняется при смене фокуса.
    @MainActor
    func attach(_ undoManager: UndoManager?) {
        guard let undoManager else { return }
        if let session, session.undoManager === undoManager { return }
        let newSession = GraphSession(root: root, undoManager: undoManager)
        newSession.onChange = { [weak self] newRoot in
            self?.root = newRoot
        }
        session = newSession
    }

    /// Единственная точка мутаций из UI. Возвращает узел для фокуса.
    @MainActor
    @discardableResult
    func perform(_ intent: GraphIntent) -> UUID? {
        assert(session != nil, "attach(undoManager:) не вызван — undo потеряется")
        guard let session else { return nil }
        var focus: UUID?
        withAnimation(.spring(duration: 0.35)) {
            focus = session.perform(intent)
        }
        return focus
    }
}
