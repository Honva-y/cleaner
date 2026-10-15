# Cleaner 方案 v0.2

> v0.2（2026-10-15）：App 定名 Cleaner；确定直接做 GUI；v0.1 已实现，见第 5 节。根据实测修正了 Chrome 副本的可释放量（APFS 克隆）。
>
> 一款面向开发者和国内用户的 macOS 存储清理工具。参考 [Mole](https://mole.fit/zh/)（[CLI 开源](https://github.com/tw93/Mole)），核心目标是**找到真正占空间的东西，并且安全地删掉**。

---

## 1. 现状：这台 Mac 的空间去哪了（2026-10-14 实测）

数据卷 460G，已用 388G，**剩 12G（97%）**。

| 位置 | 大小 | 是什么 | 能否清理 |
|---|---|---|---|
| `/private/var/folders/.../X/com.google.Chrome.code_sign_clone` | 占用 **78G**（36 份副本），实际可释放约 **2.4G** | Chrome 异常退出后留下的 App 签名克隆，9/28–10/6 累积 | 可清。正在用的是**最旧**那份（Chrome 9/28 启动至今），必须按占用检测而不是“保留最新”。35 份副本互为 APFS 克隆、共用同一份数据，全删也只能释放约一份的大小 |
| 微信 `xwechat_files` | 31G | 聊天文件、图片、视频 | 手动挑选 |
| VS Code 扩展 `~/.vscode/extensions` | 19G | `claude-code` 扩展堆了 **67 个版本**，只有 2.1.299 在用 | 可清约 18G |
| Docker `Docker.raw` | 逻辑 60G / 实占约 17G | 虚拟磁盘（稀疏文件） | 用 docker 命令清，不直接删文件 |
| 企业微信 Profiles + cefcache | 11G + 2.3G | 聊天文件 / 内嵌浏览器缓存 | 缓存可清，文件手动 |
| `~/Library/Caches` | 12G | 各应用缓存 | 大部分可清 |
| Chrome Profile | 9.7G | 浏览器数据 | 只清缓存部分 |
| Claude `vm_bundles` | 9G | AI 工具虚拟机镜像 | 手动 |
| `.gradle` 6.2G / `.m2` 5.3G / `go` 4.6G / `.npm` 2.1G / `.nvm` 1.9G / CoreSimulator 5.1G | 约 25G | 依赖缓存、模拟器 | 可重新下载，按需清 |
| 项目构建产物（node_modules、build、.next、target） | 5G+ | 可重新构建 | 按项目活跃度清 |
| 飞书、JetBrains、Cursor、Trae、Code 等 Application Support | 约 20G | 应用数据 | 只清缓存部分 |

**结论**——空间主要被三类东西占掉，传统"系统垃圾清理"只能解决很小一部分：

1. **异常残留**（扩展旧版本 19G、Chrome 克隆实际约 2G）：通用清理工具基本覆盖不到。
2. **国内 IM 的聊天文件**（微信 + 企业微信）：约 45G，需要按类型、时间分析后再挑。
3. **开发者缓存与构建产物**：约 30G。

这三类就是 Cleaner 的差异化方向。

---

## 2. 产品定位与安全原则

**定位**：开发者 + 国内用户的 Mac 存储管家。不做"加速""内存释放"这类功能，只解决存储问题。

**安全原则（不可妥协）**

1. **先扫、再看、后删**：所有清理都能先预览（dry-run）。
2. **默认移到废纸篓**；只有明确可重建的缓存才允许直接删除（可配置）。
3. **三级风险**
   - 🟢 安全：缓存、日志、临时文件。默认勾选。
   - 🟡 谨慎：构建产物、旧版本、安装包、下载文件。默认不勾，附说明。
   - 🔴 手动：聊天文件、设备备份、虚拟机。只展示大小，提供"在访达中显示"和 App 内清理入口，不提供一键删除。
4. 不碰 SIP 保护的系统目录；不以 root 运行；少数系统级任务单独授权。
5. 目标 App 正在运行时，跳过其缓存或提示先退出。
6. 保护清单（白名单）+ 操作日志 + 清理历史，所有操作可追溯。
7. 全部本地处理，不上传任何数据。

---

## 3. 功能规划

### 3.1 功能总表

| 模块 | Mole 是否有 | Cleaner | 优先级 |
|---|---|---|---|
| 智能扫描（首页一键扫） | 有 | 有 | P0 |
| 系统垃圾 + 安装包清理 | 有 | 有 | P0 |
| 开发者清理（包缓存、构建产物） | 有（purge） | 有，并增加多版本检测 | P0 |
| **异常残留检测** | 文档未提及 | 差异化 | P0 |
| 磁盘分析 | 有 | 有，并增加大文件、重复文件、旧文件 | P1 |
| AI 工具清理 | 有 | 有 | P1 |
| **国内 App 专项** | 文档未提及 | 差异化 | P2 |
| 应用卸载 + 残留 | 有 | 有 | P2 |
| **空间增长监控** | 文档未提及 | 差异化 | P2 |
| 系统优化（DNS、Spotlight 等） | 有 | 不做 | — |
| 系统状态（CPU、风扇、电池） | 有 | 不做，与存储无关 | — |

### 3.2 模块详情

#### ① 智能扫描（首页）
一次跑完全部规则，按可释放空间排序，显示总量和三档风险分组。"一键清理"只处理 🟢。

#### ② 系统垃圾
- 用户缓存 `~/Library/Caches/*`（跳过运行中的 App 和保护清单）
- 日志与崩溃报告：`~/Library/Logs`、`DiagnosticReports`
- `$TMPDIR` 中超过 N 天的临时文件
- 废纸篓（展示大小，清空需二次确认）
- 安装包：下载、桌面中的 `.dmg/.pkg/.xip/.iso`；对应 App 已安装的标记"已安装，可删"
- 旧 macOS 安装器、`/Library/Updates`（需管理员）
- 浏览器缓存：Chrome、Edge、Safari、Arc 的 Cache、Code Cache、GPUCache（不碰 Cookies 和历史记录）

#### ③ 开发者清理
- **包管理器缓存**：npm/pnpm/yarn、Gradle（caches、wrapper dists）、Maven、Go（mod、build cache）、pip/uv、Cargo、CocoaPods、Homebrew。优先调用官方命令（`npm cache clean --force`、`go clean -modcache`、`brew cleanup`），没有官方命令再删目录。
- **项目构建产物**：扫描配置的项目根目录（默认 `~/git-project`、`~/AndroidStudioProjects` 等），识别 `node_modules`、`build`、`target`、`.next`、`dist`、`.gradle`、`DerivedData`、`.dart_tool`、`Pods`。按项目最近修改时间排序，近 30 天活跃的默认不勾；Git 跟踪的文件一律不删。
- **多版本残留**（差异化）：
  - VS Code / Cursor / Trae 扩展旧版本（对照 `extensions.json`，只保留在用版本）
  - nvm 中不再使用的 Node 版本
  - JetBrains 旧版本的配置和缓存目录
  - Android SDK 旧的 system-images、build-tools
  - 不可用的 iOS 模拟器（`xcrun simctl delete unavailable`）
- **Docker**：展示 `docker system df`，调用 `docker system prune` / `docker builder prune`；不直接删 `Docker.raw`。

#### ④ AI 工具清理
覆盖 Claude、Claude Code、Codex、Cursor、Trae、通义灵码、豆包、元宝等：
- 缓存：🟢 默认勾选
- 旧版本、旧会话、残留 worktree：🟡 需确认
- VM 镜像：🔴 手动
- Ollama、LM Studio 本地模型：按最后使用时间列出，由工具自身命令删除

#### ⑤ 国内 App 专项（差异化）
覆盖微信、企业微信、飞书、QQ、钉钉、腾讯会议、QQ 音乐、网易云音乐：
- **缓存类**（cefcache、缩略图、WebKit、日志）：🟡 可清
- **聊天文件**：🔴 按类型（视频、图片、文件、语音）、按月份、按大小统计，可预览、可在访达中显示。删除前提示"删除后聊天里将无法打开"，同时给出 App 内官方清理入口。
- 只按目录结构分析，**不解密聊天数据库**，因此不显示"按联系人"的名称。
- 各 App 的目录结构随版本变化，需要逐个调研，规则跟随版本更新。

#### ⑥ 磁盘分析
- Treemap 或旭日图逐层下钻，显示**实际占用**（allocated size），对稀疏文件、硬链接、APFS 克隆做标注
- 大文件列表（默认 > 500MB）、旧文件（超过 1 年未打开）、重复文件（先比大小，再比部分哈希，最后全量哈希）
- 右键：在访达中显示 / 移到废纸篓 / 加入保护清单

#### ⑦ 异常残留检测（差异化）
用规则识别"不该这么大"的目录，每条规则附原因说明：
- Chrome `code_sign_clone` 残留
- 扩展、更新器的多版本堆积
- 临时目录异常膨胀
- 单个日志文件超过 1G
- iOS 设备备份、旧 macOS 安装器

#### ⑧ 应用卸载（P2）
- 拖拽或从列表卸载
- 按 bundle id 和名称匹配 `~/Library` 下的 Application Support、Caches、Containers、Group Containers、Preferences、LaunchAgents、Saved Application State
- 不确定的项默认不勾
- "孤儿残留"扫描：App 已删除但数据还在

#### ⑨ 空间监控（P2）
- 菜单栏显示剩余空间，低于阈值时提醒
- 每天记录主要目录的大小，生成"本周谁涨了"报告。Chrome 克隆这类问题可以在刚开始膨胀时就被发现。

### 3.3 明确不做
内存释放、"一键加速"、系统文件瘦身、杀毒。它们要么与存储无关，要么风险大于收益。

---

## 4. 技术方案

### 4.1 选型
- **Swift 6 + SwiftUI**：原生、体积小，可直接调用 macOS API（废纸篓、文件属性、运行中 App、特权 helper）。
- **三层结构**：核心库 + CLI + GUI，核心逻辑只写一次。
- **本机环境**：目前只有 Command Line Tools（Swift 6.0.2），没有 Xcode。P0 的核心库和 CLI 用 SwiftPM 就能构建；做 GUI 时建议安装 Xcode（SwiftUI 预览、签名、打包）。

### 4.2 工程结构
```
cleanMan/
├─ Package.swift
├─ Sources/
│  ├─ CleanCore/          # 核心库，不依赖 UI
│  │  ├─ Model/           # 规则、扫描结果
│  │  ├─ Rules/           # 内置规则 + 用户 JSON 规则加载
│  │  ├─ Scanner/         # 路径展开、匹配器、fts 大小统计、APFS 克隆识别
│  │  ├─ Safety/          # 删除前校验、运行中 App / 文件占用检测、权限检测
│  │  ├─ Executor/        # 移到废纸篓 / 删除
│  │  └─ Journal/         # 操作日志、清理记录
│  └─ Cleaner/            # SwiftUI 主窗口（--scan 无界面扫描，--snapshot 开发截图）
├─ Tests/CleanCoreTests/  # 单元测试，全部在临时目录中运行
└─ scripts/               # build-app.sh 打包、test.sh 测试、make-icon.swift 图标
```

### 4.3 规则引擎（核心设计）
清理项不写死在代码里，而是用声明式规则描述。支持一个新 App，只需加一段 JSON：

```json
{
  "id": "vscode.extensions.old-versions",
  "name": "VS Code 扩展旧版本",
  "category": "developer",
  "risk": "caution",
  "paths": ["~/.vscode/extensions/*"],
  "matcher": "extension-old-versions",
  "conditions": { "appNotRunning": "com.microsoft.VSCode" },
  "action": "trash",
  "description": "VS Code 升级扩展后没有删除旧版本；只保留 extensions.json 中登记的版本。"
}
```

- `matcher`：默认 glob，另有内置特殊匹配器（多版本、构建产物、安装包、克隆残留）
- `conditions`：最近修改时间、App 未运行、大小阈值
- `action`：`trash` / `delete` / `command`（如 `docker system prune -f`）/ `reveal`（只在访达中打开）

### 4.4 关键技术点

| 问题 | 方案 |
|---|---|
| 扫描速度 | Swift Concurrency 并发遍历，配合 `getattrlistbulk` 批量读属性；目录大小缓存，增量刷新 |
| 大小算不准 | 用 `st_blocks × 512` 统计实占，稀疏文件不虚报（Docker.raw 60G 实占 17G）；硬链接按 inode 去重；APFS 克隆用 `ATTR_CMNEXT_CLONEID` 去重得到“预计释放”，`ATTR_CMNEXT_PRIVATESIZE` 得到“删除后一定释放”的下限；清理后用卷可用空间的差值报告实际释放量 |
| 权限 | 引导开启"完全磁盘访问"。未授权时，读取微信等其他 App 的容器会触发系统弹窗，扫描线程会阻塞等待用户点击，所以要先授权再扫描；系统级任务以后用 `SMAppService` 特权 helper |
| 删除安全 | `FileManager.trashItem` 移到废纸篓；删除前再次校验：路径在规则允许范围内、没有符号链接逃逸、不在保护清单中 |
| 运行中 App 检测 | `NSWorkspace.runningApplications` 按 bundle id 判断 |
| 分发 | 无法上架 App Store（沙盒不允许访问其他 App 的数据）。走 Developer ID 签名 + 公证，用 DMG 或 Homebrew 分发 |

---

## 5. 里程碑

用户决定直接做 GUI，原 P0（CLI）和 P1（GUI）合并。

| 阶段 | 内容 | 状态 |
|---|---|---|
| **v0.1** | CleanCore 规则引擎 + 52 条内置规则；SwiftUI 主界面（概览、6 个分类、确认清单、清理结果、清理记录、设置）；安全校验、废纸篓、操作日志；APFS 克隆感知的大小统计；17 个单元测试 | ✅ 已完成 |
| **v0.1.1** | 概览页设备状态：CPU、内存、网络、电池、按 App 汇总的占用排行；交换文件占用提示；扫描时识别 SIP 保护和他人所有的文件，避免删一半 | ✅ 已完成 |
| **v0.2** | 磁盘分析（Treemap 逐层下钻）、大文件 / 重复文件 / 旧文件；扫描提速（`getattrlistbulk`）；首次启动的权限引导 | 待做 |
| **v0.3** | 应用卸载 + 残留、孤儿残留扫描；菜单栏剩余空间与低空间提醒；“本周谁涨了”空间增长报告 | 待做 |
| **v1.0** | Developer ID 签名公证、Sparkle 自动更新、规则在线更新 | 待做 |

## 6. 待确认

1. **自用还是发布**：决定是否需要 Developer ID 签名公证、多语言、规则在线更新。
2. **是否安装 Xcode**：目前用 Command Line Tools 就能构建和测试；做 SwiftUI 预览、正式签名时需要。
