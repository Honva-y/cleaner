import Foundation

/// 操作日志：每删一个路径记一行到 `~/Library/Logs/Cleaner/operations.log`；
/// 每次清理的汇总记到 `~/Library/Application Support/Cleaner/history.json`。
public final class Journal: @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        public var time = Date()
        public var ruleID: String
        public var ruleName: String
        public var path: String
        public var action: String
        public var result: String
        public var message: String?

        init(rule: Rule, path: String, action: CleanAction, result: String, message: String?) {
            ruleID = rule.id
            ruleName = rule.name
            self.path = path
            self.action = action.rawValue
            self.result = result
            self.message = message
        }
    }

    public struct Session: Codable, Sendable, Identifiable {
        public var id: Date { date }
        public var date: Date
        public var estimatedBytes: Int64
        public var deletedBytes: Int64
        public var trashedBytes: Int64
        public var measuredFreedBytes: Int64?
        public var cleanedItems: Int
        public var failureCount: Int
    }

    public static let shared = Journal(
        logURL: URL(fileURLWithPath: PathExpander.home + "/Library/Logs/Cleaner/operations.log"),
        historyURL: URL(fileURLWithPath: PathExpander.home + "/Library/Application Support/Cleaner/history.json")
    )

    public let logURL: URL
    public let historyURL: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public init(logURL: URL, historyURL: URL) {
        self.logURL = logURL
        self.historyURL = historyURL
    }

    func append(_ entry: Entry) {
        guard var data = try? encoder.encode(entry) else { return }
        data.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    func recordSession(_ report: CleanReport) {
        var sessions = history()
        sessions.insert(Session(
            date: report.date,
            estimatedBytes: report.estimatedBytes,
            deletedBytes: report.deletedBytes,
            trashedBytes: report.trashedBytes,
            measuredFreedBytes: report.measuredFreedBytes,
            cleanedItems: report.cleanedItems,
            failureCount: report.failures.count
        ), at: 0)
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let pretty = JSONEncoder()
        pretty.dateEncodingStrategy = .iso8601
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? pretty.encode(Array(sessions.prefix(200))).write(to: historyURL, options: .atomic)
    }

    public func history() -> [Session] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Session].self, from: data)) ?? []
    }
}
