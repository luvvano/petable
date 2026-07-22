import SwiftUI
import GraphCore

@main
struct PetableApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { PetableDocument() }) { configuration in
            AppShellView(document: configuration.document)
        }
    }
}

/// Разделы навигационного меню. Пока один — граф работ;
/// enum готов к добавлению стадий (интервью, маркетинг, …).
enum AppSection: String, Hashable, CaseIterable, Identifiable {
    case jobGraph

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jobGraph: return "Граф работ"
        }
    }

    var icon: String {
        switch self {
        case .jobGraph: return "point.3.connected.trianglepath.dotted"
        }
    }
}

/// Оболочка окна документа: сайдбар слева + активный раздел справа.
struct AppShellView: View {
    @ObservedObject var document: PetableDocument
    @State private var section: AppSection? = .jobGraph

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(AppSection.allCases) { item in
                    Label(item.title, systemImage: item.icon)
                        .tag(item)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 280)
        } detail: {
            switch section ?? .jobGraph {
            case .jobGraph:
                CanvasRootView(document: document)
            }
        }
        .navigationTitle("")
    }
}
