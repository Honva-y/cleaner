import CleanCore
import SwiftUI

struct CategoryView: View {
    @Environment(AppModel.self) private var model
    let category: CleanCategory
    @State private var expanded: Set<String> = []

    var body: some View {
        let results = model.results(in: category)
        Group {
            if model.phase == .idle || model.phase == .scanning {
                ContentUnavailableView {
                    Label(category.title, systemImage: category.symbol)
                } description: {
                    Text(model.phase == .scanning ? "正在扫描…" : "先扫描一次，看看这里有什么可以清理。")
                } actions: {
                    if model.phase == .idle {
                        Button("开始扫描") { model.startScan() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else if results.isEmpty {
                ContentUnavailableView("没有发现可清理的内容", systemImage: "checkmark.seal", description: Text(category.summary))
            } else {
                List {
                    Section {
                        ForEach(results) { result in
                            RuleRow(result: result, isExpanded: binding(for: result.id))
                        }
                    } header: {
                        Text(category.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textCase(nil)
                            .padding(.bottom, 4)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if model.phase == .scanned && !results.isEmpty {
                CleanBar(category: category)
            }
        }
        .onAppear {
            // 截图模式下展开前两条规则，方便检查明细
            if DebugSnapshot.isActive { expanded = Set(results.prefix(2).map(\.id)) }
        }
        .navigationTitle(category.title)
        .navigationSubtitle(model.lastScanDate == nil ? "" : "共 \(model.totalSize(in: category).bytes)")
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(id) },
            set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } }
        )
    }
}

/// 一条规则：用系统的展开三角显示明细
struct RuleRow: View {
    let result: RuleResult
    @Binding var isExpanded: Bool

    var body: some View {
        if result.items.isEmpty {
            RuleHeader(result: result)
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(result.items) { item in
                    ItemRow(item: item, rule: result.rule)
                }
            } label: {
                RuleHeader(result: result)
            }
        }
    }
}

struct RuleHeader: View {
    @Environment(AppModel.self) private var model
    let result: RuleResult

    var body: some View {
        let rule = result.rule
        HStack(alignment: .top, spacing: 10) {
            if rule.action != .reveal && !result.items.isEmpty {
                Toggle(sources: itemBindings, isOn: \.self) { Text("选择全部\(rule.name)") }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .padding(.top, 1)
            } else {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                    .frame(width: 14)
                    .padding(.top, 2)
                    .help("只展示占用，需要在对应 App 里处理")
                    .accessibilityLabel("只展示，需要在对应 App 里处理")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(rule.name).font(.headline)
                    RiskBadge(risk: rule.risk)
                    if rule.effectiveAction(alwaysTrash: model.settings.alwaysTrash) == .trash {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("会移到废纸篓，可以恢复")
                            .accessibilityLabel("会移到废纸篓")
                    }
                }
                Text(rule.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let running = runningNote {
                    StatusNote(running, systemImage: "app.badge", tint: .orange)
                }
                ForEach(result.notes, id: \.self) { note in
                    StatusNote(note, systemImage: "info.circle.fill", tint: .blue)
                }
                if let hint = rule.hint {
                    StatusNote(hint, systemImage: "lightbulb")
                }
                if result.accessDenied {
                    HStack(spacing: 6) {
                        StatusNote("没有权限读取这个位置", systemImage: "lock.fill", tint: .orange)
                        Button("授予完全磁盘访问权限") { model.openFullDiskAccessSettings() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text(rule.action == .reveal ? result.totalSize.bytes : result.reclaimableTotal.bytes)
                    .font(.headline.monospacedDigit())
                if rule.action != .reveal && result.reclaimableTotal < result.totalSize * 9 / 10 {
                    Text("占用 \(result.totalSize.bytes)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("多份文件共用同一份数据（APFS 克隆），删除后实际释放的空间少于占用")
                }
                if !result.items.isEmpty {
                    Text("\(result.items.count) 项")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// 有项目因为 App 正在运行而没有默认勾选时，在规则标题下说明原因
    private var runningNote: String? {
        let running = result.items.filter { $0.note?.contains("正在运行") == true }
        guard !running.isEmpty else { return nil }
        let apps = Set(running.compactMap { $0.note?.components(separatedBy: " 正在运行").first })
        let names = apps.sorted().prefix(3).joined(separator: "、")
        return running.count == result.items.count
            ? "\(names) 正在运行，默认没有勾选，建议退出后再清理"
            : "\(running.count) 项属于正在运行的 App（\(names)），默认没有勾选"
    }

    private var itemBindings: [Binding<Bool>] {
        result.items.map { item in
            Binding(get: { model.isSelected(item) }, set: { model.setSelected(item, $0) })
        }
    }
}

struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: ScanItem
    let rule: Rule

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if rule.action != .reveal {
                Toggle(isOn: Binding(get: { model.isSelected(item) }, set: { model.setSelected(item, $0) })) {
                    Text(item.title)
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .padding(.top, 1)
            } else {
                Spacer().frame(width: 14)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    if let detail = item.detail {
                        Text(detail).lineLimit(1).truncationMode(.head)
                    }
                    if let modified = item.modified {
                        Text("修改于 \(modified.relativeDescription)")
                    }
                    if item.fileCount > 1 {
                        Text("\(item.fileCount) 个文件")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let note = item.note {
                    StatusNote(note, systemImage: "exclamationmark.circle.fill", tint: .orange)
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 1) {
                Text(item.size.bytes)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                if rule.action != .reveal && item.reclaimable < item.size * 9 / 10 {
                    Text("预计释放 \(item.reclaimable.bytes)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            Button {
                model.reveal(item.urls)
            } label: {
                Label("在访达中显示", systemImage: "magnifyingglass")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("在访达中显示")
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("在访达中显示") { model.reveal(item.urls) }
            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.urls.map(\.path).joined(separator: "\n"), forType: .string)
            }
            Divider()
            Button("加入保护清单，以后不再清理") { model.protect(item) }
        }
    }
}
