import Darwin
import Foundation
import IOKit
import IOKit.ps

// MARK: - 数据类型

public struct CPUUsage: Sendable, Equatable {
    /// 0...1，含 nice
    public var user: Double
    public var system: Double
    public var total: Double { min(1, user + system) }
}

public enum MemoryPressure: Sendable {
    case normal, warning, critical

    public var title: String {
        switch self {
        case .normal: "正常"
        case .warning: "偏高"
        case .critical: "紧张"
        }
    }
}

/// 和“活动监视器”的内存页一致的口径
public struct MemoryUsage: Sendable {
    public var total: UInt64
    /// App 内存（匿名页 − 可清除页）
    public var app: UInt64
    /// 联动内存（内核占用，不能压缩或换出）
    public var wired: UInt64
    /// 被压缩的内存
    public var compressed: UInt64
    /// 缓存的文件，内存紧张时可以直接释放
    public var cached: UInt64
    public var pressure: MemoryPressure
    public var swapUsed: UInt64
    /// 交换文件在磁盘上的总大小（/System/Volumes/VM）
    public var swapFileSize: UInt64

    public var used: UInt64 { app + wired + compressed }
}

/// 字节/秒
public struct NetworkRate: Sendable {
    public var download: Double
    public var upload: Double
}

public struct BatteryInfo: Sendable {
    public var percent: Int
    public var isCharging: Bool
    public var isCharged: Bool
    public var onACPower: Bool
    /// 充电时为充满所需时间，用电池时为剩余时间；正在估算时为 nil
    public var minutesRemaining: Int?
    public var cycleCount: Int?
    /// 当前满电容量 ÷ 设计容量
    public var health: Double?
    /// 摄氏度
    public var temperature: Double?
}

/// 一个 App 的资源占用（主进程和所有辅助进程合计）
public struct AppUsage: Sendable, Identifiable {
    public var id: String
    public var name: String
    /// App 包路径，用来显示图标；非 App 进程为 nil
    public var bundlePath: String?
    /// 内存占用（phys_footprint，和活动监视器的“内存”列一致）
    public var memory: UInt64
    /// 1.0 表示占满一个核心
    public var cpu: Double
    public var processCount: Int
}

public struct SystemSnapshot: Sendable {
    public var date: Date
    /// 第一次采样没有对比基准，为 nil
    public var cpu: CPUUsage?
    /// 1 分钟平均负载
    public var loadAverage: Double
    public var memory: MemoryUsage
    public var network: NetworkRate?
    public var battery: BatteryInfo?
    /// 距上次开机（含睡眠时间，和 `uptime` 一致）
    public var uptime: TimeInterval
    public var thermalState: ProcessInfo.ThermalState
    /// 当前用户的 App，按内存降序
    public var apps: [AppUsage]
}

public struct MachineInfo: Sendable {
    /// 如 “MacBook Pro (14-inch, Nov 2023)”
    public var productName: String
    /// 如 “Mac15,3”
    public var modelIdentifier: String
    /// 如 “Apple M3”
    public var chip: String
    public var performanceCores: Int
    public var efficiencyCores: Int
    public var totalCores: Int
    public var memory: UInt64
    public var osVersion: String

    public static func current() -> MachineInfo {
        let model = Sysctl.string("hw.model") ?? "Mac"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let patch = os.patchVersion > 0 ? ".\(os.patchVersion)" : ""
        return MachineInfo(
            productName: productName() ?? model,
            modelIdentifier: model,
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "",
            performanceCores: Sysctl.int("hw.perflevel0.physicalcpu") ?? 0,
            efficiencyCores: Sysctl.int("hw.perflevel1.physicalcpu") ?? 0,
            totalCores: Sysctl.int("hw.ncpu") ?? ProcessInfo.processInfo.processorCount,
            memory: ProcessInfo.processInfo.physicalMemory,
            osVersion: "macOS \(os.majorVersion).\(os.minorVersion)\(patch)"
        )
    }

    /// Apple 芯片的机型全名在设备树 `/product` 的 product-name 里
    private static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data
        else { return nil }
        let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespaces))
        return name.isEmpty ? nil : name
    }
}

// MARK: - 采样

/// 定时调用 `sample()`。CPU、网络、进程 CPU 都按两次采样的差值计算。
public actor SystemSampler {
    private let host = mach_host_self()
    private let timebase: (numer: UInt64, denom: UInt64)
    private var lastCPUTicks: [UInt32]?
    private var lastNetwork: [String: (rx: UInt32, tx: UInt32)] = [:]
    private var lastNetworkDate: Date?
    private var lastProcessCPU: [pid_t: UInt64] = [:]
    private var lastProcessDate: Date?
    private var battery: BatteryInfo?
    private var batteryDate: Date?
    private var displayNames: [String: String] = [:]

    public init() {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        timebase = (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }

    public func sample() -> SystemSnapshot {
        let now = Date()
        // 电池信息变化慢，30 秒读一次
        if batteryDate.map({ now.timeIntervalSince($0) > 30 }) ?? true {
            battery = Self.readBattery()
            batteryDate = now
        }
        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        return SystemSnapshot(
            date: now,
            cpu: sampleCPU(),
            loadAverage: loads[0],
            memory: sampleMemory(),
            network: sampleNetwork(now: now),
            battery: battery,
            uptime: Self.uptime(now: now),
            thermalState: ProcessInfo.processInfo.thermalState,
            apps: sampleApps(now: now)
        )
    }

    private func sampleCPU() -> CPUUsage? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        defer { lastCPUTicks = ticks }
        guard let last = lastCPUTicks else { return nil }
        // 计数器是 32 位，用回绕减法
        let user = Double(ticks[Int(CPU_STATE_USER)] &- last[Int(CPU_STATE_USER)])
            + Double(ticks[Int(CPU_STATE_NICE)] &- last[Int(CPU_STATE_NICE)])
        let system = Double(ticks[Int(CPU_STATE_SYSTEM)] &- last[Int(CPU_STATE_SYSTEM)])
        let idle = Double(ticks[Int(CPU_STATE_IDLE)] &- last[Int(CPU_STATE_IDLE)])
        let total = user + system + idle
        guard total > 0 else { return nil }
        return CPUUsage(user: user / total, system: system / total)
    }

    private func sampleMemory() -> MemoryUsage {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        let page = UInt64(vm_kernel_page_size)
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        let pressure: MemoryPressure
        switch Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1 {
        case 4: pressure = .critical
        case 2: pressure = .warning
        default: pressure = .normal
        }

        return MemoryUsage(
            total: ProcessInfo.processInfo.physicalMemory,
            app: (anonymous > purgeable ? anonymous - purgeable : 0) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            cached: (UInt64(stats.external_page_count) + purgeable) * page,
            pressure: pressure,
            swapUsed: swap.xsu_used,
            swapFileSize: swap.xsu_total
        )
    }

    /// 只统计 en* 物理网卡，避免 VPN（utun）等虚拟网卡重复计算
    private func sampleNetwork(now: Date) -> NetworkRate? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }

        var current: [String: (rx: UInt32, tx: UInt32)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            cursor = entry.pointee.ifa_next
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let data = entry.pointee.ifa_data
            else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            current[name] = (counters.ifi_ibytes, counters.ifi_obytes)
        }

        defer {
            lastNetwork = current
            lastNetworkDate = now
        }
        guard let lastDate = lastNetworkDate else { return nil }
        let elapsed = now.timeIntervalSince(lastDate)
        guard elapsed > 0 else { return nil }
        var rx: UInt64 = 0
        var tx: UInt64 = 0
        for (name, value) in current {
            guard let previous = lastNetwork[name] else { continue }
            rx += UInt64(value.rx &- previous.rx)
            tx += UInt64(value.tx &- previous.tx)
        }
        return NetworkRate(download: Double(rx) / elapsed, upload: Double(tx) / elapsed)
    }

    /// 按 App 汇总当前用户的进程：Chrome 的几十个辅助进程会算到 Chrome 名下
    private func sampleApps(now: Date) -> [AppUsage] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 64)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        let elapsed = lastProcessDate.map { now.timeIntervalSince($0) * 1e9 }

        var cpuTimes: [pid_t: UInt64] = [:]
        var groups: [String: AppUsage] = [:]
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(max(count, 0)) where pid > 0 {
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            // 其他用户（root）的进程读不到，跳过
            guard result == 0 else { continue }

            // Apple 芯片上的时间单位是 mach tick，要按时基换算成纳秒
            let cpuNanos = (usage.ri_user_time + usage.ri_system_time) * timebase.numer / timebase.denom
            cpuTimes[pid] = cpuNanos
            var cpu = 0.0
            if let elapsed, elapsed > 0, let previous = lastProcessCPU[pid], cpuNanos >= previous {
                cpu = Double(cpuNanos - previous) / elapsed
            }

            let identity = identify(pid, buffer: &pathBuffer)
            var group = groups[identity.key] ?? AppUsage(
                id: identity.key, name: identity.name, bundlePath: identity.bundle, memory: 0, cpu: 0, processCount: 0
            )
            group.memory += usage.ri_phys_footprint
            group.cpu += cpu
            group.processCount += 1
            groups[identity.key] = group
        }
        lastProcessCPU = cpuTimes
        lastProcessDate = now
        return groups.values.sorted { $0.memory > $1.memory }
    }

    private func identify(_ pid: pid_t, buffer: inout [CChar]) -> (key: String, name: String, bundle: String?) {
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        let path = length > 0 ? String(cString: buffer) : ""
        if let range = path.range(of: ".app/") {
            let bundle = String(path[..<range.lowerBound]) + ".app"
            return (bundle, displayName(forBundle: bundle), bundle)
        }
        var name = (path as NSString).lastPathComponent
        if name.isEmpty {
            var nameBuffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            name = String(cString: nameBuffer)
        }
        if name == "com.apple.Virtualization.VirtualMachine" { name = "虚拟机（Docker、Claude 等）" }
        return ("proc:" + name, name.isEmpty ? "进程 \(pid)" : name, nil)
    }

    private func displayName(forBundle path: String) -> String {
        if let cached = displayNames[path] { return cached }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        displayNames[path] = name
        return name
    }

    private static func uptime(now: Date) -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        return now.timeIntervalSince1970 - TimeInterval(boot.tv_sec)
    }

    private static func readBattery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            let current = description[kIOPSCurrentCapacityKey] as? Int ?? 0
            let maximum = description[kIOPSMaxCapacityKey] as? Int ?? 100
            let charging = description[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            var minutes = charging
                ? description[kIOPSTimeToFullChargeKey] as? Int
                : (onAC ? nil : description[kIOPSTimeToEmptyKey] as? Int)
            if let value = minutes, value <= 0 { minutes = nil }

            var info = BatteryInfo(
                percent: maximum > 0 ? current * 100 / maximum : current,
                isCharging: charging,
                isCharged: description[kIOPSIsChargedKey] as? Bool ?? false,
                onACPower: onAC,
                minutesRemaining: minutes
            )
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                func property(_ key: String) -> Int? {
                    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? Int
                }
                info.cycleCount = property("CycleCount")
                if let design = property("DesignCapacity"), design > 0,
                   let full = property("NominalChargeCapacity") ?? property("AppleRawMaxCapacity") {
                    info.health = min(1, Double(full) / Double(design))
                }
                if let raw = property("Temperature"), raw > 0 {
                    info.temperature = Double(raw) / 100
                }
            }
            return info
        }
        return nil
    }
}

enum Sysctl {
    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// 兼容 32 位和 64 位整数（小端，缓冲区先清零）
    static func int(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return size == MemoryLayout<Int32>.size ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }
}
