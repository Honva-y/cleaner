import AppKit
import Charts
import CleanCore
import SwiftUI

/// 概览页顶部的设备状态：机型信息 + CPU / 内存 / 网络 / 电池卡片
struct DeviceStatusSection: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("设备状态").font(.headline)
                Text(machineSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(machineSummary)
                Spacer(minLength: 8)
                if let snapshot = monitor.snapshot {
                    Text("已运行 \(formatUptime(snapshot.uptime))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    if snapshot.thermalState != .nominal {
                        Label(snapshot.thermalState.title, systemImage: "thermometer.high")
                            .font(.callout)
                            .foregroundStyle(snapshot.thermalState.color)
                            .fixedSize()
                    }
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: CardStyle.spacing)], spacing: CardStyle.spacing) {
                CPUCard()
                MemoryCard()
                NetworkCard()
                if monitor.snapshot?.battery != nil {
                    BatteryCard()
                } else {
                    SystemCard()
                }
            }

            if let tip = memoryTip {
                StatusNote(tip, systemImage: "exclamationmark.triangle.fill", tint: .orange, font: .callout)
            }
        }
    }

    private var machineSummary: String {
        let m = monitor.machine
        var cores = "\(m.totalCores) 核"
        if m.performanceCores > 0 && m.efficiencyCores > 0 {
            cores += "（\(m.performanceCores) 性能 + \(m.efficiencyCores) 能效）"
        }
        return [m.productName, m.chip, cores, "\(m.memory.memoryBytes) 内存", m.osVersion]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// 内存压力高时，指出占用最多的 App
    private var memoryTip: String? {
        guard let snapshot = monitor.snapshot, snapshot.memory.pressure != .normal,
              let top = snapshot.apps.first
        else { return nil }
        return "内存压力\(snapshot.memory.pressure.title)：\(top.name) 占用了 \(top.memory.memoryBytes)，关闭不用的标签页或 App 可以让 Mac 更流畅。"
    }
}

// MARK: - 卡片

struct MetricCard<Accessory: View, Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                accessory
            }
            content
        }
        .frame(maxWidth: .infinity, minHeight: 144, alignment: .topLeading)
        .card(padding: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension MetricCard where Accessory == EmptyView {
    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, accessory: { EmptyView() }, content: content)
    }
}

struct CPUCard: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let cpu = monitor.snapshot?.cpu
        MetricCard(title: "CPU", symbol: "cpu") {
            TopAppsButton(sort: .cpu)
        } content: {
            Text(cpu.map { $0.total.percent } ?? "—")
                .font(.metricValue)
                .foregroundStyle(levelColor(cpu?.total ?? 0))
            Sparkline(values: monitor.cpuHistory, maximum: 1, color: .blue)
                .frame(height: 30)
            Group {
                if let cpu, let snapshot = monitor.snapshot {
                    Text("用户 \(cpu.user.percent) · 系统 \(cpu.system.percent) · 负载 \(String(format: "%.1f", snapshot.loadAverage))")
                } else {
                    Text("正在采样…")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    private func levelColor(_ value: Double) -> Color {
        value > 0.9 ? .red : value > 0.7 ? .orange : .primary
    }
}

struct MemoryCard: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let memory = monitor.snapshot?.memory
        MetricCard(title: "内存", symbol: "memorychip") {
            TopAppsButton(sort: .memory)
        } content: {
            if let memory {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(memory.used.memoryBytes)
                        .font(.metricValue)
                    Text("/ \(memory.total.memoryBytes)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                MemoryBar(memory: memory)
                    .frame(height: 8)
                    .padding(.vertical, 4)
                HStack(alignment: .top, spacing: 12) {
                    legend(.blue, "App", memory.app)
                    legend(.orange, "联动", memory.wired)
                    legend(.purple, "压缩", memory.compressed)
                }
                Text("压力\(memory.pressure.title) · 交换 \(memory.swapUsed.memoryBytes)")
                    .font(.caption)
                    .foregroundStyle(memory.pressure.color)
                    .lineLimit(1)
            } else {
                Text("—").font(.metricValue)
            }
        }
    }

    /// 卡片较窄，标签和数值分两行显示
    private func legend(_ color: Color, _ title: String, _ bytes: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(title)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text(bytes.compactGB)
                .font(.caption.monospacedDigit())
        }
        .lineLimit(1)
    }
}

/// App / 联动 / 压缩 堆叠条
struct MemoryBar: View {
    let memory: MemoryUsage

    var body: some View {
        GeometryReader { geo in
            let total = max(Double(memory.total), 1)
            HStack(spacing: 1) {
                segment(.blue, memory.app, total, geo.size.width)
                segment(.orange, memory.wired, total, geo.size.width)
                segment(.purple, memory.compressed, total, geo.size.width)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary)
            .clipShape(Capsule())
        }
        .help("App \(memory.app.memoryBytes) · 联动 \(memory.wired.memoryBytes) · 压缩 \(memory.compressed.memoryBytes) · 缓存文件 \(memory.cached.memoryBytes)")
    }

    private func segment(_ color: Color, _ bytes: UInt64, _ total: Double, _ width: CGFloat) -> some View {
        Rectangle()
            .fill(color)
            .frame(width: max(0, width * Double(bytes) / total - 1))
    }
}

struct NetworkCard: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        let network = monitor.snapshot?.network
        MetricCard(title: "网络", symbol: "network") {
            VStack(alignment: .leading, spacing: 2) {
                rateRow("arrow.down", network?.download, .green)
                rateRow("arrow.up", network?.upload, .blue)
            }
            Sparkline(values: monitor.downloadHistory, maximum: max(monitor.downloadHistory.max() ?? 0, 100_000), color: .green)
                .frame(height: 30)
            Text("最近 2 分钟的下载速度")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rateRow(_ symbol: String, _ value: Double?, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(color)
            Text(value.map { "\(Int64($0).bytes)/s" } ?? "—")
                .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
        }
    }
}

struct BatteryCard: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        if let battery = monitor.snapshot?.battery {
            MetricCard(title: "电池", symbol: symbol(battery)) {
                if let temperature = battery.temperature {
                    Text(String(format: "%.0f°C", temperature))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("电池温度")
                }
            } content: {
                Text("\(battery.percent)%")
                    .font(.metricValue)
                    .foregroundStyle(battery.percent <= 20 && !battery.onACPower ? .red : .primary)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule().fill(barColor(battery))
                            .frame(width: geo.size.width * Double(battery.percent) / 100)
                    }
                }
                .frame(height: 8)
                .padding(.vertical, 4)
                Text(status(battery))
                    .font(.caption)
                    .lineLimit(1)
                Text(details(battery))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func symbol(_ battery: BatteryInfo) -> String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.percent {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private func barColor(_ battery: BatteryInfo) -> Color {
        if battery.isCharging || battery.isCharged { return .green }
        return battery.percent <= 20 ? .red : .green
    }

    private func status(_ battery: BatteryInfo) -> String {
        if battery.isCharging {
            return battery.minutesRemaining.map { "充电中 · 约 \(formatMinutes($0))充满" } ?? "充电中"
        }
        if battery.onACPower {
            return battery.isCharged ? "已充满 · 正在使用电源" : "已接电源，暂未充电"
        }
        return battery.minutesRemaining.map { "使用电池 · 约剩 \(formatMinutes($0))" } ?? "使用电池 · 正在估算剩余时间"
    }

    private func details(_ battery: BatteryInfo) -> String {
        var parts: [String] = []
        if let health = battery.health { parts.append("健康度约 \(Int((health * 100).rounded()))%") }
        if let cycles = battery.cycleCount { parts.append("循环 \(cycles) 次") }
        return parts.joined(separator: " · ")
    }
}

/// 没有电池的 Mac（台式机）显示系统信息
struct SystemCard: View {
    @Environment(SystemMonitor.self) private var monitor

    var body: some View {
        MetricCard(title: "系统", symbol: "desktopcomputer") {
            if let snapshot = monitor.snapshot {
                Text(formatUptime(snapshot.uptime))
                    .font(.metricValue)
                Text("自上次开机")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("温度状态：\(snapshot.thermalState.title)", systemImage: "thermometer.medium")
                    .font(.caption)
                    .foregroundStyle(snapshot.thermalState.color)
            }
        }
    }
}

// MARK: - 占用排行

enum AppSort: Hashable {
    case memory, cpu
}

struct TopAppsButton: View {
    let sort: AppSort
    @State private var showing = false

    var body: some View {
        Button("占用排行") { showing = true }
            .buttonStyle(.link)
            .font(.caption)
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                TopAppsView(sort: sort)
            }
            .onReceive(NotificationCenter.default.publisher(for: .debugToggleTopApps)) { _ in
                if sort == .memory { showing.toggle() }
            }
    }
}

struct TopAppsView: View {
    @Environment(SystemMonitor.self) private var monitor
    @State var sort: AppSort

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("排序", selection: $sort) {
                Text("按内存").tag(AppSort.memory)
                Text("按 CPU").tag(AppSort.cpu)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if apps.isEmpty {
                Text("正在采样…").foregroundStyle(.secondary)
            }
            ForEach(apps) { app in
                HStack(spacing: 10) {
                    AppIconView(bundlePath: app.bundlePath)
                        .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name).lineLimit(1).truncationMode(.middle)
                        if app.processCount > 1 {
                            Text("\(app.processCount) 个进程")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(sort == .memory ? app.memory.memoryBytes : app.cpu.percent)
                            .monospacedDigit()
                        Text(sort == .memory ? "CPU \(app.cpu.percent)" : app.memory.memoryBytes)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            HStack {
                Text("只统计当前用户的进程；CPU 100% 表示占满一个核心")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("活动监视器") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private var apps: [AppUsage] {
        let all = monitor.snapshot?.apps ?? []
        let sorted = sort == .memory ? all : all.sorted { $0.cpu > $1.cpu }
        return Array(sorted.prefix(8))
    }
}

struct AppIconView: View {
    let bundlePath: String?

    var body: some View {
        if let bundlePath {
            Image(nsImage: AppIconCache.icon(for: bundlePath))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "gearshape.2")
                .resizable()
                .scaledToFit()
                .padding(3)
                .foregroundStyle(.secondary)
        }
    }
}

@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

// MARK: - 迷你折线图

struct Sparkline: View {
    let values: [Double]
    let maximum: Double
    let color: Color

    var body: some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                AreaMark(
                    x: .value("时间", index),
                    y: .value("值", min(value, maximum))
                )
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
                LineMark(
                    x: .value("时间", index),
                    y: .value("值", min(value, maximum))
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: 0...max(values.count - 1, 1))
        .chartYScale(domain: 0...max(maximum, 0.0001))
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }
}

// MARK: - 格式化

extension UInt64 {
    /// 内存用 1024 进制（和活动监视器一致）
    var memoryBytes: String { ByteFormat.memory.string(fromByteCount: Int64(self)) }
}

extension UInt64 {
    /// 卡片里空间有限：5.4G
    var compactGB: String { String(format: "%.1fG", Double(self) / 1_073_741_824) }
}

extension Double {
    var percent: String { "\(Int((self * 100).rounded()))%" }
}

extension MemoryPressure {
    var color: Color {
        switch self {
        case .normal: .secondary
        case .warning: .orange
        case .critical: .red
        }
    }
}

extension ProcessInfo.ThermalState {
    var title: String {
        switch self {
        case .nominal: "正常"
        case .fair: "偏热"
        case .serious: "过热"
        case .critical: "严重过热"
        @unknown default: "未知"
        }
    }

    var color: Color {
        switch self {
        case .nominal: .secondary
        case .fair: .orange
        default: .red
        }
    }
}

func formatUptime(_ interval: TimeInterval) -> String {
    let days = Int(interval / 86400)
    let hours = Int(interval.truncatingRemainder(dividingBy: 86400) / 3600)
    if days > 0 { return hours > 0 ? "\(days) 天 \(hours) 小时" : "\(days) 天" }
    let minutes = Int(interval.truncatingRemainder(dividingBy: 3600) / 60)
    return hours > 0 ? "\(hours) 小时 \(minutes) 分" : "\(minutes) 分钟"
}

func formatMinutes(_ minutes: Int) -> String {
    minutes >= 60 ? "\(minutes / 60) 小时 \(minutes % 60) 分钟" : "\(minutes) 分钟"
}
