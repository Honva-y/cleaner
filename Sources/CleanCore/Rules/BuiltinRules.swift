import Foundation

/// 内置清理规则。顺序即优先级：同一路径只归属第一条匹配到它的规则，所以具体规则在前、通用规则在后。
public enum BuiltinRules {
    public static let all: [Rule] = anomaly + browser + developer + ai + chat + system + generic

    static let editors = "{.vscode,.vscode-insiders,.vscode-oss,.cursor,.trae,.trae-cn,.windsurf,.kiro,.qoder,.antigravity}"
    static let chromiumCaches = "{Cache,Code Cache,GPUCache,DawnCache,DawnGraphiteCache,DawnWebGPUCache,GrShaderCache,ShaderCache,GraphiteDawnCache}"
    static let wechat = "~/Library/Containers/com.tencent.xinWeChat/Data"
    static let wecom = "~/Library/Containers/com.tencent.WeWorkMac/Data"

    // MARK: 异常残留

    static let anomaly: [Rule] = [
        Rule(
            id: "anomaly.chrome-code-sign-clone",
            name: "Chrome 签名副本残留",
            category: .anomaly, risk: .safe, action: .delete,
            summary: "Chrome 每次启动会在临时目录复制一份自己用于校验签名，异常退出时不会删除，越积越多。正在使用的副本会自动跳过。",
            paths: ["$DARWIN_USER_DIR/X/com.google.Chrome*.code_sign_clone/code_sign_clone.*"],
            matcher: .unusedClones,
            appBundleIDs: ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary"],
            processName: "Google Chrome",
            hint: "副本和 Chrome 本体可能共用磁盘块，实际释放量以清理后的结果为准。"
        ),
        Rule(
            id: "anomaly.editor-extension-versions",
            name: "编辑器扩展旧版本",
            category: .anomaly, risk: .safe, action: .delete,
            summary: "VS Code、Cursor、Trae 等升级扩展后留下的旧版本。只保留 extensions.json 中登记的在用版本。",
            paths: ["~/\(editors)/extensions"],
            matcher: .editorExtensions
        ),
    ]

    // MARK: 浏览器

    static let browser: [Rule] = [
        Rule(
            id: "browser.chrome",
            name: "Chrome 缓存",
            category: .browser, risk: .safe, action: .delete,
            summary: "网页、脚本和显卡着色器缓存，删除后会自动重建。",
            paths: [
                "~/Library/Caches/Google/Chrome",
                "~/Library/Application Support/Google/Chrome/*/\(chromiumCaches)",
                "~/Library/Application Support/Google/Chrome/\(chromiumCaches)",
                "~/Library/Application Support/Google/Chrome/{component_crx_cache,extensions_crx_cache}",
            ],
            appBundleIDs: ["com.google.Chrome"]
        ),
        Rule(
            id: "browser.chrome-service-worker",
            name: "Chrome 网站离线数据",
            category: .browser, risk: .caution, action: .delete,
            summary: "网站通过 Service Worker 缓存的离线资源。删除后部分网站第一次打开会变慢，离线功能需要重新加载。",
            paths: ["~/Library/Application Support/Google/Chrome/*/Service Worker/CacheStorage"],
            appBundleIDs: ["com.google.Chrome"]
        ),
        Rule(
            id: "browser.edge",
            name: "Edge 缓存",
            category: .browser, risk: .safe, action: .delete,
            summary: "Microsoft Edge 的网页缓存。",
            paths: [
                "~/Library/Caches/Microsoft Edge",
                "~/Library/Application Support/Microsoft Edge/*/\(chromiumCaches)",
                "~/Library/Application Support/Microsoft Edge/*/Service Worker/CacheStorage",
            ],
            appBundleIDs: ["com.microsoft.edgemac"]
        ),
        Rule(
            id: "browser.arc",
            name: "Arc 缓存",
            category: .browser, risk: .safe, action: .delete,
            summary: "Arc 浏览器的网页缓存。",
            paths: [
                "~/Library/Caches/Arc",
                "~/Library/Application Support/Arc/User Data/*/\(chromiumCaches)",
                "~/Library/Application Support/Arc/User Data/*/Service Worker/CacheStorage",
            ],
            appBundleIDs: ["company.thebrowser.Browser"]
        ),
        Rule(
            id: "browser.safari",
            name: "Safari 缓存",
            category: .browser, risk: .safe, action: .delete,
            summary: "Safari 的网页缓存。",
            paths: ["~/Library/Caches/com.apple.Safari", "~/Library/Containers/com.apple.Safari/Data/Library/Caches/*"],
            appBundleIDs: ["com.apple.Safari"]
        ),
        Rule(
            id: "browser.firefox",
            name: "Firefox 缓存",
            category: .browser, risk: .safe, action: .delete,
            summary: "Firefox 的网页缓存。",
            paths: ["~/Library/Caches/Firefox/Profiles/*/cache2"],
            appBundleIDs: ["org.mozilla.firefox"]
        ),
    ]

    // MARK: 开发工具

    static let developer: [Rule] = [
        Rule(
            id: "dev.build-artifacts",
            name: "项目构建产物",
            category: .developer, risk: .caution, action: .delete,
            summary: "node_modules、build、target、.next 等，可以重新安装或构建。超过 30 天没改动的项目默认勾选，被 Git 跟踪的目录会跳过。",
            paths: [],
            matcher: .buildArtifacts
        ),
        Rule(
            id: "dev.npm",
            name: "npm / Yarn / pnpm 缓存",
            category: .developer, risk: .safe, action: .delete,
            summary: "包管理器的下载缓存，下次安装时会重新下载。",
            paths: ["~/.npm/{_cacache,_logs,_npx}", "~/Library/Caches/{Yarn,pnpm,node-gyp}", "~/.yarn/berry/cache", "~/.cache/{node,yarn,pnpm}"]
        ),
        Rule(
            id: "dev.gradle-caches",
            name: "Gradle 依赖缓存",
            category: .developer, risk: .caution, action: .delete,
            summary: "Gradle 下载的依赖和构建缓存。删除后下次构建会重新下载，耗时较长。",
            paths: ["~/.gradle/caches"],
            appBundleIDs: ["com.google.android.studio", "com.jetbrains.intellij", "com.jetbrains.intellij.ce"]
        ),
        Rule(
            id: "dev.gradle-wrapper",
            name: "Gradle Wrapper 发行版",
            category: .developer, risk: .caution, action: .delete,
            summary: "各个 Gradle 版本的安装包。项目用到时会重新下载。",
            paths: ["~/.gradle/wrapper/dists/*"],
            exclude: ["*/CACHEDIR.TAG"]
        ),
        Rule(
            id: "dev.gradle-daemon-logs",
            name: "Gradle 守护进程日志",
            category: .developer, risk: .safe, action: .delete,
            summary: "Gradle daemon 的运行日志。",
            paths: ["~/.gradle/daemon/*/*.log"],
            aggregate: true
        ),
        Rule(
            id: "dev.maven",
            name: "Maven 本地仓库",
            category: .developer, risk: .caution, action: .delete,
            summary: "Maven 下载的依赖，删除后下次构建会重新下载。",
            paths: ["~/.m2/repository"]
        ),
        Rule(
            id: "dev.go",
            name: "Go 缓存",
            category: .developer, risk: .caution, action: .delete,
            summary: "Go 编译缓存和模块缓存，删除后会重新编译、重新下载。",
            paths: ["~/Library/Caches/go-build", "~/go/pkg/mod"]
        ),
        Rule(
            id: "dev.cargo",
            name: "Cargo 缓存",
            category: .developer, risk: .caution, action: .delete,
            summary: "Rust crate 的下载缓存和源码。",
            paths: ["~/.cargo/registry/{cache,src}", "~/.cargo/git/checkouts"]
        ),
        Rule(
            id: "dev.python",
            name: "pip / uv 缓存",
            category: .developer, risk: .safe, action: .delete,
            summary: "Python 包的下载缓存。",
            paths: ["~/Library/Caches/{pip,pypoetry,uv}", "~/.cache/{pip,uv}"]
        ),
        Rule(
            id: "dev.homebrew",
            name: "Homebrew 缓存",
            category: .developer, risk: .safe, action: .delete,
            summary: "Homebrew 下载的安装包。",
            paths: ["~/Library/Caches/Homebrew"]
        ),
        Rule(
            id: "dev.cocoapods",
            name: "CocoaPods 缓存",
            category: .developer, risk: .safe, action: .delete,
            summary: "CocoaPods 下载的 Pod 缓存。",
            paths: ["~/Library/Caches/CocoaPods"]
        ),
        Rule(
            id: "dev.xcode-derived",
            name: "Xcode 构建缓存",
            category: .developer, risk: .safe, action: .delete,
            summary: "DerivedData 和模拟器缓存，下次构建会重新生成。",
            paths: ["~/Library/Developer/Xcode/DerivedData/*", "~/Library/Developer/CoreSimulator/Caches/*"],
            appBundleIDs: ["com.apple.dt.Xcode"]
        ),
        Rule(
            id: "dev.xcode-device-support",
            name: "iOS 设备调试支持文件",
            category: .developer, risk: .caution, action: .delete,
            summary: "连接过的 iPhone 各系统版本的调试符号，再次连接时会重新生成。",
            paths: ["~/Library/Developer/Xcode/{iOS,watchOS,tvOS,visionOS} DeviceSupport/*"]
        ),
        Rule(
            id: "dev.simulators",
            name: "iOS 模拟器设备",
            category: .developer, risk: .caution, action: .trash,
            summary: "模拟器设备及其中安装的 App 和数据。",
            paths: ["~/Library/Developer/CoreSimulator/Devices/*"],
            appBundleIDs: ["com.apple.iphonesimulator"]
        ),
        Rule(
            id: "dev.jetbrains-old",
            name: "JetBrains 旧版本缓存与日志",
            category: .developer, risk: .safe, action: .delete,
            summary: "IntelliJ、Android Studio 等升级后，旧版本留下的缓存和日志。每个产品只保留最新版本。",
            paths: [
                "~/Library/Caches/JetBrains/*", "~/Library/Logs/JetBrains/*",
                "~/Library/Caches/Google/AndroidStudio*", "~/Library/Logs/Google/AndroidStudio*",
            ],
            matcher: .oldVersions
        ),
        Rule(
            id: "dev.jetbrains-old-config",
            name: "JetBrains 旧版本配置",
            category: .developer, risk: .caution, action: .trash,
            summary: "旧版本 IDE 的配置和插件。新版本首次启动时已经导入过，一般可以删除。",
            paths: ["~/Library/Application Support/JetBrains/*", "~/Library/Application Support/Google/AndroidStudio*"],
            matcher: .oldVersions
        ),
        Rule(
            id: "dev.nvm",
            name: "nvm 旧版 Node.js",
            category: .developer, risk: .caution, action: .delete,
            summary: "nvm 安装的旧版 Node.js，保留最新版本和默认版本。",
            paths: ["~/.nvm/versions/node/*"],
            matcher: .oldVersions,
            keepAliasFile: "~/.nvm/alias/default"
        ),
        Rule(
            id: "dev.android-cache",
            name: "Android 工具缓存",
            category: .developer, risk: .safe, action: .delete,
            summary: "Android SDK 工具的下载缓存。",
            paths: ["~/.android/cache", "~/.android/build-cache"]
        ),
        Rule(
            id: "dev.docker",
            name: "Docker 虚拟磁盘",
            category: .developer, risk: .manual, action: .reveal,
            summary: "Docker 的镜像、容器和数据卷都在这个虚拟磁盘里，不能直接删除文件。",
            paths: ["~/Library/Containers/com.docker.docker/Data/vms/*/data/Docker.raw"],
            hint: "在 Docker Desktop → 设置 → Resources 中调整，或在终端运行 docker system prune -a 清理不用的镜像。"
        ),
    ]

    // MARK: AI 工具

    static let ai: [Rule] = [
        Rule(
            id: "ai.app-caches",
            name: "AI 应用缓存",
            category: .ai, risk: .safe, action: .delete,
            summary: "Claude、ChatGPT、Codex、Cursor、Trae 等内嵌浏览器的缓存和日志，删除后会自动重建。",
            paths: [
                "~/Library/Application Support/{Claude,ChatGPT,Codex,Cursor,Trae,Trae CN,Windsurf,Kiro,Qoder,QoderCN,Lingma,Doubao}/{\(chromiumCaches.dropFirst().dropLast()),CachedData,CachedExtensionVSIXs,logs}",
                "~/Library/Caches/{com.openai.codex,com.openai.chat,com.anthropic.claudefordesktop,com.todesktop.230313mzl4w4u92,cn.trae.app,com.trae.app}",
            ]
        ),
        Rule(
            id: "ai.codex-archived",
            name: "Codex 已归档会话",
            category: .ai, risk: .caution, action: .trash,
            summary: "Codex 中已经归档的会话记录。",
            paths: ["~/.codex/archived_sessions"]
        ),
        Rule(
            id: "ai.claude-vm",
            name: "Claude 虚拟机镜像",
            category: .ai, risk: .manual, action: .reveal,
            summary: "Claude 桌面版运行代码用的虚拟机镜像，由 Claude 自己管理。",
            paths: ["~/Library/Application Support/Claude/vm_bundles"],
            hint: "删除后 Claude 会重新下载；如果不用相关功能，可以在 Claude 的设置里关闭。"
        ),
        Rule(
            id: "ai.ollama",
            name: "Ollama 本地模型",
            category: .ai, risk: .manual, action: .reveal,
            summary: "Ollama 下载的本地大模型。",
            paths: ["~/.ollama/models"],
            hint: "在终端运行 ollama list 查看，ollama rm <模型名> 删除不用的模型。"
        ),
        Rule(
            id: "ai.lmstudio",
            name: "LM Studio 本地模型",
            category: .ai, risk: .manual, action: .trash,
            summary: "LM Studio 下载的本地大模型。",
            paths: ["~/.lmstudio/models/*/*", "~/.cache/lm-studio/models/*/*"]
        ),
    ]

    // MARK: 聊天软件

    static let wechatHint = "也可以在 微信 → 设置 → 存储空间 中清理。删除后，聊天记录里对应的内容将无法打开。"
    static let wecomHint = "删除后，聊天记录里对应的内容需要重新下载；超过服务器保存期限的将无法打开。"

    static let chat: [Rule] = [
        Rule(
            id: "chat.wechat-cache",
            name: "微信缓存",
            category: .chat, risk: .safe, action: .delete,
            summary: "微信的临时文件和缓存（不含聊天记录和聊天文件）。",
            paths: ["\(wechat)/Documents/xwechat_files/*/{cache,temp}", "\(wechat)/Library/Caches/*"],
            appBundleIDs: ["com.tencent.xinWeChat"]
        ),
        Rule(
            id: "chat.wechat-video",
            name: "微信视频",
            category: .chat, risk: .manual, action: .trash,
            summary: "聊天中收发的视频，按月份列出。",
            paths: ["\(wechat)/Documents/xwechat_files/*/msg/video"],
            matcher: .monthFolders,
            hint: wechatHint
        ),
        Rule(
            id: "chat.wechat-image",
            name: "微信图片",
            category: .chat, risk: .manual, action: .trash,
            summary: "聊天中收发的图片，按月份列出。",
            paths: ["\(wechat)/Documents/xwechat_files/*/msg/attach/*"],
            matcher: .monthFolders,
            hint: wechatHint
        ),
        Rule(
            id: "chat.wechat-file",
            name: "微信文件",
            category: .chat, risk: .manual, action: .trash,
            summary: "聊天中收发的文件，按月份列出。",
            paths: ["\(wechat)/Documents/xwechat_files/*/msg/file"],
            matcher: .monthFolders,
            hint: wechatHint
        ),
        Rule(
            id: "chat.wecom-cache",
            name: "企业微信缓存",
            category: .chat, risk: .safe, action: .delete,
            summary: "内嵌浏览器缓存、表情和缩略图，删除后会自动重新下载。",
            paths: [
                "\(wecom)/Documents/cefcache",
                "\(wecom)/Documents/Profiles/*/Caches/{Emotions,Emotion_Thumbnail,Video_Thumbnail,Link_Thumbnail}",
                "\(wecom)/Library/Caches/*",
            ],
            appBundleIDs: ["com.tencent.WeWorkMac"]
        ),
        Rule(
            id: "chat.wecom-image",
            name: "企业微信图片",
            category: .chat, risk: .manual, action: .trash,
            summary: "聊天中收发的图片，按月份列出。",
            paths: ["\(wecom)/Documents/Profiles/*/Caches/Images"],
            matcher: .monthFolders,
            hint: wecomHint
        ),
        Rule(
            id: "chat.wecom-video",
            name: "企业微信视频",
            category: .chat, risk: .manual, action: .trash,
            summary: "聊天中收发的视频，按月份列出。",
            paths: ["\(wecom)/Documents/Profiles/*/Caches/Videos"],
            matcher: .monthFolders,
            hint: wecomHint
        ),
        Rule(
            id: "chat.wecom-file",
            name: "企业微信文件",
            category: .chat, risk: .manual, action: .trash,
            summary: "聊天中收发的文件，按月份列出。",
            paths: ["\(wecom)/Documents/Profiles/*/Caches/Files"],
            matcher: .monthFolders,
            hint: wecomHint
        ),
        Rule(
            id: "chat.qq-cache",
            name: "QQ 缓存",
            category: .chat, risk: .safe, action: .delete,
            summary: "QQ 的缓存文件。",
            paths: ["~/Library/Containers/com.tencent.qq/Data/Library/Caches/*"],
            appBundleIDs: ["com.tencent.qq"]
        ),
        Rule(
            id: "chat.lark-cache",
            name: "飞书缓存",
            category: .chat, risk: .safe, action: .delete,
            summary: "飞书内嵌浏览器的缓存。",
            paths: ["~/Library/Application Support/LarkShell/{CodeCache,GrShaderCache,GPUCache,Cache}", "~/Library/Caches/com.bytedance.lark*"],
            appBundleIDs: ["com.bytedance.macos.feishu", "com.electron.lark"]
        ),
    ]

    // MARK: 系统垃圾

    static let system: [Rule] = [
        Rule(
            id: "system.trash",
            name: "废纸篓",
            category: .system, risk: .caution, action: .delete,
            summary: "废纸篓里的文件仍然占用空间，清空后才会释放。",
            paths: ["~/.Trash/*", "~/.Trash/.[!.]*"],
            exclude: ["~/.Trash/.DS_Store"],
            aggregate: true
        ),
        Rule(
            id: "system.installers",
            name: "安装包",
            category: .system, risk: .caution, action: .trash,
            summary: "下载和桌面上的 dmg、pkg 等安装包，App 装好后一般就用不上了。",
            paths: ["~/{Downloads,Desktop}/*.{dmg,DMG,pkg,PKG,mpkg,xip,iso}", "~/Library/iTunes/iPhone Software Updates/*.ipsw"]
        ),
        Rule(
            id: "system.crash-reports",
            name: "崩溃报告",
            category: .system, risk: .safe, action: .delete,
            summary: "App 崩溃时生成的诊断报告。",
            paths: ["~/Library/Logs/DiagnosticReports/*"],
            aggregate: true
        ),
        Rule(
            id: "system.logs",
            name: "应用日志",
            category: .system, risk: .safe, action: .delete,
            summary: "各个 App 写的运行日志。",
            paths: ["~/Library/Logs/*"],
            exclude: ["~/Library/Logs/Cleaner", "~/Library/Logs/DiagnosticReports"]
        ),
        Rule(
            id: "system.temp",
            name: "临时文件",
            category: .system, risk: .safe, action: .delete,
            summary: "系统临时目录中超过 3 天没有改动的文件。",
            paths: ["$TMPDIR/*"],
            minAgeDays: 3,
            aggregate: true
        ),
        Rule(
            id: "system.mail-downloads",
            name: "邮件附件下载",
            category: .system, risk: .safe, action: .delete,
            summary: "“邮件”App 打开附件时下载的副本，原件仍在邮件里。",
            paths: ["~/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/*"],
            aggregate: true
        ),
        Rule(
            id: "system.ios-backups",
            name: "iPhone / iPad 备份",
            category: .system, risk: .manual, action: .trash,
            summary: "通过访达备份的 iOS 设备数据。删除前请确认已有其他备份。",
            paths: ["~/Library/Application Support/MobileSync/Backup/*"]
        ),
    ]

    // MARK: 通用（放最后，前面规则认领过的路径会自动跳过）

    static let generic: [Rule] = [
        Rule(
            id: "system.electron-caches",
            name: "应用内嵌浏览器缓存",
            category: .system, risk: .safe, action: .delete,
            summary: "VS Code、飞书、钉钉等基于 Chromium 的 App 的网页缓存，删除后会自动重建。",
            paths: [
                "~/Library/Application Support/*/\(chromiumCaches)",
                "~/Library/Application Support/*/Partitions/*/\(chromiumCaches)",
                "~/Library/Application Support/*/CachedData",
            ]
        ),
        Rule(
            id: "system.container-caches",
            name: "沙盒应用缓存",
            category: .system, risk: .safe, action: .delete,
            summary: "从 App Store 安装的 App 的缓存。",
            paths: ["~/Library/Containers/*/Data/Library/Caches/*"],
            exclude: ["~/Library/Containers/com.apple.*"]
        ),
        Rule(
            id: "system.user-caches",
            name: "应用缓存",
            category: .system, risk: .safe, action: .delete,
            summary: "~/Library/Caches 中各个 App 的缓存，删除后会自动重建。系统组件的缓存不会动。",
            paths: ["~/Library/Caches/*"],
            exclude: [
                "~/Library/Caches/com.apple.*", "~/Library/Caches/CloudKit", "~/Library/Caches/FamilyCircle",
                "~/Library/Caches/com.cleaner.app",
                // IDE 索引缓存删了要重建很久，旧版本已由 JetBrains 规则处理
                "~/Library/Caches/JetBrains", "~/Library/Caches/Google",
            ]
        ),
    ]
}

/// 用户自定义规则：`~/Library/Application Support/Cleaner/rules/*.json`，每个文件是一个规则数组
public enum RuleStore {
    public static let userRulesDirectory = URL(fileURLWithPath: PathExpander.home + "/Library/Application Support/Cleaner/rules")

    public static func loadAll() -> (rules: [Rule], errors: [String]) {
        var rules = BuiltinRules.all
        var errors: [String] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: userRulesDirectory, includingPropertiesForKeys: nil)) ?? []
        let ids = Set(rules.map(\.id))
        for file in files where file.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: file)
                let custom = try JSONDecoder().decode([Rule].self, from: data)
                // 自定义规则放在通用规则之前
                let insertAt = rules.firstIndex { $0.id == BuiltinRules.generic.first?.id } ?? rules.endIndex
                rules.insert(contentsOf: custom.filter { !ids.contains($0.id) }, at: insertAt)
            } catch {
                errors.append("\(file.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return (rules, errors)
    }
}
