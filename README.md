# Cleaner

macOS 存储清理工具，面向开发者和国内用户。核心目标：**找到真正占空间的东西，并且安全地删掉**。

方案和路线图见 [docs/PLAN.md](docs/PLAN.md)。

## 功能（v0.1）

| 分类 | 内容 |
|---|---|
| 异常残留 | Chrome 签名副本残留（自动跳过正在使用的副本）、VS Code / Cursor / Trae 等编辑器扩展旧版本 |
| 系统垃圾 | 应用缓存、日志、崩溃报告、临时文件、安装包、废纸篓、邮件附件、iOS 备份 |
| 浏览器 | Chrome / Edge / Arc / Safari / Firefox 缓存，Chrome 网站离线数据 |
| 开发工具 | 项目构建产物（node_modules、build、target、.next、.venv…）、npm / Gradle / Maven / Go / Cargo / pip 缓存、Xcode、模拟器、JetBrains 旧版本、nvm 旧版 Node、Docker（只展示） |
| AI 工具 | Claude / ChatGPT / Codex / Cursor / Trae 等缓存、Codex 归档会话、本地模型（只展示） |
| 聊天软件 | 微信、企业微信、QQ、飞书缓存；微信 / 企业微信的视频、图片、文件按月份列出 |

### 设备状态（概览页）

- 机型、芯片、核心数、内存、系统版本、已运行时长、温度状态
- CPU 占用（用户 / 系统、负载、2 分钟曲线）
- 内存占用（App / 联动 / 压缩，和活动监视器口径一致）、内存压力、交换空间
- 网速（只统计 en* 物理网卡）和 2 分钟下载曲线
- 电池电量、充电状态、健康度、循环次数、温度
- “占用排行”：按 App 汇总内存和 CPU（Chrome 的几十个辅助进程会算到 Chrome 名下）
- 内存压力高时点名占用最多的 App；交换文件占磁盘较多时提示重启可释放

每 2 秒采样一次，只在概览页显示时运行。

### 安全机制

- **扫描只读**，清理前弹出完整清单逐项确认。
- **三级风险**：安全（默认勾选）/ 谨慎（默认不勾）/ 手动（个人数据，只能逐项选择，一律移到废纸篓）。
- 可重新生成的缓存直接删除，其余移到废纸篓；设置里可以改成全部移到废纸篓。
- 删除前逐个路径校验：只允许删用户目录和用户临时目录下的内容、拒绝系统目录和顶层目录、防止符号链接逃逸、跳过保护清单。
- 正在运行的 App 的缓存默认不勾选；Chrome 副本通过 `lsof` 检测占用。
- 被 Git 跟踪的构建目录会跳过；近 30 天有改动的项目、Python 虚拟环境默认不勾选。
- 受系统完整性保护（SIP）或带不可删除标志的路径不会出现在列表里；包含其他用户（如 `sudo` 创建）文件的项默认不勾选，清理时整项跳过，避免只删一半。
- 每一步删除记录在 `~/Library/Logs/Cleaner/operations.log`，每次清理的汇总在“清理记录”里。

### 大小统计

- **占用**：`st_blocks × 512`，和 `du`、访达一致；稀疏文件（如 Docker.raw）按实际占用计算。
- **预计释放**：同一份 APFS 克隆数据只算一次（`ATTR_CMNEXT_CLONEID`）。例如 35 份 Chrome 副本占用 78 GB，但它们共用同一份数据，预计释放只有约 2 GB。
- 清理完成后，用磁盘可用空间的前后差值报告实际释放了多少。

## 构建与运行

只需要 Command Line Tools（不需要 Xcode），macOS 14+。

```bash
scripts/build-app.sh --open
```

生成的 App 在 `build/Cleaner.app`。启动台只显示“应用程序”文件夹里的 App，加 `--install` 会在构建后复制到 `/Applications`：

```bash
scripts/build-app.sh --install --open
```

首次使用请先在 **系统设置 → 隐私与安全性 → 完全磁盘访问** 中添加 Cleaner，然后重新打开。否则扫描到微信等 App 的数据时系统会弹窗询问，扫描会暂停等待；废纸篓、Safari、邮件也无法扫描。

> 打包脚本默认用本机的代码签名证书 `SnapLite Dev` 签名，可以用 `CODESIGN_IDENTITY="证书名"` 换成别的证书（`security find-identity -v -p codesigning` 查看可用证书）。用固定证书签名时，重新构建后授权仍然有效；找不到证书会退回 ad-hoc 签名，每次重新构建都要重新授权。

### 其他命令

```bash
# 不打开界面，只扫描并打印结果（不会删除任何文件）；加 --all 打印每条规则的全部项目
swift run -c release Cleaner --scan

# 打印一次设备状态
swift run -c release Cleaner --metrics

# 运行单元测试
scripts/test.sh

# 开发用：自动扫描并把每个页面截图保存到目录，然后退出（不会执行清理）
.build/release/Cleaner --snapshot /tmp/cleaner-shots
```

## 自定义规则

在 `~/Library/Application Support/Cleaner/rules/` 下放 JSON 文件，每个文件是一个规则数组，下次扫描时生效：

```json
[
  {
    "id": "my.app-cache",
    "name": "某 App 缓存",
    "category": "system",
    "risk": "safe",
    "action": "delete",
    "summary": "说明文字",
    "paths": ["~/Library/Application Support/SomeApp/Cache"],
    "appBundleIDs": ["com.example.someapp"]
  }
]
```

| 字段 | 说明 |
|---|---|
| `category` | `anomaly` / `system` / `browser` / `developer` / `ai` / `chat` |
| `risk` | `safe` / `caution` / `manual` |
| `action` | `delete` / `trash` / `reveal`（只展示） |
| `paths` | glob，支持 `~`、`$TMPDIR`、`{a,b}` |
| `matcher` | 默认 `glob`；另有 `monthFolders`（按 YYYY-MM 子目录聚合）、`oldVersions`（只保留最新版本）、`editorExtensions` |
| 可选 | `exclude`、`minAgeDays`、`appBundleIDs`、`aggregate`、`hint` |

## 工程结构

```
Sources/
├─ CleanCore/          核心库，不依赖 UI
│  ├─ Model/           规则、扫描结果
│  ├─ Rules/           内置规则 + 自定义规则加载
│  ├─ Scanner/         路径展开、匹配器、大小统计（fts + APFS 克隆识别）
│  ├─ Safety/          删除前校验、运行中 App 检测、权限检测
│  ├─ System/          设备状态采样（CPU、内存、网络、电池、进程）
│  ├─ Executor/        删除 / 移到废纸篓
│  └─ Journal/         操作日志、清理记录
└─ Cleaner/            SwiftUI 界面
Tests/CleanCoreTests/  单元测试（全部在临时目录里运行）
scripts/               打包、测试、图标生成
```
