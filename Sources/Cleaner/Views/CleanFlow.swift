import CleanCore
import SwiftUI

/// 底部操作条：显示已选大小，点击后先弹出确认清单
struct CleanBar: View {
    @Environment(AppModel.self) private var model
    /// nil 表示概览页（统计全部分类）
    let category: CleanCategory?
    @State private var confirming = false

    var body: some View {
        let selectedHere = model.selectedSize(in: category)
        let selectedAll = model.selectedSize()
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("已选 \(selectedAll.bytes)")
                    .font(.headline.monospacedDigit())
                Text(category == nil
                     ? "共 \(model.selectedCount) 项，来自所有分类"
                     : "本分类 \(selectedHere.bytes)，共 \(model.selectedCount) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let category {
                Button("全不选") {
                    model.results(in: category).forEach { model.setSelected($0, false) }
                }
                .disabled(selectedHere == 0)
            }
            Button {
                confirming = true
            } label: {
                Text("清理…").frame(minWidth: 72)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedAll == 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .sheet(isPresented: $confirming) {
            CleanConfirmView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .debugShowConfirm)) { _ in
            if category == nil { confirming = true }
        }
    }
}

/// 清理前的确认清单
struct CleanConfirmView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let tasks = model.pendingTasks()
        let deleting = tasks.filter { $0.action == .delete }
        let trashing = tasks.filter { $0.action == .trash }
        let personal = tasks.filter { $0.rule.risk == .manual }
        let running = tasks.filter { $0.item.note?.contains("正在运行") == true }
        let grouped = Dictionary(grouping: tasks, by: \.rule.id)
        let ruleOrder = model.results.map(\.rule).filter { grouped[$0.id] != nil }

        VStack(alignment: .leading, spacing: 16) {
            Text("确认清理").font(.title2.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                if !deleting.isEmpty {
                    summaryRow("xmark.bin", .accentColor,
                               "直接删除 \(size(deleting).bytes)（\(deleting.count) 项）",
                               "可以自动重新生成的缓存和日志，删除后立即释放空间")
                }
                if !trashing.isEmpty {
                    summaryRow("trash", .secondary,
                               "移到废纸篓 \(size(trashing).bytes)（\(trashing.count) 项）",
                               "可以从废纸篓恢复；清空废纸篓后才会真正释放空间")
                }
                if !personal.isEmpty {
                    summaryRow("exclamationmark.triangle.fill", .red,
                               "包含 \(personal.count) 项个人数据",
                               "如聊天中的视频、图片和文件。删除后在对应 App 里将无法打开")
                }
                if !running.isEmpty {
                    summaryRow("app.badge", .orange,
                               "有 \(running.count) 项属于正在运行的 App",
                               "建议先退出这些 App，否则它们可能报错或马上重新生成缓存")
                }
            }

            List {
                ForEach(ruleOrder) { rule in
                    let items = grouped[rule.id] ?? []
                    Section {
                        ForEach(items, id: \.item.id) { task in
                            HStack {
                                Text(task.item.title).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(task.item.reclaimable.bytes)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            .font(.callout)
                        }
                    } header: {
                        HStack {
                            Text(rule.name)
                            RiskBadge(risk: rule.risk)
                            Spacer()
                            Text(size(items).bytes).monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            HStack {
                Text("每一步都会记录在操作日志里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    dismiss()
                    model.clean()
                } label: {
                    Text("清理 \(size(tasks).bytes)")
                }
                .buttonStyle(.borderedProminent)
                .tint(personal.isEmpty ? .accentColor : .red)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
    }

    private func size(_ tasks: [CleanTask]) -> Int64 {
        tasks.reduce(0) { $0 + $1.item.reclaimable }
    }

    private func summaryRow(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

struct CleaningProgressView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let progress = model.cleanProgress
        VStack(spacing: 16) {
            Text("正在清理…").font(.title3.weight(.semibold))
            ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
            Text(progress.title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(24)
        .frame(width: 420)
        .interactiveDismissDisabled()
    }
}

struct CleanResultView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let report: CleanReport

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(report.failures.isEmpty ? .green : .orange)

            Text(headline).font(.title2.weight(.semibold))

            VStack(spacing: 6) {
                if let measured = report.measuredFreedBytes {
                    Text("磁盘可用空间实际增加了 \(max(measured, 0).bytes)")
                }
                if report.deletedBytes > 0 {
                    Text("直接删除 \(report.deletedBytes.bytes)")
                }
                if report.trashedBytes > 0 {
                    Text("移到废纸篓 \(report.trashedBytes.bytes)，清空废纸篓后才会释放")
                }
                if let measured = report.measuredFreedBytes, measured < report.deletedBytes / 2 {
                    Text("实际释放比估算少，可能是部分文件和其他文件共用磁盘块（APFS 克隆），或系统还在回收空间。")
                        .multilineTextAlignment(.center)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if !report.failures.isEmpty {
                DisclosureGroup("\(report.failures.count) 项没有清理") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(report.failures) { failure in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(PathExpander.abbreviate(failure.path))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text(failure.reason).foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
            }

            HStack {
                if report.trashedBytes > 0 {
                    Button("打开废纸篓") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: PathExpander.home + "/.Trash"))
                    }
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var headline: String {
        let freed = report.measuredFreedBytes.map { max($0, 0) } ?? report.deletedBytes
        if report.cleanedItems == 0 { return "没有清理任何内容" }
        return freed > 0 ? "已释放 \(freed.bytes)" : "已清理 \(report.cleanedItems) 项"
    }
}
