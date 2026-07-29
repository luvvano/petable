// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "GraphCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GraphCore", targets: ["GraphCore"])
    ],
    targets: [
        // Справочник механик ценности — копия канона as-is (CC BY-NC-SA 4.0,
        // Иван Замесин). Не переписывается в Swift: текст обновляется
        // копированием файла, а рассинхрон ловит тест на резолв слагов.
        .target(name: "GraphCore", resources: [.process("Resources")]),
        .testTarget(name: "GraphCoreTests", dependencies: ["GraphCore"]),
    ]
)
