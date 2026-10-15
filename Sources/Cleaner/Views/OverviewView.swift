import CleanCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(SystemMonitor.self) private var monitor
    @Binding var destination: Destination?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DeviceStatusSection()

                diskCard

                if !model.hasFullDiskAccess {
                    FullDiskAccessBanner()
                }

                switch model.phase {
                case .idle:
                    welcome
                case .scanning:
                    scanning
                case .scanned, .cleaning:
                    summary
                }

                ForEach(model.ruleLoadErrors, id: \.self) { error in
                    Label("自定义规则加载失败：\(error)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            if model.phase == .scanned {
                CleanBar(category: nil)
            }
        }
        .navigationTitle("概览")
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private var diskCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("磁盘空间").font(.headline)
                if let disk = model.disk {
                    let percent = Int((Double(disk.used) / Double(max(disk.total, 1)) * 100).rounded())
                    Text("已使用 \(percent)%")
                        .foregroundStyle(percent >= 90 ? .red : .secondary)
                }
                Spacer()
                // 设备状态放在最上面后，主操作要留在首屏
                if model.phase == .idle {
                    Button("扫描可清理的内容") { model.startScan() }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let disk = model.disk {
                DiskUsageBar(disk: disk, selected: model.selectedSize())
            } else {
                Text("无法读取磁盘信息").foregroundStyle(.secondary)
            }
            SwapTip()
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("找出占用空间的内容").font(.title2.weight(.semibold))
            Text("扫描只读取文件信息，不会删除任何东西。清理前你会看到完整清单并逐项确认。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                model.startScan()
            } label: {
                Text("开始扫描").frame(minWidth: 120)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var scanning: some View {
        VStack(spacing: 14) {
            ProgressView(value: model.scanProgress.fraction)
                .progressViewStyle(.linear)
            HStack {
                Text(model.scanProgress.phase)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if model.scanProgress.total > 0 {
                    Text("\(model.scanProgress.completed) / \(model.scanProgress.total)")
                        .monospacedDigit()
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            Button("停止扫描") { model.cancelScan() }
        }
        .padding(.vertical, 40)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("可清理 \(model.totalSize().bytes)")
                        .font(.title.weight(.semibold))
                    if let date = model.lastScanDate {
                        Text("扫描于 \(date.formatted(date: .omitted, time: .shortened))，默认只勾选了安全的项目和不活跃项目的构建产物")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                ForEach(CleanCategory.allCases) { category in
                    CategoryCard(category: category) {
                        destination = .category(category)
                    }
                }
            }
        }
    }
}

struct CategoryCard: View {
    @Environment(AppModel.self) private var model
    let category: CleanCategory
    let open: () -> Void

    var body: some View {
        let total = model.totalSize(in: category)
        let selected = model.selectedSize(in: category)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: category.symbol)
                        .font(.title3)
                        .foregroundStyle(.tint)
                    Text(category.title).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                Text(total > 0 ? total.bytes : "没有发现")
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(total > 0 ? .primary : .secondary)
                Text(selected > 0 ? "已选 \(selected.bytes)" : category.summary)
                    .font(.caption)
                    .foregroundStyle(selected > 0 ? Color.green : Color.secondary)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// 交换文件也占磁盘空间，而且只有重启才会释放
struct SwapTip: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        if let snapshot = monitor.snapshot, snapshot.memory.swapFileSize >= 2 << 30 {
            let days = Int(snapshot.uptime / 86400)
            Label {
                Text("其中交换文件占用了 \(Int64(snapshot.memory.swapFileSize).bytes)：内存不够用时，系统会把数据暂存到磁盘上。\(days >= 7 ? "这台 Mac 已连续运行 \(days) 天，" : "")重启后这部分空间会释放。")
            } icon: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}
