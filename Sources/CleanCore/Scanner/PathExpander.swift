import Darwin
import Foundation

/// 把规则里的路径模式展开成真实路径。
public enum PathExpander {
    public static let home: String = NSHomeDirectory()

    /// 当前用户的 `/private/var/folders/xx/xxxx` 目录（真实路径，T/C/X 都在下面）
    public static let darwinUserDir: String = {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else { return "" }
        let temp = String(cString: buffer)
        let resolved = realPath(temp) ?? temp
        return (resolved as NSString).deletingLastPathComponent
    }()

    /// 替换 `~`、`$TMPDIR`、`$DARWIN_USER_DIR`
    public static func expandTokens(_ pattern: String) -> String {
        var p = pattern
        if p == "~" {
            p = home
        } else if p.hasPrefix("~/") {
            p = home + p.dropFirst()
        }
        p = p.replacingOccurrences(of: "$DARWIN_USER_DIR", with: darwinUserDir)
        p = p.replacingOccurrences(of: "$TMPDIR", with: darwinUserDir + "/T")
        return p
    }

    /// 展开 glob。`*` 不匹配以 `.` 开头的文件名。
    public static func glob(_ pattern: String) -> [URL] {
        let expanded = expandTokens(pattern)
        var gt = glob_t()
        defer { globfree(&gt) }
        guard Darwin.glob(expanded, GLOB_BRACE, nil, &gt) == 0 else { return [] }
        var urls: [URL] = []
        for i in 0..<Int(gt.gl_pathc) {
            guard let cPath = gt.gl_pathv[i] else { continue }
            let path = String(cString: cPath)
            if FileInfo.exists(path) {
                urls.append(URL(fileURLWithPath: path))
            }
        }
        return urls
    }

    public static func matches(_ path: String, pattern: String) -> Bool {
        fnmatch(expandTokens(pattern), path, 0) == 0
    }

    /// 模式中不含通配符的前缀目录（展开后），例如 `~/Library/Caches/*` → `/Users/x/Library/Caches`
    public static func staticPrefix(_ pattern: String) -> String {
        let expanded = expandTokens(pattern)
        var parts: [Substring] = []
        for part in expanded.split(separator: "/") {
            if part.contains(where: { "*?[{".contains($0) }) { break }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// 判断模式所在目录是否因权限读不了（TCC 保护的目录 opendir 会返回 EPERM）
    public static func isAccessDenied(_ pattern: String) -> Bool {
        var path = staticPrefix(pattern)
        while path != "/" && !FileInfo.exists(path) {
            path = (path as NSString).deletingLastPathComponent
        }
        guard let dir = opendir(path) else {
            return errno == EPERM || errno == EACCES
        }
        closedir(dir)
        return false
    }

    /// `/Users/x/Library/Caches` → `~/Library/Caches`
    public static func abbreviate(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

enum FileInfo {
    static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    static func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// 带有不可删除标志（SIP 的 restricted / sunlnk、chflags 的 uchg / schg 等）
    static let protectiveFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND | SF_NOUNLINK | SF_RESTRICTED)

    static func isProtected(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return st.st_flags & protectiveFlags != 0
    }

    static func modificationDate(_ url: URL) -> Date? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
    }

    static func creationDate(_ url: URL) -> Date? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(st.st_birthtimespec.tv_sec))
    }

    /// 列出子目录（不跟随符号链接）
    static func subdirectories(of url: URL, includeHidden: Bool = false) -> [URL] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        return names
            .filter { includeHidden || !$0.hasPrefix(".") }
            .map { url.appendingPathComponent($0) }
            .filter { isDirectory($0) }
    }
}
