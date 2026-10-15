import AppKit
import Foundation

/// 扫描开始时正在运行的 App。用来避免清理正在使用的缓存。
public struct RunningAppsSnapshot: Sendable {
    public var bundleIDs: Set<String>
    /// 小写的 App 名称、bundle 文件名、可执行文件名
    public var names: Set<String>
    /// 名称（小写）或 bundle id → 展示用的 App 名
    private var displayNames: [String: String]

    public init(bundleIDs: Set<String> = [], names: [String: String] = [:]) {
        self.bundleIDs = bundleIDs
        self.names = Set(names.keys)
        self.displayNames = names
        for id in bundleIDs where displayNames[id] == nil {
            displayNames[id] = id
        }
    }

    @MainActor
    public static func current() -> RunningAppsSnapshot {
        var ids = Set<String>()
        var names: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let display = app.localizedName ?? app.bundleIdentifier ?? ""
            if let id = app.bundleIdentifier {
                ids.insert(id)
                names[id.lowercased()] = display
            }
            guard app.activationPolicy != .prohibited else { continue }
            for candidate in [
                app.localizedName,
                app.bundleURL?.deletingPathExtension().lastPathComponent,
                app.executableURL?.lastPathComponent,
            ] {
                if let candidate, !candidate.isEmpty {
                    names[candidate.lowercased()] = display
                }
            }
        }
        return RunningAppsSnapshot(bundleIDs: ids, names: names)
    }

    public func isRunning(anyOf bundleIDs: [String]) -> String? {
        for id in bundleIDs where self.bundleIDs.contains(id) {
            return displayNames[id.lowercased()] ?? id
        }
        return nil
    }

    /// 判断路径属于哪个正在运行的 App：看它在 Caches / Application Support / Containers 下的第一级目录名
    public func owner(of url: URL) -> String? {
        let library = PathExpander.home + "/Library/"
        let roots = ["Caches/", "Application Support/", "Containers/", "Logs/"]
        let path = url.path
        for root in roots {
            let prefix = library + root
            guard path.hasPrefix(prefix) else { continue }
            guard let first = path.dropFirst(prefix.count).split(separator: "/").first else { return nil }
            let key = String(first).lowercased()
            if let name = displayNames[key], names.contains(key) || bundleIDs.contains(String(first)) {
                return name
            }
            // com.microsoft.VSCode.ShipIt 这类以 bundle id 开头的目录
            for id in bundleIDs where key.hasPrefix(id.lowercased() + ".") {
                return displayNames[id.lowercased()] ?? id
            }
            return nil
        }
        return nil
    }
}

/// 查询进程打开的文件（基于 lsof）
public enum OpenFileInspector {
    /// 返回进程名以 `command` 开头的进程打开的所有路径。lsof 无法运行时返回 nil。
    public static func openPaths(command: String) -> Set<String>? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-n", "-P", "-w", "-F", "n", "-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var paths = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("n") {
            paths.insert(String(line.dropFirst()))
        }
        return paths
    }
}

/// bundle id → App 显示名（如 com.tencent.xinWeChat → 微信）
public enum AppNameResolver {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    public static func displayName(forBundleID id: String) -> String? {
        guard id.split(separator: ".").count >= 3 else { return nil }
        lock.lock()
        if let cached = cache[id] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var name: String?
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            name = FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        lock.lock()
        cache[id] = name
        lock.unlock()
        return name
    }
}
