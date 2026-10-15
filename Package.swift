// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cleaner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Cleaner", targets: ["Cleaner"]),
    ],
    targets: [
        // 核心逻辑：规则、扫描、安全校验、执行清理、日志。不依赖 UI。
        .target(name: "CleanCore"),
        // SwiftUI 界面
        .executableTarget(name: "Cleaner", dependencies: ["CleanCore"]),
        .testTarget(name: "CleanCoreTests", dependencies: ["CleanCore"]),
    ],
    swiftLanguageModes: [.v5]
)
