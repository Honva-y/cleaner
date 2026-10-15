import CleanCore
import Foundation
import Observation

/// 用户设置，保存在 UserDefaults
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    static let defaultProjectRoots = [
        "~/git-project", "~/Projects", "~/projects", "~/Developer", "~/code", "~/workspace",
        "~/AndroidStudioProjects", "~/IdeaProjects", "~/Documents/GitHub",
    ]

    /// 所有删除都先移到废纸篓
    var alwaysTrash: Bool {
        didSet { defaults.set(alwaysTrash, forKey: "alwaysTrash") }
    }

    /// 查找构建产物的项目目录
    var projectRoots: [String] {
        didSet { defaults.set(projectRoots, forKey: "projectRoots") }
    }

    /// 保护清单：这些路径及其子路径永远不会被清理
    var protectedPaths: [String] {
        didSet { defaults.set(protectedPaths, forKey: "protectedPaths") }
    }

    /// 项目多少天内有改动算“活跃”
    var activeProjectDays: Int {
        didSet { defaults.set(activeProjectDays, forKey: "activeProjectDays") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        alwaysTrash = defaults.bool(forKey: "alwaysTrash")
        projectRoots = defaults.stringArray(forKey: "projectRoots") ?? Self.defaultProjectRoots
        protectedPaths = defaults.stringArray(forKey: "protectedPaths") ?? []
        let days = defaults.integer(forKey: "activeProjectDays")
        activeProjectDays = days > 0 ? days : 30
    }
}
