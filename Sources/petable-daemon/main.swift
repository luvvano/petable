import AgentRuntime
import Foundation
import OrgEngine

// petable-daemon: LaunchAgent-исполнитель конвейера (П0).
// Владеет запусками; приложение — UI-клиент через XPC.
// Хранилище — ~/Library/Application Support/Petable (T3, не ~/Documents).

let store = EventStore(root: EventStore.defaultRoot())

var adapters: [any AgentAdapter] = []
if let claude = CLIProcessAdapter.find("claude") {
    adapters.append(CLIProcessAdapter.claude(executable: claude))
}
if let codex = CLIProcessAdapter.find("codex") {
    // Схема вердикта — enforced (T5, находка спайка).
    let schemaURL = store.root.appendingPathComponent("verdict-schema.json")
    let schema = """
    {"type":"object","properties":{"status":{"type":"string","enum":["done","changesRequested","cannotComplete"]},"note":{"type":"string"}},"required":["status","note"],"additionalProperties":false}
    """
    try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
    try? schema.write(to: schemaURL, atomically: true, encoding: .utf8)
    adapters.append(CLIProcessAdapter.codex(executable: codex, schemaPath: schemaURL.path))
}

let core = DaemonCore(store: store, registry: AdapterRegistry(adapters))
let delegate = DaemonXPCDelegate(core: core)
let listener = NSXPCListener(machServiceName: petableDaemonMachService)
listener.delegate = delegate
listener.resume()

// Восстановление (П0): поднять запуски прошлой жизни — в том числе
// прерванные drain'ом при обновлении движка. Асинхронно, слушатель
// уже принимает коннекты.
Task { await core.recoverAll() }

FileHandle.standardError.write(Data("petable-daemon: слушаю \(petableDaemonMachService)\n".utf8))
RunLoop.main.run()
