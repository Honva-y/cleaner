import Foundation

/// 风险等级：决定默认是否勾选、删除方式和确认强度。
public enum RiskLevel: String, Codable, Sendable, CaseIterable, Comparable {
    /// 可重新生成的缓存、日志，默认勾选
    case safe
    /// 构建产物、旧版本、安装包，默认不勾
    case caution
    /// 聊天文件、备份等个人数据，只能逐项手动选择，并且一律移到废纸篓
    case manual

    public var title: String {
        switch self {
        case .safe: "安全"
        case .caution: "谨慎"
        case .manual: "手动"
        }
    }

    private var order: Int {
        switch self {
        case .safe: 0
        case .caution: 1
        case .manual: 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.order < rhs.order }
}

public enum CleanCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case anomaly, system, browser, developer, ai, chat

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .anomaly: "异常残留"
        case .system: "系统垃圾"
        case .browser: "浏览器"
        case .developer: "开发工具"
        case .ai: "AI 工具"
        case .chat: "聊天软件"
        }
    }

    public var symbol: String {
        switch self {
        case .anomaly: "exclamationmark.triangle"
        case .system: "gearshape.2"
        case .browser: "globe"
        case .developer: "hammer"
        case .ai: "sparkles"
        case .chat: "bubble.left.and.bubble.right"
        }
    }

    public var summary: String {
        switch self {
        case .anomaly: "不该存在的残留：异常退出留下的副本、不断堆积的旧版本"
        case .system: "应用缓存、日志、临时文件、安装包和废纸篓"
        case .browser: "网页缓存，不会动 Cookie、密码和历史记录"
        case .developer: "依赖缓存、项目构建产物、旧版本工具链"
        case .ai: "AI 编程工具的缓存、旧会话和镜像"
        case .chat: "微信、企业微信的缓存和聊天文件"
        }
    }
}

public enum CleanAction: String, Codable, Sendable {
    /// 直接删除：只用于能自动重新生成的内容
    case delete
    /// 移到废纸篓：可以恢复，但清空废纸篓后才会真正释放空间
    case trash
    /// 只展示占用，不提供删除（需要在对应 App 里处理）
    case reveal
}

public enum MatcherKind: String, Codable, Sendable {
    /// `paths` 中每个 glob 匹配到的路径各算一项
    case glob
    /// 编辑器扩展目录里没有被 extensions.json 引用的旧版本
    case editorExtensions
    /// 没有被进程占用的克隆副本（Chrome code_sign_clone）
    case unusedClones
    /// 项目目录里的构建产物（node_modules、build、target…）
    case buildArtifacts
    /// 按 YYYY-MM 月份目录聚合（聊天媒体）
    case monthFolders
    /// 同一产品的多个版本目录，只保留最新版本（JetBrains、nvm）
    case oldVersions
}

/// 一条清理规则。内置规则写在 `BuiltinRules`，用户也可以在
/// `~/Library/Application Support/Cleaner/rules/*.json` 里追加。
public struct Rule: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var category: CleanCategory
    public var risk: RiskLevel
    public var action: CleanAction
    public var summary: String
    /// glob 路径，支持 `~`、`$TMPDIR`、`$DARWIN_USER_DIR` 和 `{a,b}`
    public var paths: [String]
    /// 排除的 glob（与匹配到的完整路径比较）
    public var exclude: [String]
    public var matcher: MatcherKind
    /// 只包含超过 N 天未修改的项
    public var minAgeDays: Int?
    /// 这些 App 运行时整条规则默认不勾选
    public var appBundleIDs: [String]
    /// `unusedClones` 用来检测占用的进程名前缀
    public var processName: String?
    /// `oldVersions` 额外保留此文件里写的版本（如 nvm 的 alias/default）
    public var keepAliasFile: String?
    /// 把所有匹配项合并成一项展示（适合大量小文件）
    public var aggregate: Bool
    /// 额外提示，如 App 内的官方清理入口
    public var hint: String?

    public init(
        id: String,
        name: String,
        category: CleanCategory,
        risk: RiskLevel,
        action: CleanAction,
        summary: String,
        paths: [String],
        exclude: [String] = [],
        matcher: MatcherKind = .glob,
        minAgeDays: Int? = nil,
        appBundleIDs: [String] = [],
        processName: String? = nil,
        keepAliasFile: String? = nil,
        aggregate: Bool = false,
        hint: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.risk = risk
        self.action = action
        self.summary = summary
        self.paths = paths
        self.exclude = exclude
        self.matcher = matcher
        self.minAgeDays = minAgeDays
        self.appBundleIDs = appBundleIDs
        self.processName = processName
        self.keepAliasFile = keepAliasFile
        self.aggregate = aggregate
        self.hint = hint
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        category = try c.decode(CleanCategory.self, forKey: .category)
        risk = try c.decode(RiskLevel.self, forKey: .risk)
        action = try c.decodeIfPresent(CleanAction.self, forKey: .action) ?? .trash
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        paths = try c.decode([String].self, forKey: .paths)
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        matcher = try c.decodeIfPresent(MatcherKind.self, forKey: .matcher) ?? .glob
        minAgeDays = try c.decodeIfPresent(Int.self, forKey: .minAgeDays)
        appBundleIDs = try c.decodeIfPresent([String].self, forKey: .appBundleIDs) ?? []
        processName = try c.decodeIfPresent(String.self, forKey: .processName)
        keepAliasFile = try c.decodeIfPresent(String.self, forKey: .keepAliasFile)
        aggregate = try c.decodeIfPresent(Bool.self, forKey: .aggregate) ?? false
        hint = try c.decodeIfPresent(String.self, forKey: .hint)
    }

    /// 实际执行的删除方式：手动级别的内容一律移到废纸篓
    public func effectiveAction(alwaysTrash: Bool) -> CleanAction {
        if action == .reveal { return .reveal }
        if risk == .manual || alwaysTrash { return .trash }
        return action
    }
}
