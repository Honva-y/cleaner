import CleanCore
import SwiftUI

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension RiskLevel {
    var color: Color {
        switch self {
        case .safe: .green
        case .caution: .orange
        case .manual: .red
        }
    }

    var explanation: String {
        switch self {
        case .safe: "可自动重新生成，放心清理"
        case .caution: "可以恢复或重新下载，但需要花时间"
        case .manual: "个人数据，请逐项确认"
        }
    }
}

struct RiskBadge: View {
    let risk: RiskLevel

    var body: some View {
        Text(risk.title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(risk.color)
            .background(risk.color.opacity(0.15), in: Capsule())
            .help(risk.explanation)
    }
}

/// 磁盘占用条：已用 / 已选可清理 / 可用
struct DiskUsageBar: View {
    let disk: DiskSpace
    var selected: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let width = geo.size.width
                let total = max(Double(disk.total), 1)
                let usedWidth = width * Double(disk.used) / total
                let selectedWidth = min(usedWidth, width * Double(selected) / total)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(usageColor.gradient).frame(width: usedWidth)
                    if selectedWidth > 1 {
                        Rectangle().fill(Color.green.gradient)
                            .frame(width: selectedWidth)
                            .offset(x: usedWidth - selectedWidth)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)

            HStack(spacing: 16) {
                legend(usageColor, "已用 \(disk.used.bytes)")
                if selected > 0 { legend(.green, "已选可清理 \(selected.bytes)") }
                legend(Color.secondary.opacity(0.3), "可用 \(disk.available.bytes)")
                Spacer()
                Text("共 \(disk.total.bytes)").foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private var usageColor: Color {
        let ratio = Double(disk.used) / max(Double(disk.total), 1)
        return ratio > 0.9 ? .red : ratio > 0.75 ? .orange : .accentColor
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}

/// 缺少完全磁盘访问权限时的提示条
struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("需要“完全磁盘访问”权限").font(.headline)
                Text("建议先授权再扫描：否则扫描到微信等 App 的数据时，系统会弹窗询问，扫描会暂停等待；废纸篓、Safari、邮件也无法扫描。授权后请重新打开 Cleaner。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("前往授权") { model.openFullDiskAccessSettings() }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.25)))
    }
}

extension Date {
    var relativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
