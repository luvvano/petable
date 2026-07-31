import AgentRuntime
import Foundation
import OrgEngine

// petable-daemon: LaunchAgent-исполнитель конвейера (П0).
// Владеет запусками; приложение — UI-клиент через XPC.
// Хранилище — ~/Library/Application Support/Petable (T3, не ~/Documents).

let store = EventStore(root: EventStore.defaultRoot())

// Схема вердикта — enforced (T5, находка спайка).
let schemaURL = store.root.appendingPathComponent("verdict-schema.json")
let schema = """
{"type":"object","properties":{"status":{"type":"string","enum":["done","changesRequested","cannotComplete"]},"note":{"type":"string"}},"required":["status","note"],"additionalProperties":false}
"""
try? FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
try? schema.write(to: schemaURL, atomically: true, encoding: .utf8)

func makeAdapter(_ name: String) -> (any AgentAdapter)? {
    guard let executable = CLIProcessAdapter.find(name) else { return nil }
    switch name {
    case "claude": return CLIProcessAdapter.claude(executable: executable)
    case "codex": return CLIProcessAdapter.codex(executable: executable, schemaPath: schemaURL.path)
    default: return nil
    }
}

var adapters: [any AgentAdapter] = []
if let claude = makeAdapter("claude") { adapters.append(claude) }
if let codex = makeAdapter("codex") { adapters.append(codex) }

// Fallback: CLI, не найденный на старте, переискивается при промахе —
// launchd мог поднять демона до установки CLI или с урезанным PATH.
let registry = AdapterRegistry(adapters, fallback: { name in
    CLIDiscovery.reset()
    return makeAdapter(name)
})

let core = DaemonCore(store: store, registry: registry)
let delegate = DaemonXPCDelegate(core: core)
let listener = NSXPCListener(machServiceName: petableDaemonMachService)
listener.delegate = delegate
listener.resume()

// Восстановление (П0): поднять запуски прошлой жизни — в том числе
// прерванные drain'ом при обновлении движка. Асинхронно, слушатель
// уже принимает коннекты.
Task { await core.recoverAll() }

let found = adapters.map(\.cliID).joined(separator: ", ")
FileHandle.standardError.write(Data(
    "petable-daemon: слушаю \(petableDaemonMachService) · исполнители: \(found.isEmpty ? "не найдены (переищу при первом этапе)" : found)\n".utf8
))
RunLoop.main.run()
