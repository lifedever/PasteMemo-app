# 粘贴板条目「另存为」技术实现说明（tech_save_as）

## 1. 目标与实现原则

本次技术实现围绕一个核心点：**以单一 Presenter 统一导出逻辑，再把入口分发到各 UI 层**。

原则：

1. 业务逻辑集中：避免在多个 View 里重复写 `NSSavePanel`/`NSOpenPanel`。
2. 行为一致：不同入口触发的保存流程完全一致。
3. 最小侵入：尽量只在 action 分发层与菜单层新增分支。
4. 可扩展：后续支持批量、模板命名时，只改 Presenter 主流程。

---

## 2. 代码变更总览

## 2.1 新增文件

- `Sources/Engine/ClipItemSaveToFilePresenter.swift`

职责：

- 判断条目是否可保存。
- 根据条目类型选择保存策略。
- 统一弹出保存面板。
- 执行文件复制/写入。
- 统一 toast 成功失败反馈。

## 2.2 修改文件

- `Sources/Views/QuickPanel/CommandPaletteView.swift`
  - `CommandAction` 增加 `.saveAsFile`
  - 图标、文案、快捷键 `U`、keyCode `32` 映射
  - actions 列表插入 saveAs 条目
- `Sources/Views/QuickPanel/QuickPanelView.swift`
  - `handleCommandAction` 增加 `.saveAsFile`
  - 右键菜单新增“另存为”
  - `searchBar` 搜索框右侧新增仅图标按钮
- `Sources/Views/Main/MainWindowView.swift`
  - `handleMainCommandAction` 增加 `.saveAsFile`
  - 列表右键菜单新增“另存为”（单选）
- `Sources/Views/Main/ClipDetailView.swift`
  - 详情操作栏新增“另存为”按钮
- `Sources/Views/QuickPanel/QuickPreviewPane.swift`
  - 移除底部“另存为”按钮（入口迁移到搜索框右侧）
- `Sources/Localization/*/Localizable.strings`
  - 新增/更新 `cmd.saveAsFile` 与 `saveAs.*` 文案

---

## 3. Presenter 详细设计

文件：`Sources/Engine/ClipItemSaveToFilePresenter.swift`

## 3.1 入口函数

- `canSaveAsFile(_ item: ClipItem) -> Bool`
  - 判定逻辑：
    1. 非删除对象。
    2. 有可访问路径，或有图片字节，或有非空文本内容。
    3. 过滤 `"[Image]"` 但无图片字节的伪可导出状态。

- `beginSave(_ item: ClipItem)`
  - 主流程分发：
    1. 多路径 -> 目录导出
    2. 单路径 -> 单文件另存复制
    3. 图片优先导出 -> 二进制图片写盘
    4. 其他 -> 文本写盘

---

## 3.2 路径收敛

- `resolvedExistingPaths(for:)`
  - 汇总来源：
    - `item.content` 中文件型内容
    - `item.resolvedFilePaths`
  - 处理：trim、去重、仅保留磁盘存在路径。

---

## 3.3 保存分支实现

### A. 单文件复制另存

- 函数：`presentSaveCopy(ofFileAt:item:)`
- 面板：`NSSavePanel`
- 行为：
  - 默认文件名按统一命名规则生成。
  - 允许目录创建。
  - 目标存在时先删除再复制（`copyFileReplacing`）。

### B. 多文件导出到目录

- 函数：`presentChooseFolderAndCopy(paths:)`
- 面板：`NSOpenPanel`（目录选择模式）
- 行为：
  - 遍历复制全部文件。
  - 目标同名文件调用 `uniqueDestinationURL` 自动避让。
  - 根据结果 toast：全成功 / 部分成功 / 失败。

### C. 图片保存

- 函数：`presentSaveImage(data:item:)`
- 扩展名识别：`imageFileExtension(for:)`
- 写盘：`Data.write(options: .atomic)`

### D. 文本/代码保存

- 函数：`presentSaveText(_:)`
- 扩展名：
  - 代码 -> `resolvedFileExtension`
  - 非代码 -> `txt`
- 编码：UTF-8

---

## 4. 默认文件名规则实现

函数：`defaultFileName(for item: ClipItem, ext: String) -> String`

实现逻辑：

1. 取 `item.itemID`。
2. 按 `-` 最多分割一次，取第一段作为短 ID。
3. 拼接：`pastememo_<shortID>.<ext>`。

示例代码语义：

- 输入：`AABBCCDD-1122-3344-...` + `txt`
- 输出：`pastememo_AABBCCDD.txt`

---

## 5. UI 接入点

## 5.1 Quick Panel

### 5.1.1 搜索栏图标按钮

- 位置：`QuickPanelView.searchBar` 的 `TextField` 后。
- 展示条件：`if let item = currentItem, ClipItemSaveToFilePresenter.canSaveAsFile(item)`。
- 样式：纯图标按钮，无文本，tooltip 显示 `cmd.saveAsFile`。

### 5.1.2 命令面板

- `CommandAction` 新增 `.saveAsFile`。
- 快捷键映射：
  - `shortcutKey = "U"`
  - `keyCode = 32`
- 执行：`handleCommandAction(.saveAsFile)` -> `ClipItemSaveToFilePresenter.beginSave(item)`。

### 5.1.3 右键菜单

- 单选条目菜单新增“另存为”。
- 多选不展示（避免导出策略歧义）。

## 5.2 Main Window

### 5.2.1 条目详情工具栏

- 在复制按钮后、编辑按钮前新增 `saveAsFileButton`。
- 调用 Presenter `beginSave`。

### 5.2.2 历史列表右键菜单

- 单选场景插入“另存为”。

---

## 6. 国际化改动

## 6.1 新增 keys

- `cmd.saveAsFile`
- `saveAs.save`
- `saveAs.chooseFolderPrompt`
- `saveAs.chooseFolderMessage`
- `saveAs.saved`
- `saveAs.failed`
- `saveAs.exportedCount`
- `saveAs.exportedPartial`

## 6.2 文案调整

- `cmd.saveAsFile` 统一语义为“另存为”/“Save As…”（不再强调“文件”）。

---

## 7. 错误处理与用户反馈

1. 用户取消保存面板 -> 直接 return。
2. 复制/写入失败 -> `saveAs.failed` toast。
3. 多文件部分失败 -> `saveAs.exportedPartial` toast。
4. 成功 -> `saveAs.saved` 或 `saveAs.exportedCount` toast。

图标策略：

- 成功：`ToastIcon.success`
- 状态/失败：`ToastIcon.info`（与现有 toast 体系对齐）

---

## 8. 兼容性与风险

## 8.1 兼容性

- macOS 平台能力均为 AppKit 标准组件（`NSSavePanel`/`NSOpenPanel`）。
- 不依赖额外第三方库。

## 8.2 潜在风险

1. 大文件复制耗时：当前同步执行，极端情况下可能短暂阻塞。
2. 文件权限限制：目标目录不可写时会失败 toast。
3. 复杂内容类型（mixed）后续扩展策略未开放。

---

## 9. 验证记录

本轮已执行并通过：

- `swift build`
- `swift test`
- 改名与 UI 调整后再次 `swift build`

建议回归：

1. 11 语言切换后 tooltip/菜单文案检查。
2. 图片/文本/代码/文件路径各类型保存一次。
3. 快捷面板 `U` 键与既有按键行为冲突检查。

---

## 10. 后续可演进点

1. 另存为支持批量策略（按条目循环弹窗 / 一次性目录导出）。
2. 增加用户可配置命名模板（例如 `${date}` `${sourceApp}`）。
3. 记忆上次导出目录，减少重复选目录成本。
4. 导出后快捷动作（Reveal in Finder）。
