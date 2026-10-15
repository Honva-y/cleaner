import AppKit
import CleanCore
import SwiftUI

extension Notification.Name {
    static let debugNavigate = Notification.Name("Cleaner.debug.navigate")
    static let debugShowConfirm = Notification.Name("Cleaner.debug.showConfirm")
    static let debugToggleTopApps = Notification.Name("Cleaner.debug.toggleTopApps")
}

/// 开发用：`Cleaner --snapshot <目录>` 自动扫描，把每个页面渲染成 PNG 后退出。
/// 只会打开确认清单，不会执行清理。
@MainActor
enum DebugSnapshot {
    static let outputDirectory: URL? = {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--snapshot"), index + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[index + 1])
    }()

    static var isActive: Bool { outputDirectory != nil }

    static func run(model: AppModel) async {
        guard let dir = outputDirectory else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        await pause(2.5)
        capture("0-welcome", in: dir)
        NotificationCenter.default.post(name: .debugToggleTopApps, object: nil)
        await pause(1)
        capture("0b-top-apps", in: dir)
        NotificationCenter.default.post(name: .debugToggleTopApps, object: nil)
        await pause(0.5)

        model.startScan()
        await pause(3)
        capture("1-scanning", in: dir)
        while model.phase != .scanned { await pause(0.5) }

        var pages: [(String, Destination)] = [("2-overview", .overview)]
        for (index, category) in CleanCategory.allCases.enumerated() {
            pages.append(("3-\(index)-\(category.rawValue)", .category(category)))
        }
        pages.append(("4-history", .history))
        for (name, destination) in pages {
            NotificationCenter.default.post(name: .debugNavigate, object: destination)
            await pause(1.5)
            capture(name, in: dir)
        }

        NotificationCenter.default.post(name: .debugNavigate, object: Destination.overview)
        await pause(1)
        NotificationCenter.default.post(name: .debugShowConfirm, object: nil)
        await pause(1.5)
        capture("5-confirm", in: dir)
        exit(0)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func capture(_ name: String, in dir: URL) {
        for (index, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let file = dir.appendingPathComponent("\(name)-w\(index).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: file)
        }
    }
}
