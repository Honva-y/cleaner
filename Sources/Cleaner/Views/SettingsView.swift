import CleanCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
            PathListSettings(
                title: "项目目录",
                explanation: "在这些目录里查找 node_modules、build、target 等构建产物（最多向下 6 层）。",
                paths: Binding(get: { model.settings.projectRoots }, set: { model.settings.projectRoots = $0 }),
                allowFiles: false
            )
            .tabItem { Label("项目目录", systemImage: "folder") }
            PathListSettings(
                title: "保护清单",
                explanation: "这些文件和文件夹（包括里面的内容）永远不会被清理。也可以在清理列表里右键某一项加入。",
                paths: Binding(get: { model.settings.protectedPaths }, set: { model.settings.protectedPaths = $0 }),
                allowFiles: true
            )
            .tabItem { Label("保护清单", systemImage: "lock.shield") }
        }
        .frame(width: 560, height: 420)
    }
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("删除方式") {
                Toggle("所有内容都先移到废纸篓", isOn: $settings.alwaysTrash)
                Text("默认情况下，可重新生成的缓存会直接删除，其余内容移到废纸篓。打开后全部移到废纸篓，更安全，但要清空废纸篓才会释放空间。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("项目构建产物") {
                Stepper("项目 \(settings.activeProjectDays) 天内有改动算活跃，不默认勾选",
                        value: $settings.activeProjectDays, in: 1...365, step: 7)
            }
            Section("权限") {
                HStack {
                    Label(model.hasFullDiskAccess ? "已获得完全磁盘访问权限" : "没有完全磁盘访问权限",
                          systemImage: model.hasFullDiskAccess ? "checkmark.shield" : "exclamationmark.shield")
                        .foregroundStyle(model.hasFullDiskAccess ? .green : .orange)
                    Spacer()
                    Button("打开系统设置") { model.openFullDiskAccessSettings() }
                }
                Text("扫描废纸篓、Safari、邮件等受保护的位置需要此权限。授权后请重新打开 Cleaner。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("自定义规则") {
                HStack {
                    Text(PathExpander.abbreviate(RuleStore.userRulesDirectory.path))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Spacer()
                    Button("在访达中打开") {
                        try? FileManager.default.createDirectory(at: RuleStore.userRulesDirectory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(RuleStore.userRulesDirectory)
                    }
                }
                Text("在这个目录放 JSON 规则文件，可以添加自己的清理项，格式见项目 README。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PathListSettings: View {
    let title: String
    let explanation: String
    @Binding var paths: [String]
    let allowFiles: Bool
    @State private var selection: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
            List(paths, id: \.self, selection: $selection) { path in
                HStack {
                    Image(systemName: "folder")
                    Text(PathExpander.abbreviate(PathExpander.expandTokens(path)))
                    Spacer()
                    if !FileManager.default.fileExists(atPath: PathExpander.expandTokens(path)) {
                        Text("不存在").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.bordered)
            HStack {
                Button("添加…", systemImage: "plus") { add() }
                Button("移除", systemImage: "minus") {
                    paths.removeAll { selection.contains($0) }
                    selection.removeAll()
                }
                .disabled(selection.isEmpty)
            }
        }
        .padding(20)
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = allowFiles
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: PathExpander.home)
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = PathExpander.abbreviate(url.path)
            if !paths.contains(path) { paths.append(path) }
        }
    }
}
