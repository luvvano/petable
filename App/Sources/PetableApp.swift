import SwiftUI
import GraphCore

@main
struct PetableApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { PetableDocument() }) { configuration in
            CanvasRootView(document: configuration.document)
        }
    }
}
