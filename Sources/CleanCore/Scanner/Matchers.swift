import Foundation

/// 扫描上下文：扫描开始时一次性采集，扫描过程中不再变化。
public struct ScanContext: Sendable {
    public var running: RunningAppsSnapshot
    /// 查找项目构建产物的根目录
    public var projectRoots: [String]
    /// 项目在这么多天内有修改就算“活跃”，构建产物默认不勾选
    public var activeProjectDays: Int
    public var now: Date

    public init(
        running: RunningAppsSnapshot,
        projectRoots: [String],
        activeProjectDays: Int = 30,
        now: Date = Date()
    ) {
        self.running = running
        self.projectRoots = projectRoots
        self.activeProjectDays = activeProjectDays
        self.now = now
    }
}

/// 匹配阶段找到的候选项，还没有计算大小
struct Candidate {
    var title: String
    var detail: String?
    var urls: [URL]
    var note: String?
    /// nil 表示按风险等级决定
    var preselect: Bool?
}

struct MatchOutput {
    var candidates: [Candidate] = []
    var notes: [String] = []
    var accessDenied = false
}

enum Matchers {
    static func run(_ rule: Rule, context: ScanContext) -> MatchOutput {
        var output: MatchOutput
        switch rule.matcher {
        case .glob: output = globItems(rule, context)
        case .editorExtensions: output = editorExtensions(rule)
        case .unusedClones: output = unusedClones(rule, context)
        case .buildArtifacts: output = buildArtifacts(rule, context)
        case .monthFolders: output = monthFolders(rule)
        case .oldVersions: output = oldVersions(rule)
        }

        // 受系统保护的路径谁也删不掉，直接排除
        output.candidates = output.candidates.compactMap { candidate in
            var candidate = candidate
            candidate.urls.removeAll(where: FileInfo.isProtected)
            return candidate.urls.isEmpty ? nil : candidate
        }

        if rule.aggregate, output.candidates.count > 1 || (output.candidates.count == 1 && rule.matcher == .glob) {
            let urls = output.candidates.flatMap(\.urls)
            let anyUnselected = output.candidates.contains { $0.preselect == false }
            output.candidates = [Candidate(
                title: "\(rule.name)（\(urls.count) 项）",
                detail: rule.paths.first.map { PathExpander.abbreviate(PathExpander.staticPrefix($0)) },
                urls: urls,
                note: anyUnselected ? output.candidates.compactMap(\.note).first : nil,
                preselect: anyUnselected ? false : nil
            )]
        }

        if let app = context.running.isRunning(anyOf: rule.appBundleIDs), rule.matcher != .unusedClones {
            for i in output.candidates.indices {
                output.candidates[i].preselect = false
                output.candidates[i].note = output.candidates[i].note ?? "\(app) 正在运行，建议退出后再清理"
            }
        }
        return output
    }

    // MARK: - glob

    static func globItems(_ rule: Rule, _ context: ScanContext) -> MatchOutput {
        var output = MatchOutput()
        var seen = Set<String>()
        for pattern in rule.paths {
            if PathExpander.isAccessDenied(pattern) {
                output.accessDenied = true
                continue
            }
            let prefix = PathExpander.staticPrefix(pattern)
            for url in PathExpander.glob(pattern) where seen.insert(url.path).inserted {
                if isExcluded(url, rule) { continue }
                if let days = rule.minAgeDays, let modified = FileInfo.modificationDate(url),
                   context.now.timeIntervalSince(modified) < Double(days) * 86400 {
                    continue
                }
                var candidate = Candidate(
                    title: displayTitle(for: url, prefix: prefix),
                    detail: PathExpander.abbreviate(url.deletingLastPathComponent().path),
                    urls: [url]
                )
                if let owner = context.running.owner(of: url) {
                    candidate.note = "\(owner) 正在运行，建议退出后再清理"
                    candidate.preselect = false
                }
                output.candidates.append(candidate)
            }
        }
        return output
    }

    static func isExcluded(_ url: URL, _ rule: Rule) -> Bool {
        rule.exclude.contains { PathExpander.matches(url.path, pattern: $0) }
    }

    /// 用相对于模式前缀的路径作标题，并把 bundle id 换成 App 名：
    /// `~/Library/Caches/com.tencent.xinWeChat` → `微信（com.tencent.xinWeChat）`
    static func displayTitle(for url: URL, prefix: String) -> String {
        var relative = url.path
        if url.path.hasPrefix(prefix + "/") {
            relative = String(url.path.dropFirst(prefix.count + 1))
        } else {
            relative = url.lastPathComponent
        }
        if let simulator = simulatorName(url) { return simulator }
        var parts = relative.split(separator: "/").map(String.init)
        if let first = parts.first, let name = AppNameResolver.displayName(forBundleID: first) {
            parts[0] = "\(name)（\(first)）"
        }
        // 沙盒容器：com.x.app/Data/Library/Caches/y → com.x.app › y
        if let index = parts.firstIndex(of: "Data"), parts[index...].starts(with: ["Data", "Library", "Caches"]) {
            parts.removeSubrange(index..<index + 3)
        }
        return parts.joined(separator: " › ")
    }

    /// 模拟器设备目录名是 UUID，读 device.plist 换成“iPhone 15 · iOS 17.2”
    static func simulatorName(_ url: URL) -> String? {
        guard url.path.contains("/CoreSimulator/Devices/"),
              let data = try? Data(contentsOf: url.appendingPathComponent("device.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let name = plist["name"] as? String
        else { return nil }
        var runtime = (plist["runtime"] as? String) ?? ""
        runtime = runtime.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
        if let dash = runtime.firstIndex(of: "-") {
            let os = runtime[..<dash]
            let version = runtime[runtime.index(after: dash)...].replacingOccurrences(of: "-", with: ".")
            runtime = "\(os) \(version)"
        }
        return runtime.isEmpty ? name : "\(name) · \(runtime)"
    }

    // MARK: - 编辑器扩展旧版本

    /// `publisher.name-1.2.3` 或 `publisher.name-1.2.3-darwin-arm64`
    static func parseExtensionFolder(_ name: String) -> (id: String, version: [Int])? {
        guard let match = name.firstMatch(of: #/^(.+?)-(\d+(?:\.\d+)+)(?:-.+)?$/#) else { return nil }
        return (String(match.1).lowercased(), parseVersion(String(match.2)))
    }

    static func parseVersion(_ string: String) -> [Int] {
        string.split(separator: ".").map { Int($0) ?? 0 }
    }

    static func editorExtensions(_ rule: Rule) -> MatchOutput {
        var output = MatchOutput()
        for pattern in rule.paths {
            for root in PathExpander.glob(pattern) where FileInfo.isDirectory(root) {
                let referenced = referencedExtensionFolders(in: root)
                let obsolete = obsoleteExtensionFolders(in: root)
                var groups: [String: [(url: URL, version: [Int])]] = [:]
                for dir in FileInfo.subdirectories(of: root) {
                    guard let parsed = parseExtensionFolder(dir.lastPathComponent) else { continue }
                    groups[parsed.id, default: []].append((dir, parsed.version))
                }
                for (id, members) in groups {
                    let referencedMembers = members.filter { referenced.contains($0.url.lastPathComponent) }
                    var keep: Set<String>
                    if !referencedMembers.isEmpty {
                        keep = Set(referencedMembers.map { $0.url.lastPathComponent })
                    } else {
                        // extensions.json 里没登记：保守起见保留最高版本
                        let newest = members.max { $0.version.lexicographicallyPrecedes($1.version) }!
                        keep = [newest.url.lastPathComponent]
                    }
                    for member in members {
                        let name = member.url.lastPathComponent
                        let isObsolete = obsolete.contains(name) && !referenced.contains(name)
                        guard !keep.contains(name) || isObsolete else { continue }
                        let version = member.version.map(String.init).joined(separator: ".")
                        output.candidates.append(Candidate(
                            title: "\(id) \(version)",
                            detail: PathExpander.abbreviate(root.path),
                            urls: [member.url]
                        ))
                    }
                }
            }
        }
        output.candidates.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return output
    }

    static func referencedExtensionFolders(in root: URL) -> Set<String> {
        let file = root.appendingPathComponent("extensions.json")
        guard let data = try? Data(contentsOf: file),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        var names = Set<String>()
        for entry in entries {
            if let relative = entry["relativeLocation"] as? String {
                names.insert(relative)
            } else if let location = entry["location"] as? [String: Any], let path = location["path"] as? String {
                names.insert((path as NSString).lastPathComponent)
            }
        }
        return names
    }

    static func obsoleteExtensionFolders(in root: URL) -> Set<String> {
        let file = root.appendingPathComponent(".obsolete")
        guard let data = try? Data(contentsOf: file),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return Set(map.keys)
    }

    // MARK: - 未被占用的克隆副本

    static func unusedClones(_ rule: Rule, _ context: ScanContext) -> MatchOutput {
        var output = MatchOutput()
        let clones = rule.paths.flatMap(PathExpander.glob).filter(FileInfo.isDirectory)
        guard !clones.isEmpty else { return output }

        var inUse = Set<String>()
        var uncertain = false
        if let app = context.running.isRunning(anyOf: rule.appBundleIDs) {
            let openPaths = rule.processName.flatMap(OpenFileInspector.openPaths(command:)) ?? []
            for clone in clones {
                let marker = "/" + clone.lastPathComponent + "/"
                if openPaths.contains(where: { $0.contains(marker) }) {
                    inUse.insert(clone.path)
                }
            }
            if inUse.isEmpty {
                uncertain = true
                output.notes.append("\(app) 正在运行，但没能确认它在用哪一份副本，所以全部默认不勾选。退出 \(app) 后重新扫描即可放心清理。")
            } else {
                output.notes.append("\(inUse.count) 份正在被 \(app) 使用，已自动跳过。")
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for clone in clones where !inUse.contains(clone.path) {
            let created = FileInfo.creationDate(clone).map(formatter.string(from:)) ?? clone.lastPathComponent
            output.candidates.append(Candidate(
                title: "副本 · 创建于 \(created)",
                detail: PathExpander.abbreviate(clone.path),
                urls: [clone],
                preselect: uncertain ? false : nil
            ))
        }
        output.candidates.sort { $0.title < $1.title }
        return output
    }

    // MARK: - 项目构建产物

    /// 产物目录名 → 父目录里必须存在的标志文件（任意一个）
    static let artifactMarkers: [String: [String]] = {
        let node = ["package.json"]
        let gradle = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
        let python = ["pyproject.toml", "requirements.txt", "setup.py", "Pipfile"]
        return [
            "node_modules": node, ".next": node, ".nuxt": node, ".turbo": node,
            ".parcel-cache": node, ".svelte-kit": node, ".angular": ["angular.json"],
            "build": gradle, ".gradle": gradle, ".cxx": gradle,
            "target": ["Cargo.toml", "pom.xml"],
            ".build": ["Package.swift"],
            "Pods": ["Podfile"],
            ".dart_tool": ["pubspec.yaml"],
            ".venv": python, "venv": python,
        ]
    }()

    static let maxProjectDepth = 6

    static func buildArtifacts(_ rule: Rule, _ context: ScanContext) -> MatchOutput {
        var output = MatchOutput()
        let roots = context.projectRoots
            .map(PathExpander.expandTokens)
            .filter { FileInfo.exists($0) }
        for root in roots {
            walkProjects(URL(fileURLWithPath: root), root: root, depth: 0, context: context, output: &output)
        }
        output.candidates.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if roots.isEmpty {
            output.notes.append("还没有配置项目目录，可以在设置里添加。")
        }
        return output
    }

    private static func walkProjects(_ dir: URL, root: String, depth: Int, context: ScanContext, output: inout MatchOutput) {
        guard depth <= maxProjectDepth, !Task.isCancelled else { return }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        let nameSet = Set(names)
        for name in names {
            let child = dir.appendingPathComponent(name)
            guard FileInfo.isDirectory(child) else { continue }
            if let markers = artifactMarkers[name], markers.contains(where: nameSet.contains) {
                if let candidate = artifactCandidate(child, project: dir, root: root, context: context) {
                    output.candidates.append(candidate)
                } else {
                    output.notes.append("\(PathExpander.abbreviate(child.path)) 含有 Git 跟踪的文件，已跳过。")
                }
                continue
            }
            if name.hasPrefix(".") || name == "node_modules" { continue }
            walkProjects(child, root: root, depth: depth + 1, context: context, output: &output)
        }
    }

    private static func artifactCandidate(_ artifact: URL, project: URL, root: String, context: ScanContext) -> Candidate? {
        if GitInspector.containsTrackedFiles(artifact) { return nil }

        let lastActive = projectLastActive(project, root: root)
        let days = Int(context.now.timeIntervalSince(lastActive) / 86400)
        let active = days < context.activeProjectDays
        var projectName = project.path
        if projectName.hasPrefix(root + "/") {
            projectName = String(projectName.dropFirst(root.count + 1))
        } else {
            projectName = project.lastPathComponent
        }
        var note = active ? "项目近 \(context.activeProjectDays) 天内有改动（\(max(days, 0)) 天前）" : "项目已 \(days) 天没有改动"
        // Python 虚拟环境重建要重新装依赖（可能还有手动装的包），始终不默认勾选
        let isVirtualEnv = artifact.lastPathComponent == ".venv" || artifact.lastPathComponent == "venv"
        if isVirtualEnv { note += "；Python 虚拟环境，重建需重新安装依赖" }
        return Candidate(
            title: "\(projectName) › \(artifact.lastPathComponent)",
            detail: PathExpander.abbreviate(project.path),
            urls: [artifact],
            note: note,
            preselect: !active && !isVirtualEnv
        )
    }

    /// 项目最近一次活动：项目目录、标志文件、Git 索引中最新的修改时间
    static func projectLastActive(_ project: URL, root: String) -> Date {
        var dates: [Date] = []
        for name in ["", "package.json", "build.gradle", "build.gradle.kts", "Cargo.toml", "pom.xml", "Package.swift", "pubspec.yaml"] {
            if let date = FileInfo.modificationDate(name.isEmpty ? project : project.appendingPathComponent(name)) {
                dates.append(date)
            }
        }
        // 往上找 .git，取 index/HEAD 的修改时间
        var dir = project
        while dir.path.hasPrefix(root) {
            let git = dir.appendingPathComponent(".git")
            if FileInfo.exists(git.path) {
                for file in ["index", "HEAD", "FETCH_HEAD"] {
                    if let date = FileInfo.modificationDate(git.appendingPathComponent(file)) { dates.append(date) }
                }
                break
            }
            if dir.path == root { break }
            dir = dir.deletingLastPathComponent()
        }
        return dates.max() ?? .distantPast
    }

    // MARK: - 按月份聚合

    static func monthFolders(_ rule: Rule) -> MatchOutput {
        var output = MatchOutput()
        var byMonth: [String: [URL]] = [:]
        for pattern in rule.paths {
            if PathExpander.isAccessDenied(pattern) {
                output.accessDenied = true
                continue
            }
            for root in PathExpander.glob(pattern) where FileInfo.isDirectory(root) {
                for child in FileInfo.subdirectories(of: root) {
                    guard let month = normalizedMonth(child.lastPathComponent) else { continue }
                    byMonth[month, default: []].append(child)
                }
            }
        }
        for month in byMonth.keys.sorted() {
            let urls = byMonth[month]!
            output.candidates.append(Candidate(
                title: month,
                detail: urls.count == 1 ? PathExpander.abbreviate(urls[0].path) : "分布在 \(urls.count) 个会话目录",
                urls: urls
            ))
        }
        return output
    }

    /// `2024-10`、`2024-1` → `2024-10`、`2024-01`；1970 年这类异常日期也保留，方便清理
    static func normalizedMonth(_ name: String) -> String? {
        guard let match = name.firstMatch(of: #/^(\d{4})-(\d{1,2})$/#),
              let month = Int(match.2), (1...12).contains(month)
        else { return nil }
        return String(format: "%@-%02d", String(match.1), month)
    }

    // MARK: - 多版本目录

    /// `IntelliJIdea2025.3` → (`IntelliJIdea`, [2025, 3])；`v22.1.0` → (`v`, [22, 1, 0])
    static func parseVersionedName(_ name: String) -> (product: String, version: [Int])? {
        guard let match = name.firstMatch(of: #/^(.*?[^\d.])?(\d+(?:\.\d+)*)$/#) else { return nil }
        return (String(match.1 ?? ""), parseVersion(String(match.2)))
    }

    static func oldVersions(_ rule: Rule) -> MatchOutput {
        var output = MatchOutput()
        let alias = rule.keepAliasFile
            .flatMap { try? String(contentsOfFile: PathExpander.expandTokens($0), encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var groups: [String: [(url: URL, version: [Int])]] = [:]
        for pattern in rule.paths {
            for url in PathExpander.glob(pattern) where FileInfo.isDirectory(url) {
                if isExcluded(url, rule) { continue }
                guard let parsed = parseVersionedName(url.lastPathComponent) else { continue }
                let key = url.deletingLastPathComponent().path + "|" + parsed.product
                groups[key, default: []].append((url, parsed.version))
            }
        }
        for (_, members) in groups where members.count > 1 {
            let newest = members.max { $0.version.lexicographicallyPrecedes($1.version) }!
            for member in members where member.url != newest.url {
                let name = member.url.lastPathComponent
                if let alias, !alias.isEmpty, name == alias || name == "v" + alias || name.hasPrefix("v" + alias + ".") {
                    continue
                }
                output.candidates.append(Candidate(
                    title: name,
                    detail: PathExpander.abbreviate(member.url.deletingLastPathComponent().path),
                    urls: [member.url],
                    note: "已有更新的版本 \(newest.url.lastPathComponent)"
                ))
            }
        }
        output.candidates.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return output
    }
}

/// 检查目录里是否有被 Git 跟踪的文件
enum GitInspector {
    static func containsTrackedFiles(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", url.deletingLastPathComponent().path, "ls-files", "--error-unmatch", "--", url.lastPathComponent]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        // 0 = 有被跟踪的文件；1 = 没有或不是 Git 仓库
        return process.terminationStatus == 0
    }
}
