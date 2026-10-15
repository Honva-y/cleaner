import CleanCore
import SwiftUI

struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(SystemMonitor.self) private var monitor
    @Binding var destination: Destination?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DeviceStatusSection()

                storageCard

                if !model.hasFullDiskAccess {
                    FullDiskAccessBanner()
                }

                if model.phase == .scanned || model.phase == .cleaning {
                    summary
                }

                ForEach(model.ruleLoadErrors, id: \.self) { error in
                    StatusNote("自定义规则加载失败：\(error)", systemImage: "exclamationmark.triangle.fill", tint: .orange, font: .callout)
                }
            }
            .padding(24)
            .frame(maxWidth: 960, alignment: .leading)
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

    /// 磁盘空间 + 扫描入口和进度：主操作留在首屏，不再单独放一块欢迎区
    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("磁盘空间").font(.headline)
                if let disk = model.disk {
                    let percent = Int((Double(disk.used) / Double(max(disk.total, 1)) * 100).rounded())
                    Text("已使用 \(percent)%")
                        .foregroundStyle(percent >= 90 ? .red : .secondary)
                        .monospacedDigit()
                }
                Spacer()
            }
            if let disk = model.disk {
                DiskUsageBar(disk: disk, selected: model.selectedSize())
            } else {
                Text("无法读取磁盘信息").foregroundStyle(.secondary)
            }
            SwapTip()

            switch model.phase {
            case .idle:
                Divider().padding(.vertical, 4)
                scanPrompt
            case .scanning:
                Divider().padding(.vertical, 4)
                scanning
            case .scanned, .cleaning:
                EmptyView()
            }
        }
        .card()
    }

    private var scanPrompt: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("找出占用空间的内容").font(.headline)
                Text("扫描只读取文件信息，不会删除任何东西。清理前你会看到完整清单并逐项确认。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                model.startScan()
            } label: {
                Text("开始扫描").frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var scanning: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("正在扫描").font(.headline)
                    Spacer()
                    if model.scanProgress.total > 0 {
                        Text("\(model.scanProgress.completed) / \(model.scanProgress.total)")
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: model.scanProgress.fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("扫描进度")
                Text(model.scanProgress.phase)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Button("停止") { model.cancelScan() }
                .controlSize(.large)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("可清理 \(model.totalSize().bytes)")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                if let date = model.lastScanDate {
                    Text("扫描于 \(date.formatted(date: .omitted, time: .shortened)) · 默认只勾选了安全的项目和不活跃项目的构建产物")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: CardStyle.spacing)], spacing: CardStyle.spacing) {
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
    @State private var hovering = false

    var body: some View {
        let total = model.totalSize(in: category)
        let selected = model.selectedSize(in: category)
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: category.symbol)
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 24)
                    Text(category.title).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                Text(total > 0 ? total.bytes : "没有发现")
                    .font(.metricValue)
                    .foregroundStyle(total > 0 ? .primary : .secondary)
                Group {
                    if selected > 0 {
                        StatusNote("已选 \(selected.bytes)", systemImage: "checkmark.circle.fill", tint: .green)
                    } else {
                        Text(category.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .lineLimit(2, reservesSpace: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(padding: 14)
            .overlay(
                RoundedRectangle(cornerRadius: CardStyle.cornerRadius, style: .continuous)
                    .strokeBorder(.separator, lineWidth: hovering ? 1 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: CardStyle.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityHint("查看\(category.title)的明细")
    }
}

/// 交换文件也占磁盘空间，而且只有重启才会释放
struct SwapTip: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        if let snapshot = monitor.snapshot, snapshot.memory.swapFileSize >= 2 << 30 {
            let days = Int(snapshot.uptime / 86400)
            StatusNote(
                "其中交换文件占用了 \(Int64(snapshot.memory.swapFileSize).bytes)：内存不够用时，系统会把数据暂存到磁盘上。\(days >= 7 ? "这台 Mac 已连续运行 \(days) 天，" : "")重启后这部分空间会释放。",
                systemImage: "arrow.triangle.2.circlepath",
                font: .callout
            )
        }
    }
}
