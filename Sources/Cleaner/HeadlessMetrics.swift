import CleanCore
import Foundation

/// `Cleaner --metrics`：打印一次设备状态（开发调试用）
enum HeadlessMetrics {
    static func run() async {
        let machine = MachineInfo.current()
        print("\(machine.productName)（\(machine.modelIdentifier)）· \(machine.chip) · \(machine.totalCores) 核（\(machine.performanceCores) 性能 + \(machine.efficiencyCores) 能效）· \(gb(machine.memory)) · \(machine.osVersion)")
        let sampler = SystemSampler()
        _ = await sampler.sample()
        try? await Task.sleep(for: .seconds(1))
        let s = await sampler.sample()
        if let cpu = s.cpu {
            print(String(format: "CPU %.0f%%（用户 %.0f%% · 系统 %.0f%%）负载 %.2f", cpu.total * 100, cpu.user * 100, cpu.system * 100, s.loadAverage))
        }
        let m = s.memory
        print("内存 已用 \(gb(m.used)) / \(gb(m.total))：App \(gb(m.app)) · 联动 \(gb(m.wired)) · 压缩 \(gb(m.compressed)) · 缓存文件 \(gb(m.cached)) · 压力 \(m.pressure.title)")
        print("交换 已用 \(gb(m.swapUsed))，交换文件占磁盘 \(gb(m.swapFileSize))")
        if let n = s.network {
            print("网络 ↓ \(ByteCountFormatter.string(fromByteCount: Int64(n.download), countStyle: .file))/s ↑ \(ByteCountFormatter.string(fromByteCount: Int64(n.upload), countStyle: .file))/s")
        }
        if let b = s.battery {
            print("电池 \(b.percent)% 充电中=\(b.isCharging) 已充满=\(b.isCharged) 电源=\(b.onACPower) 剩余=\(b.minutesRemaining.map(String.init) ?? "-") 分钟 循环=\(b.cycleCount ?? -1) 健康=\(Int((b.health ?? 0) * 100))% 温度=\(b.temperature ?? 0)°C")
        }
        print(String(format: "已运行 %.1f 天 · 温度状态 %d", s.uptime / 86400, s.thermalState.rawValue))
        print("内存占用最多：")
        for app in s.apps.prefix(6) {
            print(String(format: "  %@  %@  CPU %.0f%%  %d 个进程", app.name, gb(app.memory), app.cpu * 100, app.processCount))
        }
    }

    static func gb(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
