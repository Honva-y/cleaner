import Darwin
import Foundation

public enum Permissions {
    /// 系统设置 → 隐私与安全性 → 完全磁盘访问
    public static let fullDiskAccessSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// 通过尝试读取受 TCC 保护的目录判断是否有“完全磁盘访问”权限
    public static func hasFullDiskAccess() -> Bool {
        for path in ["~/Library/Safari", "~/.Trash", "~/Library/Mail"].map(PathExpander.expandTokens)
        where FileInfo.exists(path) {
            guard let dir = opendir(path) else { return false }
            closedir(dir)
            return true
        }
        return true
    }
}
