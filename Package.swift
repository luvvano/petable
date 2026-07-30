// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "GraphCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GraphCore", targets: ["GraphCore"]),
        .library(name: "AgentRuntime", targets: ["AgentRuntime"]),
        .library(name: "OrgEngine", targets: ["OrgEngine"]),
    ],
    targets: [
        // Справочник механик ценности — копия канона as-is (CC BY-NC-SA 4.0,
        // Иван Замесин). Не переписывается в Swift: текст обновляется
        // копированием файла, а рассинхрон ловит тест на резолв слагов.
        .target(name: "GraphCore", resources: [.process("Resources")]),
        .testTarget(name: "GraphCoreTests", dependencies: ["GraphCore"]),
        // Запуск CLI-агентов: единственная реализация на всех потребителей
        // (адаптеры демона, CLI-ветка граф-агента, чат) — решение 4A.
        .target(name: "AgentRuntime", dependencies: ["GraphCore"]),
        .testTarget(
            name: "AgentRuntimeTests",
            dependencies: ["AgentRuntime"],
            resources: [.copy("Fixtures")]
        ),
        // Движок организации: машина состояний этапов, event-хранилище
        // запусков (П1′), реконсиляция саммари. Работает и в демоне,
        // и в тестах (FakeAdapter) — от Process не зависит.
        .target(name: "OrgEngine", dependencies: ["GraphCore", "AgentRuntime"]),
        .testTarget(name: "OrgEngineTests", dependencies: ["OrgEngine"]),
        // LaunchAgent-демон (П0): XPC-обвязка вокруг DaemonCore.
        // Устанавливается приложением в ~/Library/Application Support/Petable.
        .executableTarget(name: "petable-daemon", dependencies: ["OrgEngine", "AgentRuntime"]),
    ]
)
