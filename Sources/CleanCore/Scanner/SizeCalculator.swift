import Darwin
import Foundation

public struct SizeInfo: Sendable, Equatable {
    /// 占用的磁盘空间（st_blocks × 512），和 `du`、访达一致；稀疏文件不会虚报
    public var allocated: Int64 = 0
    /// 删除后一定能释放的空间：不和任何克隆、快照共用的部分
    public var exclusive: Int64 = 0
    /// 预计释放：同一份克隆数据在一条规则内只算一次
    public var estimated: Int64 = 0
    public var fileCount: Int = 0
    public var unreadable: Int = 0
    /// 当前用户删不掉的条目：属于其他用户（如 sudo 创建）的目录、带保护标志的文件
    public var blocked: Int = 0
    public var newestModification: Date?

    mutating func merge(_ other: SizeInfo) {
        allocated += other.allocated
        exclusive += other.exclusive
        estimated += other.estimated
        fileCount += other.fileCount
        unreadable += other.unreadable
        blocked += other.blocked
        if let date = other.newestModification, date > (newestModification ?? .distantPast) {
            newestModification = date
        }
    }

    mutating func add(_ bytes: Int64, exclusive: Int64? = nil, estimated: Int64? = nil) {
        allocated += bytes
        self.exclusive += exclusive ?? bytes
        self.estimated += estimated ?? bytes
    }
}

/// 记录已统计过的硬链接和 APFS 克隆，避免同一份数据重复计算
final class SharingTracker: @unchecked Sendable {
    private struct Inode: Hashable { let dev: Int32; let ino: UInt64 }
    private var inodes = Set<Inode>()
    private var clones = Set<UInt64>()
    private let lock = NSLock()

    func firstHardLink(dev: Int32, ino: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inodes.insert(Inode(dev: dev, ino: ino)).inserted
    }

    func firstClone(_ id: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return clones.insert(id).inserted
    }
}

/// APFS 克隆信息（getattrlist 扩展属性）
struct CloneInfo {
    /// 删除后立即释放的字节数（不被克隆或快照共用）
    let privateSize: Int64
    /// 内容完全相同的克隆共用同一个 id
    let cloneID: UInt64
    /// 可能和其他文件共用数据块
    let mayShareBlocks: Bool

    static func read(_ path: UnsafePointer<CChar>) -> CloneInfo? {
        let wanted = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) | attrgroup_t(ATTR_CMNEXT_CLONEID) | attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS)
        list.forkattr = wanted
        // 布局：u_int32 长度 | attribute_set_t（5 × u_int32）| privatesize | cloneid | ext_flags
        var buffer = (UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0), UInt64(0))
        let result = withUnsafeMutableBytes(of: &buffer) { raw in
            getattrlist(path, &list, raw.baseAddress, raw.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW))
        }
        guard result == 0 else { return nil }
        return withUnsafeBytes(of: &buffer) { raw -> CloneInfo? in
            let returnedFork = raw.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self)
            guard returnedFork & wanted == wanted else { return nil }
            let flags = raw.loadUnaligned(fromByteOffset: 40, as: UInt64.self)
            return CloneInfo(
                privateSize: raw.loadUnaligned(fromByteOffset: 24, as: Int64.self),
                cloneID: raw.loadUnaligned(fromByteOffset: 32, as: UInt64.self),
                mayShareBlocks: flags & UInt64(EF_MAY_SHARE_BLOCKS) != 0
            )
        }
    }
}

public enum SizeCalculator {
    static let cloneCheckThreshold: Int64 = 64 * 1024
    static let currentUser = getuid()

    /// 用 fts 遍历统计，不跟随符号链接、不跨卷。任务取消时返回已统计的部分。
    static func measure(_ url: URL, tracker: SharingTracker? = nil) -> SizeInfo {
        var info = SizeInfo()
        guard let cPath = strdup(url.path) else { return info }
        defer { free(cPath) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cPath, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            info.unreadable += 1
            return info
        }
        defer { fts_close(fts) }

        var visited = 0
        var newest = 0
        while let entry = fts_read(fts) {
            visited += 1
            if visited & 0xFFF == 0 && Task.isCancelled { break }

            switch Int32(entry.pointee.fts_info) {
            case FTS_DP:
                continue
            case FTS_DNR, FTS_ERR, FTS_NS:
                info.unreadable += 1
                continue
            default:
                break
            }
            guard let st = entry.pointee.fts_statp?.pointee else { continue }
            let bytes = Int64(st.st_blocks) * 512
            if st.st_flags & FileInfo.protectiveFlags != 0
                || ((st.st_mode & S_IFMT) == S_IFDIR && st.st_uid != currentUser) {
                info.blocked += 1
            }
            newest = max(newest, st.st_mtimespec.tv_sec)

            let kind = st.st_mode & S_IFMT
            guard kind == S_IFREG else {
                info.add(bytes)
                continue
            }
            if st.st_nlink > 1, let tracker, !tracker.firstHardLink(dev: st.st_dev, ino: st.st_ino) {
                continue
            }
            info.fileCount += 1
            // 小文件即使是克隆对总量影响也很小，跳过属性查询能明显加快扫描（node_modules 里大多是小文件）
            guard bytes >= cloneCheckThreshold, let clone = CloneInfo.read(entry.pointee.fts_path), clone.mayShareBlocks else {
                info.add(bytes)
                continue
            }
            let isFirstCopy = tracker?.firstClone(clone.cloneID) ?? true
            info.add(bytes, exclusive: clone.privateSize, estimated: isFirstCopy ? bytes : clone.privateSize)
        }
        if newest > 0 {
            info.newestModification = Date(timeIntervalSince1970: TimeInterval(newest))
        }
        return info
    }
}
