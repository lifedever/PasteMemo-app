# AI Agent (MCP) 总开关设计

## 背景

PasteMemo 在 1.6.x 起内置了 MCP service，让 Claude / Codex / Cline 等 AI 工具通过本地 socket 读取剪贴板历史。`MCPSocketServer.shared.start()` 在 `applicationDidFinishLaunching` 里**无条件**启动（`opensource/Sources/App/AppDelegate.swift:84`），用户即使从未安装任何 agent 配置，server 也照样监听。

issue #50 用户反馈："此软件功能丰富，界面操作逻辑很完美，我很喜欢，AI agent 功能是一个好功能…但这个 AI agent 我用不上，能否加个开关关掉 MCP 服务"。

## 目标

1. 加 1 个总开关，关闭后 MCP socket server 完全不监听。
2. **新装用户默认关**（隐私优先 / 按需开启）。
3. **从已有版本升级的老用户默认开**（保持 1.7.x 的现有行为，零打扰）。
4. 关闭时不动用户已经在 Claude / Codex 等本地配置里写入的 MCP server 条目。

## 关键决策

### 状态存储

`mcpEnabled` 存 `UserDefaults`（`@AppStorage`），**不**进 SwiftData。跟项目里所有其它设置（`appearanceMode`、`launchAtLogin`、`mcpAllowSensitive`）走同一套机制。

理由：开关要在 `MCPSocketServer.start()` 调用之前就能读到（启动阶段），同时 migration 判定本身依赖"App Support 目录是否存在"，必须在 SwiftData container 初始化之前跑 —— UserDefaults 零依赖、随时可读。

### 区分新装 vs 升级

**不**引入"上次启动版本号"机制。直接用 App Support 目录存在性判定：

```swift
private static func migrateMCPEnabledIfNeeded() {
    let migrationKey = "mcpEnabled.migrationApplied"
    let ud = UserDefaults.standard
    guard !ud.bool(forKey: migrationKey) else { return }

    let bundleID = Bundle.main.bundleIdentifier ?? "com.lifedever.pastememo"
    let appSupportDir = URL.applicationSupportDirectory.appendingPathComponent(bundleID)
    let isExistingUser = FileManager.default.fileExists(atPath: appSupportDir.path)

    ud.set(isExistingUser, forKey: "mcpEnabled")
    ud.set(true, forKey: migrationKey)
}
```

为什么 App Support 目录是可靠信号：CLAUDE.md "Swift / Apple 开发禁忌 #7" 明确规定所有 SwiftData store 都放在 `<AppSupport>/<bundleID>/` 子目录下。1.7.x 已经按此实施。所以：

- 1.7.x 升级 → 目录已存在 → `mcpEnabled = true` ✅
- 全新安装 → 目录还没创建 → `mcpEnabled = false` ✅
- Dev 版（bundle ID `com.lifedever.pastememo.dev`） → 独立判定 ✅

**调用时机**：migration 必须早于 `PasteMemoApp.sharedModelContainer` 初始化。放在 `PasteMemoApp.init()` 最顶部（`static let sharedModelContainer = …` 触发之前）。一旦 SwiftData 初始化，目录就会被创建，后续判断都会变成"老用户"。

`migrationApplied` 标记保证迁移只跑一次 —— 即使用户后来手动 toggle off + 删除 App Support 目录等极端操作也不会重新被判成"新用户"。

### 启停逻辑

`AppDelegate.swift:84` 改为按 `mcpEnabled` 启停：

```swift
if UserDefaults.standard.bool(forKey: "mcpEnabled") {
    MCPSocketServer.shared.start(container: PasteMemoApp.sharedModelContainer)
}
```

`applicationWillTerminate` 里的 `stop()` 保留无条件调用 —— stop 一个没在跑的 server 是 no-op，不需要 guard。

设置 toggle 改变时主动启停：

```swift
Toggle(L10n.tr("settings.aiAgents.master.toggle"), isOn: $mcpEnabled)
    .onChange(of: mcpEnabled) { _, enabled in
        if enabled {
            MCPSocketServer.shared.start(container: PasteMemoApp.sharedModelContainer)
        } else {
            MCPSocketServer.shared.stop()
        }
    }
```

需要核对 `MCPSocketServer.start()` 是否对重复调用幂等（启动阶段已经跑过 start，用户在设置里关掉再开 → 第二次 start）。如不幂等，在 start 入口加 guard。

### UI 布局

`AIAgentIntegrationView` 顶部新增一个 Section 放总开关，位置：

- 在 `binaryMissing` 警告下面（如果存在）
- 在 `service` 状态上面

```
┌─────────────────────────────────────────┐
│ ⚠ 找不到 pastememo-mcp（如有）          │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│ 启用 AI Agent 集成          [开关]      │
│ 允许 Claude、Codex 等 AI 工具通过 MCP   │
│ 协议读取你的剪贴板历史                  │
└─────────────────────────────────────────┘
   ↓ 开启状态：以下 sections 全部显示
   ↓ 关闭状态：只显示一行灰字"已关闭..."

┌─────────────────────────────────────────┐
│ 服务         ●运行中    ~/...mcp.sock   │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│ Agents                                  │
│   Claude     [✓已安装]                  │
│   Codex      [手动配置]                 │
│   …                                     │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│ 隐私                                    │
│   □ 允许读取敏感内容                    │
└─────────────────────────────────────────┘
┌─────────────────────────────────────────┐
│ 来源 App 黑名单                         │
└─────────────────────────────────────────┘
```

关闭时下方所有 sections 隐藏（不是禁用 —— 减少视觉噪音），仅显示一行 placeholder：

```
┌─────────────────────────────────────────┐
│ 已关闭。开启后可让 AI Agent 通过 MCP    │
│ 协议访问你的剪贴板历史。                │
└─────────────────────────────────────────┘
```

### 本地化新 key

加在 `opensource/Sources/Localization/*.lproj/Localizable.strings` 已有的 `settings.aiAgents.*` 区域：

| Key | zh-Hans | en |
|---|---|---|
| `settings.aiAgents.master` | 总开关 | Master switch |
| `settings.aiAgents.master.toggle` | 启用 AI Agent 集成 | Enable AI Agent integration |
| `settings.aiAgents.master.detail` | 允许 Claude、Codex 等 AI 工具通过 MCP 协议读取你的剪贴板历史 | Allow AI tools like Claude and Codex to read your clipboard history via MCP |
| `settings.aiAgents.master.disabledHint` | 已关闭。开启后可让 AI Agent 通过 MCP 协议访问你的剪贴板历史。 | Disabled. Turn on to let AI agents access your clipboard via MCP. |

按 CLAUDE.md 规则 #4，所有 `.lproj` 目录都要补全，不能只更新中英两个。

## 不做的事

1. **不**自动卸载 Claude / Codex / Cline 等本地已写入的 MCP server 配置。用户主动卸载走原 uninstall 按钮（关闭总开关后 agents section 隐藏，但只要再开回来就能继续 uninstall）。
2. **不**清理 `~/Library/Application Support/<bundleID>/mcp.sock` —— `MCPSocketServer.stop()` 已经处理。
3. **不**移除 AI Agent 设置 tab。隐藏 tab 反而让用户找不到入口再打开。
4. **不**触发任何"已为你关闭 AI Agent"之类的弹窗 —— 老用户升级保持开，根本不需要通知；新用户没用过也不需要通知。
5. **不**做"按需启动"（懒启动）—— 显式开关比隐式行为对用户预期更清楚。

## 改动文件清单

- `opensource/Sources/App/PasteMemoApp.swift` — 加 `migrateMCPEnabledIfNeeded()`，在 `init()` 最顶部调用
- `opensource/Sources/App/AppDelegate.swift` — `start()` 加 `mcpEnabled` 条件
- `opensource/Sources/Views/Settings/AIAgentIntegrationView.swift` — 顶部 Section + 条件渲染
- `opensource/Sources/Bridge/MCPSocketServer.swift` — `start()` 加幂等 guard（如果还没有）
- `opensource/Sources/Localization/*.lproj/Localizable.strings` — 4 个新 key × 所有语言

## 验收

1. 全新安装 1.x.x（带本特性）：启动后 AI Agent tab 顶部开关是关闭状态，下面 sections 不可见。`lsof -U | grep mcp.sock` 看不到 socket 监听。
2. 从 1.7.x 升级到 1.x.x：启动后 AI Agent tab 顶部开关是**开启**状态，下面 sections 正常显示。`lsof -U | grep mcp.sock` 能看到 socket 监听。已安装的 Claude/Codex agent 配置仍能正常连接。
3. 手动 toggle off：socket 立即停止监听；已连接的 agent 后续请求失败（连接被拒）。
4. 手动 toggle on：socket 重新监听；agent 重新可以连接。
5. Toggle off → 关闭 PasteMemo → 重新启动：MCP service 不启动。
6. Dev 版独立判定，与正式版互不影响。

## 风险与回退

- 主要风险：迁移判定时机错误（在 SwiftData container 已初始化后才跑），会让全新安装也被判成老用户 → 开关错误地默认开。**缓解**：单元测试 + 验收 case 1。
- 回退方案：如果出现问题，下个 patch 把 `AppDelegate.swift` 的条件改回无条件 `start()`，UI 上保留开关但不再生效（仅控制设置展示）。
