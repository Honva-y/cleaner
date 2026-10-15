import Foundation
import Testing
@testable import CleanCore

/// 每个测试一个独立的临时目录（在 $TMPDIR 下，属于 SafetyGuard 允许的范围）
final class Sandbox {
    let root: URL

    init() throws {
        let base = URL(fileURLWithPath: PathExpander.realPath(NSTemporaryDirectory()) ?? NSTemporaryDirectory())
        root = base.appendingPathComponent("cleaner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        Cleaner.makeWritable(root)
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func file(_ path: String, bytes: Int = 10_000, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x61, count: bytes).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    @discardableResult
    func dir(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func rule(_ id: String = "test", matcher: MatcherKind = .glob, paths: [String], risk: RiskLevel = .safe, action: CleanAction = .delete, keepAliasFile: String? = nil) -> Rule {
        Rule(id: id, name: id, category: .system, risk: risk, action: action, summary: "", paths: paths.map { root.path + "/" + $0 }, matcher: matcher, keepAliasFile: keepAliasFile.map { root.path + "/" + $0 })
    }
}

let emptyContext = ScanContext(running: RunningAppsSnapshot(), projectRoots: [])

@Suite struct SafetyGuardTests {
    @Test func rejectsTopLevelAndSystemPaths() throws {
        let guardrail = SafetyGuard()
        #expect(guardrail.check(URL(fileURLWithPath: "/")) != .allowed)
        #expect(guardrail.check(URL(fileURLWithPath: PathExpander.home)) != .allowed)
        #expect(guardrail.check(URL(fileURLWithPath: PathExpander.home + "/Library")) != .allowed)
        #expect(guardrail.check(URL(fileURLWithPath: PathExpander.home + "/Documents")) != .allowed)
        #expect(guardrail.check(URL(fileURLWithPath: "/System/Library")) != .allowed)
        #expect(guardrail.check(URL(fileURLWithPath: "/Applications/Safari.app")) != .allowed)
    }

    @Test func allowsFilesInsideSandbox() throws {
        let box = try Sandbox()
        let file = try box.file("a/b.txt")
        #expect(SafetyGuard().check(file) == .allowed)
    }

    @Test func respectsProtectedPaths() throws {
        let box = try Sandbox()
        let keep = try box.file("keep/important.txt")
        let guardrail = SafetyGuard(protectedPaths: [box.root.path + "/keep"])
        #expect(guardrail.check(keep) != .allowed)
        // 删除父目录也会连带删除受保护的内容
        #expect(guardrail.check(box.root) != .allowed)
    }

    @Test func rejectsSymlinkEscape() throws {
        let box = try Sandbox()
        // 一个指向 /System 的目录链接：通过它访问的路径解析后在允许范围之外
        let link = box.root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/System/Library")
        let target = link.appendingPathComponent("CoreServices")
        #expect(SafetyGuard().check(target) != .allowed)
        // 链接本身可以删（只删链接，不删目标）
        #expect(SafetyGuard().check(link) == .allowed)
    }
}

@Suite struct SizeTests {
    @Test func countsHardLinksOnce() throws {
        let box = try Sandbox()
        let a = try box.file("d/a.bin", bytes: 100_000)
        try FileManager.default.linkItem(at: a, to: box.root.appendingPathComponent("d/b.bin"))
        let tracker = SharingTracker()
        let info = SizeCalculator.measure(box.root.appendingPathComponent("d"), tracker: tracker)
        #expect(info.fileCount == 1)
        #expect(info.allocated >= 100_000 && info.allocated < 200_000)
    }
}

@Suite struct CloneTests {
    @Test func clonesAreCountedOnceInEstimate() throws {
        let box = try Sandbox()
        let original = try box.file("set/a/data.bin", bytes: 4_000_000)
        try box.dir("set/b")
        let copy = box.root.appendingPathComponent("set/b/data.bin")
        #expect(clonefile(original.path, copy.path, 0) == 0)

        let tracker = SharingTracker()
        var info = SizeCalculator.measure(box.root.appendingPathComponent("set/a"), tracker: tracker)
        info.merge(SizeCalculator.measure(box.root.appendingPathComponent("set/b"), tracker: tracker))
        // 两份都占用 4MB，但数据是同一份：预计释放只算一次，单独删除任何一份都释放不了
        #expect(info.allocated >= 8_000_000)
        #expect(info.estimated >= 4_000_000 && info.estimated < 5_000_000)
        #expect(info.exclusive < 100_000)
    }

    @Test func scannerSpreadsCloneEstimateAcrossItems() async throws {
        let box = try Sandbox()
        let original = try box.file("clones/one/data.bin", bytes: 12_000_000)
        for name in ["two", "three", "four"] {
            try box.dir("clones/\(name)")
            #expect(clonefile(original.path, box.root.appendingPathComponent("clones/\(name)/data.bin").path, 0) == 0)
        }
        let results = await Scanner(rules: [box.rule(paths: ["clones/*"])]).scan(context: emptyContext)
        let result = try #require(results.first)
        #expect(result.items.count == 4)
        #expect(result.totalSize >= 48_000_000)
        #expect(result.reclaimableTotal >= 11_900_000 && result.reclaimableTotal < 13_000_000)
        #expect(result.items.allSatisfy { $0.note?.contains("APFS 克隆") == true })
    }
}

@Suite struct MatcherTests {
    @Test func editorExtensionsKeepsReferencedVersion() throws {
        let box = try Sandbox()
        for v in ["2.1.1", "2.1.2", "2.1.3"] {
            try box.file("ext/anthropic.claude-code-\(v)-darwin-arm64/package.json")
        }
        try box.file("ext/ms-python.python-2024.1.0/package.json")
        let json = #"[{"identifier":{"id":"anthropic.claude-code"},"version":"2.1.2","relativeLocation":"anthropic.claude-code-2.1.2-darwin-arm64"},{"identifier":{"id":"ms-python.python"},"relativeLocation":"ms-python.python-2024.1.0"}]"#
        try json.write(to: box.root.appendingPathComponent("ext/extensions.json"), atomically: true, encoding: .utf8)

        let output = Matchers.run(box.rule(matcher: .editorExtensions, paths: ["ext"]), context: emptyContext)
        let names = Set(output.candidates.map { $0.urls[0].lastPathComponent })
        #expect(names == ["anthropic.claude-code-2.1.1-darwin-arm64", "anthropic.claude-code-2.1.3-darwin-arm64"])
    }

    @Test func monthFoldersGroupAcrossChats() throws {
        let box = try Sandbox()
        try box.file("attach/chatA/2024-10/Img/1.jpg")
        try box.file("attach/chatB/2024-10/Img/2.jpg")
        try box.file("attach/chatB/2024-9/Img/3.jpg")
        try box.file("attach/chatB/notes/x.txt")
        let output = Matchers.run(box.rule(matcher: .monthFolders, paths: ["attach/*"], risk: .manual, action: .trash), context: emptyContext)
        #expect(output.candidates.map(\.title) == ["2024-09", "2024-10"])
        #expect(output.candidates[1].urls.count == 2)
    }

    @Test func oldVersionsKeepNewestPerProduct() throws {
        let box = try Sandbox()
        for name in ["IntelliJIdea2025.2", "IntelliJIdea2025.3", "DataGrip2024.2", "consentOptions"] {
            try box.dir("jb/\(name)")
        }
        let output = Matchers.run(box.rule(matcher: .oldVersions, paths: ["jb/*"]), context: emptyContext)
        #expect(output.candidates.map(\.title) == ["IntelliJIdea2025.2"])
    }

    @Test func oldVersionsKeepNvmDefault() throws {
        let box = try Sandbox()
        for name in ["v18.20.7", "v20.1.0", "v22.22.0"] {
            try box.dir("node/\(name)")
        }
        try "18".write(to: box.root.appendingPathComponent("default"), atomically: true, encoding: .utf8)
        let output = Matchers.run(box.rule(matcher: .oldVersions, paths: ["node/*"], keepAliasFile: "default"), context: emptyContext)
        #expect(output.candidates.map(\.title) == ["v20.1.0"])
    }

    @Test func buildArtifactsRequireMarkersAndRespectActivity() throws {
        let box = try Sandbox()
        let old = Date(timeIntervalSinceNow: -90 * 86400)
        try box.file("old-app/package.json", modified: old)
        try box.file("old-app/node_modules/x/index.js")
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: box.root.appendingPathComponent("old-app").path)
        try box.file("new-app/package.json")
        try box.file("new-app/node_modules/y/index.js")
        // 没有 build.gradle 的 build 目录不算产物
        try box.file("docs/build/index.html")

        let context = ScanContext(running: RunningAppsSnapshot(), projectRoots: [box.root.path])
        let output = Matchers.run(Rule(id: "b", name: "b", category: .developer, risk: .caution, action: .delete, summary: "", paths: [], matcher: .buildArtifacts), context: context)
        let byTitle = Dictionary(uniqueKeysWithValues: output.candidates.map { ($0.title, $0) })
        #expect(Set(byTitle.keys) == ["old-app › node_modules", "new-app › node_modules"])
        #expect(byTitle["old-app › node_modules"]?.preselect == true)
        #expect(byTitle["new-app › node_modules"]?.preselect == false)
    }

    @Test func runningAppUnselectsItems() throws {
        let box = try Sandbox()
        try box.file("cache/data.bin")
        var rule = box.rule(paths: ["cache"])
        rule.appBundleIDs = ["com.example.app"]
        let context = ScanContext(running: RunningAppsSnapshot(bundleIDs: ["com.example.app"], names: ["com.example.app": "Example"]), projectRoots: [])
        let output = Matchers.run(rule, context: context)
        #expect(output.candidates.first?.preselect == false)
    }
}

@Suite struct ScannerTests {
    @Test func laterRulesSkipClaimedPaths() async throws {
        let box = try Sandbox()
        try box.file("caches/chrome/data.bin")
        try box.file("caches/other/data.bin")
        let specific = box.rule("specific", paths: ["caches/chrome"])
        let generic = box.rule("generic", paths: ["caches/*"])
        let results = await Scanner(rules: [specific, generic]).scan(context: emptyContext)
        let genericItems = results.first { $0.rule.id == "generic" }?.items.map(\.title) ?? []
        #expect(genericItems == ["other"])
        #expect(results.first { $0.rule.id == "specific" }?.items.count == 1)
    }
}

@Suite struct CleanerTests {
    func task(_ urls: [URL], action: CleanAction) -> CleanTask {
        let rule = Rule(id: "t", name: "t", category: .system, risk: .safe, action: action, summary: "", paths: [])
        return CleanTask(item: ScanItem(ruleID: "t", title: "t", detail: nil, urls: urls, size: 1, preselected: true), rule: rule, action: action)
    }

    @Test func deletesReadOnlyDirectories() async throws {
        let box = try Sandbox()
        let dir = try box.dir("mod/pkg@v1")
        try box.file("mod/pkg@v1/a.go")
        // 模拟 Go 模块缓存：目录只读
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let journal = Journal(logURL: box.root.appendingPathComponent("log"), historyURL: box.root.appendingPathComponent("history.json"))
        let report = await Cleaner(guardrail: SafetyGuard(), journal: journal).clean([task([box.root.appendingPathComponent("mod")], action: .delete)])
        #expect(report.failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: box.root.appendingPathComponent("mod").path))
    }

    @Test func dryRunDeletesNothing() async throws {
        let box = try Sandbox()
        let file = try box.file("x/y.bin")
        let report = await Cleaner(guardrail: SafetyGuard(), journal: nil).clean([task([file], action: .delete)], dryRun: true)
        #expect(report.cleanedItems == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func protectedPathIsSkipped() async throws {
        let box = try Sandbox()
        let file = try box.file("keep/y.bin")
        let report = await Cleaner(guardrail: SafetyGuard(protectedPaths: [box.root.path + "/keep"]), journal: nil).clean([task([file], action: .delete)])
        #expect(report.failures.count == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}

@Suite struct SystemMetricsTests {
    @Test func secondSampleHasSaneValues() async throws {
        let sampler = SystemSampler()
        _ = await sampler.sample()
        try await Task.sleep(for: .milliseconds(300))
        let snapshot = await sampler.sample()
        let cpu = try #require(snapshot.cpu)
        #expect((0...1).contains(cpu.total))
        #expect(snapshot.memory.total == ProcessInfo.processInfo.physicalMemory)
        #expect(snapshot.memory.used > 0 && snapshot.memory.used <= snapshot.memory.total)
        #expect(snapshot.uptime > 0)
        #expect(snapshot.network != nil)
        // 至少能看到当前测试进程自己
        #expect(snapshot.apps.contains { $0.memory > 0 && $0.processCount > 0 })
    }

    @Test func machineInfoIsPopulated() {
        let machine = MachineInfo.current()
        #expect(!machine.chip.isEmpty)
        #expect(machine.totalCores > 0)
        #expect(machine.memory == ProcessInfo.processInfo.physicalMemory)
        #expect(machine.osVersion.hasPrefix("macOS "))
    }
}

@Suite struct UndeletableTests {
    @Test func protectedTopLevelPathsAreNotOffered() throws {
        let box = try Sandbox()
        try box.file("tmp/normal/a.txt")
        let locked = try box.dir("tmp/locked")
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(locked.path, 0) }
        let output = Matchers.run(box.rule(paths: ["tmp/*"]), context: emptyContext)
        #expect(output.candidates.map(\.title) == ["normal"])
        #expect(SafetyGuard().check(locked) != .allowed)
    }

    @Test func itemsWithLockedFilesAreSkippedInsteadOfHalfDeleted() async throws {
        let box = try Sandbox()
        try box.file("project/node_modules/a/index.js")
        let locked = try box.file("project/node_modules/b/index.js")
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(locked.path, 0) }

        let results = await Scanner(rules: [box.rule(paths: ["project/node_modules"])]).scan(context: emptyContext)
        let item = try #require(results.first?.items.first)
        #expect(item.blockedCount == 1)
        #expect(item.preselected == false)

        let rule = try #require(results.first?.rule)
        let report = await Cleaner(guardrail: SafetyGuard(), journal: nil).clean([CleanTask(item: item, rule: rule, action: .delete)])
        #expect(report.cleanedItems == 0)
        // 一个文件都没动
        #expect(FileManager.default.fileExists(atPath: box.root.appendingPathComponent("project/node_modules/a/index.js").path))
    }
}
