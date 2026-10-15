import SwiftUI

struct CleanerApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()
    @State private var monitor = SystemMonitor()

    var body: some Scene {
        Window("Cleaner", id: "main") {
            ContentView()
                .environment(model)
                .environment(monitor)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("清理") {
                Button("开始扫描") { model.startScan() }
                    .keyboardShortcut("r")
                    .disabled(model.phase == .scanning || model.phase == .cleaning)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 从命令行直接运行可执行文件时也显示 Dock 图标和菜单栏
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
