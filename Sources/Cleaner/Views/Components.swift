import CleanCore
import SwiftUI

extension Int64 {
    var bytes: String { ByteFormat.file.string(fromByteCount: self) }
}

enum ByteFormat {
    /// 不用 “Zero KB” 这类文字写法；最小单位 KB，0 显示成 “0 KB” 而不是 “0 bytes”
    static let file: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter
    }()

    static let memory: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
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
            .accessibilityLabel("风险：\(risk.title)，\(risk.explanation)")
    }
}

// MARK: - 卡片和提示

enum CardStyle {
    static let cornerRadius: CGFloat = 10
    static let padding: CGFloat = 16
    static let spacing: CGFloat = 12
}

extension View {
    /// 概览页统一的卡片样式
    func card(padding: CGFloat = CardStyle.padding) -> some View {
        self
            .padding(padding)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: CardStyle.cornerRadius, style: .continuous))
    }
}

extension Font {
    /// 卡片里的主数值
    static let metricValue = Font.system(.title, design: .rounded, weight: .semibold).monospacedDigit()
}

/// 带图标的说明文字：只给图标上色，正文保持次要颜色，避免大段彩色文字
struct StatusNote: View {
    let text: String
    let symbol: String
    var tint: Color = .secondary
    var font: Font = .caption

    init(_ text: String, systemImage: String, tint: Color = .secondary, font: Font = .caption) {
        self.text = text
        self.symbol = systemImage
        self.tint = tint
        self.font = font
    }

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
        .font(font)
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
                    Rectangle().fill(.quaternary)
                    Rectangle().fill(usageColor).frame(width: usedWidth)
                    if selectedWidth > 1 {
                        Rectangle().fill(Color.green)
                            .frame(width: selectedWidth)
                            .offset(x: usedWidth - selectedWidth)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: 12)
            .accessibilityElement()
            .accessibilityLabel("磁盘占用")
            .accessibilityValue("已用 \(disk.used.bytes)，共 \(disk.total.bytes)")

            HStack(spacing: 16) {
                legend(usageColor, "已用", disk.used)
                if selected > 0 { legend(.green, "已选可清理", selected) }
                legend(Color.secondary.opacity(0.3), "可用", disk.available)
                Spacer()
                Text("共 \(disk.total.bytes)").foregroundStyle(.secondary)
            }
            .font(.callout.monospacedDigit())
        }
    }

    private var usageColor: Color {
        let ratio = Double(disk.used) / max(Double(disk.total), 1)
        return ratio > 0.9 ? .red : ratio > 0.75 ? .orange : .accentColor
    }

    private func legend(_ color: Color, _ title: String, _ bytes: Int64) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).foregroundStyle(.secondary)
            Text(bytes.bytes)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 缺少完全磁盘访问权限时的提示条
struct FullDiskAccessBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("需要“完全磁盘访问”权限").font(.headline)
                Text("否则扫描微信等 App 的数据时，系统会弹窗询问，扫描会暂停；废纸篓、Safari、邮件也无法扫描。授权后请重新打开 Cleaner。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button("前往授权") { model.openFullDiskAccessSettings() }
        }
        .card(padding: 14)
        .overlay(
            RoundedRectangle(cornerRadius: CardStyle.cornerRadius, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35))
        )
        .accessibilityElement(children: .contain)
    }
}

extension Date {
    var relativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
