import Foundation

/// 删除前的最后一道校验。任何一条不满足都拒绝删除。
public struct SafetyGuard: Sendable {
    public enum Verdict: Equatable, Sendable {
        case allowed
        case rejected(String)
    }

    /// 只允许删除这些目录下面的内容
    public let allowedRoots: [String]
    /// 用户的保护清单（真实路径）
    public let protectedPaths: [String]
    private let home: String

    public init(
        protectedPaths: [String] = [],
        allowedRoots: [String]? = nil,
        home: String = PathExpander.home
    ) {
        self.home = PathExpander.realPath(home) ?? home
        self.allowedRoots = (allowedRoots ?? [home, PathExpander.darwinUserDir])
            .filter { !$0.isEmpty }
            .map { PathExpander.realPath($0) ?? $0 }
        self.protectedPaths = protectedPaths.map {
            let expanded = PathExpander.expandTokens($0)
            return PathExpander.realPath(expanded) ?? expanded
        }
    }

    /// 绝对不能整个删掉的目录
    private var neverDelete: Set<String> {
        let h = home
        var set: Set<String> = [
            "/", "/System", "/Library", "/Applications", "/Users", "/usr", "/bin", "/sbin",
            "/private", "/private/var", "/private/var/folders", "/Volumes",
        ]
        for sub in [
            "", "/Library", "/Library/Caches", "/Library/Application Support", "/Library/Containers",
            "/Library/Group Containers", "/Library/Preferences", "/Library/Logs", "/Library/Developer",
            "/Library/Mobile Documents", "/Library/Mail", "/Library/Messages", "/Library/Keychains",
            "/Documents", "/Desktop", "/Downloads", "/Pictures", "/Movies", "/Music", "/Applications",
            "/.ssh", "/.gnupg", "/.Trash", "/.config", "/.local", "/.cache",
        ] {
            set.insert(h + sub)
        }
        for root in allowedRoots { set.insert(root) }
        return set
    }

    public func check(_ url: URL) -> Verdict {
        let raw = url.path
        guard raw.hasPrefix("/") else { return .rejected("不是绝对路径") }
        if raw.split(separator: "/").contains("..") { return .rejected("路径包含 ..") }
        guard FileInfo.exists(raw) else { return .rejected("文件已不存在") }

        // 父目录解析符号链接，最后一级不解析（删符号链接本身而不是它指向的内容）
        let parent = (raw as NSString).deletingLastPathComponent
        guard let realParent = PathExpander.realPath(parent) else { return .rejected("无法解析路径") }
        let path = (realParent as NSString).appendingPathComponent((raw as NSString).lastPathComponent)

        if neverDelete.contains(path) { return .rejected("受保护的系统或用户目录") }
        if FileInfo.isProtected(URL(fileURLWithPath: path)) { return .rejected("受系统完整性保护（SIP），无法删除") }

        guard let root = allowedRoots.first(where: { path.hasPrefix($0 + "/") }) else {
            return .rejected("不在允许清理的范围内")
        }
        // 至少要在允许目录下两层，防止误删 ~/Something 这种顶层目录
        let depth = path.dropFirst(root.count).split(separator: "/").count
        if depth < 2 { return .rejected("目录层级太浅") }

        for protected in protectedPaths {
            if path == protected || path.hasPrefix(protected + "/") {
                return .rejected("在保护清单中")
            }
            if protected.hasPrefix(path + "/") {
                return .rejected("包含保护清单中的路径")
            }
        }
        return .allowed
    }
}
