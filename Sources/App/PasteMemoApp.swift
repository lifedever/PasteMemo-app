import SwiftUI
import SwiftData
import AppKit

@main
struct PasteMemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("appearanceMode") private var appearanceMode: String = "system"
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false

    init() {
        // 必须在 sharedModelContainer 首次访问前跑 —— container init 会创建 App
        // Support 目录,目录一旦存在,迁移判定就会把全新安装错判成"老用户"。
        Self.migrateMCPEnabledIfNeeded()
    }

    /// One-time migration: 决定 `mcpEnabled` 的默认值。
    /// - 老用户(从 1.7.x 升级):App Support 目录已存在 → 默认开启,保持原行为
    /// - 新装用户:目录还没创建 → 默认关闭,按需开启(隐私优先)
    /// issue #50
    private static func migrateMCPEnabledIfNeeded() {
        let migrationKey = "mcpEnabled.migrationApplied"
        let ud = UserDefaults.standard
        guard !ud.bool(forKey: migrationKey) else { return }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.lifedever.pastememo"
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeDir = appSupport.appendingPathComponent(bundleID)
        let isExistingUser = FileManager.default.fileExists(atPath: storeDir.path)

        ud.set(isExistingUser, forKey: "mcpEnabled")
        ud.set(true, forKey: migrationKey)
    }

    /// Settings scene 的兜底内容:被意外呈现时立即关掉自己并转到 AppKit 设置窗口。
    private struct SettingsSceneRedirect: View {
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .onAppear {
                    dismiss()
                    showSettingsWindowAppKit()
                }
        }
    }

    var body: some Scene {
        // 主管理器 / 自动化管理器不再用 SwiftUI `Window` scene:登录自启时 App 在
        // 后台启动,SwiftUI 不创建任何窗口,依赖视图 onAppear 注册的开窗闭包永远
        // 不会注册,状态栏「管理器/设置」点了没反应(issue #66)。两个窗口改走
        // AppKit WindowManager(见 WindowHelper.swift),闭包在 AppDelegate 启动时注册。
        // Settings scene 正常不可达(Cmd+, 已指到 AppKit 窗口,showSettingsWindow:
        // 自 Sonoma 起不再创建此窗口)。真实设置 UI 已是 NavigationSplitView,放进
        // Settings scene 会触发尺寸爆炸——万一未来某处加了 SettingsLink 把 scene
        // 呈现出来,这里只重定向到 AppKit 设置窗口,不承载真实 UI。
        Settings {
            SettingsSceneRedirect()
        }
        .commands {
            // 「设置…」(Cmd+,)指到 AppKit 设置窗口 —— Settings scene 的
            // showSettingsWindow: 在 macOS 14+ 已不可靠,见 WindowHelper.swift。
            CommandGroup(replacing: .appSettings) {
                Button(L10n.tr("menu.settings")) {
                    AppAction.shared.openSettings?()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .appInfo) {
                Button(L10n.tr("menu.checkForUpdates")) {
                    Task { await UpdateChecker.shared.checkForUpdates(userInitiated: true) }
                }
                Divider()
            }
            CommandMenu(L10n.tr("relay.title")) {
                if RelayManager.shared.isActive {
                    Button(L10n.tr("relay.exitRelay")) {
                        RelayManager.shared.deactivate()
                    }
                } else {
                    Button(L10n.tr("relay.startRelay")) {
                        RelayManager.shared.activate()
                    }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button(L10n.tr("menu.manager")) {
                    AppAction.shared.openMainWindow?()
                }
                Divider()
                Button(L10n.tr("menu.newGroup")) {
                    AppMenuActions.showNewGroupAlert()
                }
                Button(L10n.tr("menu.newSmartGroup")) {
                    // TODO: Smart group creation
                }
                .disabled(true)
                Divider()
                Button(L10n.tr("settings.automation.manage")) {
                    AppAction.shared.openAutomationManager?()
                }
            }
            CommandGroup(replacing: .importExport) {
                Button(L10n.tr("dataPorter.export")) {
                    AppMenuActions.handleExport()
                }
                Button(L10n.tr("dataPorter.import")) {
                    AppMenuActions.handleImport()
                }
                if DevDataImporter.isDevBuild {
                    Divider()
                    Button(L10n.tr("devTools.importFromRelease")) {
                        DevDataImporter.importFromRelease()
                    }
                }
            }
            CommandGroup(after: .windowArrangement) {
                Button {
                    alwaysOnTop.toggle()
                    for window in NSApp.windows where window.canBecomeMain {
                        window.level = alwaysOnTop ? .floating : .normal
                    }
                } label: {
                    if alwaysOnTop {
                        Text("✓ " + L10n.tr("menu.alwaysOnTop"))
                    } else {
                        Text("    " + L10n.tr("menu.alwaysOnTop"))
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button(L10n.tr("menu.help")) {
                    showHelpWindow()
                }
                Divider()
                Link(L10n.tr("menu.reportIssue"), destination: URL(string: "https://github.com/lifedever/PasteMemo-app/issues")!)
            }
        }

        // 状态栏图标改用 AppKit 的 NSStatusItem 实现（StatusBarController），
        // 这样能区分左/右键、支持左键自定义动作。AppDelegate 在启动时安装。
    }

    // MARK: - Menu Bar Icon

    static func menuBarIconPreview(filled: Bool) -> NSImage? {
        return menuBarIcon(paused: false, filled: filled)
    }

    static func menuBarIcon(paused: Bool, relay: Bool = false, filled: Bool = false) -> NSImage? {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            drawCards(in: rect, filled: filled)

            if relay {
                drawRelaySymbol(in: rect, filled: filled)
            } else if paused {
                drawPauseSymbol(in: rect, filled: filled)
            } else {
                drawLetterP(in: rect, filled: filled)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static let cardW: CGFloat = 11.0
    private static let cardH: CGFloat = 13.0
    private static let cardRadius: CGFloat = 2.5
    private static let cardGap: CGFloat = 2.5
    private static let cardStroke: CGFloat = 1.2

    /// Front card + back card exposed L-edge
    private static func drawCards(in rect: NSRect, filled: Bool = false) {
        let totalW = cardW + cardGap
        let totalH = cardH + cardGap
        let originX = (rect.width - totalW) / 2
        let originY = (rect.height - totalH) / 2

        // Snap to half-pixel for crisp strokes
        let fX = round(originX * 2) / 2
        let fY = round((originY + cardGap) * 2) / 2
        let bX = round((originX + cardGap) * 2) / 2
        let bY = round(originY * 2) / 2

        let r = cardRadius
        NSColor.black.setStroke()

        // Back card — same radius as front card, just offset by cardGap
        let back = NSBezierPath()
        back.lineWidth = cardStroke
        back.lineCapStyle = .round
        // Top edge
        back.move(to: NSPoint(x: fX + r, y: bY))
        back.line(to: NSPoint(x: bX + cardW - r, y: bY))
        // Top-right corner arc (same radius as front card)
        back.appendArc(
            withCenter: NSPoint(x: bX + cardW - r, y: bY + r),
            radius: r, startAngle: -90, endAngle: 0
        )
        // Right edge
        back.line(to: NSPoint(x: bX + cardW, y: fY + cardH - r))
        back.stroke()

        // Front card — full rounded rect
        let frontRect = NSRect(x: fX, y: fY, width: cardW, height: cardH)
        let front = NSBezierPath(roundedRect: frontRect, xRadius: r, yRadius: r)
        if filled {
            NSColor.black.setFill()
            front.fill()
        } else {
            front.lineWidth = cardStroke
            front.stroke()
        }
    }

    private static func frontCardCenter(in rect: NSRect) -> NSPoint {
        let totalW = cardW + cardGap
        let totalH = cardH + cardGap
        let fX = (rect.width - totalW) / 2
        let fY = (rect.height - totalH) / 2 + cardGap
        return NSPoint(x: fX + cardW / 2, y: fY + cardH / 2)
    }

    private static func drawLetterP(in rect: NSRect, filled: Bool = false) {
        let center = frontCardCenter(in: rect)
        let font = NSFont.systemFont(ofSize: 10.5, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]
        let str = NSAttributedString(string: "P", attributes: attrs)
        let s = str.size()

        if filled {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
        }
        str.draw(at: NSPoint(
            x: round(center.x - s.width / 2),
            y: round(center.y - s.height / 2)
        ))
        if filled {
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func drawPauseSymbol(in rect: NSRect, filled: Bool = false) {
        let center = frontCardCenter(in: rect)
        let barW: CGFloat = 1.8
        let barH: CGFloat = 7.0
        let gap: CGFloat = 2.2

        NSColor.black.setFill()
        if filled {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
        }

        let leftBar = NSRect(
            x: center.x - gap / 2 - barW,
            y: center.y - barH / 2,
            width: barW, height: barH
        )
        NSBezierPath(roundedRect: leftBar, xRadius: 0.5, yRadius: 0.5).fill()

        let rightBar = NSRect(
            x: center.x + gap / 2,
            y: center.y - barH / 2,
            width: barW, height: barH
        )
        NSBezierPath(roundedRect: rightBar, xRadius: 0.5, yRadius: 0.5).fill()

        if filled {
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func drawRelaySymbol(in rect: NSRect, filled: Bool = false) {
        let center = frontCardCenter(in: rect)
        let arrowLen: CGFloat = 5.0
        let headLen: CGFloat = 1.8
        let headH: CGFloat = 1.5
        let vGap: CGFloat = 1.6
        let lineW: CGFloat = 1.1

        let left = center.x - arrowLen / 2
        let right = center.x + arrowLen / 2
        NSColor.black.setStroke()

        if filled {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
        }

        // → top arrow
        let topY = center.y - vGap
        let topPath = NSBezierPath()
        topPath.lineWidth = lineW
        topPath.lineCapStyle = .round
        topPath.move(to: NSPoint(x: left, y: topY))
        topPath.line(to: NSPoint(x: right, y: topY))
        topPath.move(to: NSPoint(x: right - headLen, y: topY - headH))
        topPath.line(to: NSPoint(x: right, y: topY))
        topPath.stroke()

        // ← bottom arrow
        let botY = center.y + vGap
        let botPath = NSBezierPath()
        botPath.lineWidth = lineW
        botPath.lineCapStyle = .round
        botPath.move(to: NSPoint(x: right, y: botY))
        botPath.line(to: NSPoint(x: left, y: botY))
        botPath.move(to: NSPoint(x: left + headLen, y: botY + headH))
        botPath.line(to: NSPoint(x: left, y: botY))
        botPath.stroke()

        if filled {
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    static let sharedModelContainer: ModelContainer = {
        let schema = Schema([ClipItem.self, AutomationRule.self, SmartGroup.self])
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lifedever.pastememo"
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeDir = appSupport.appendingPathComponent(bundleID)
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let storeURL = storeDir.appendingPathComponent("PasteMemo.store")
        let config = ModelConfiguration(url: storeURL)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
            // Must run AFTER ModelContainer creates the SQLite schema. ensureIndexes
            // (and ensureFTS inside it) builds indexes, the clip_fts mirror table and
            // its sync triggers — all of which reference ZCLIPITEM / ZSMARTGROUP, so
            // those tables have to exist first. Running it BEFORE meant that on a
            // fresh install's first launch the store file didn't exist yet, the
            // fileExists guard short-circuited, and clip_fts + triggers were never
            // created for that session → quick-panel search silently returned empty
            // until the next relaunch self-healed it (issue #61).
            ensureIndexes(at: storeURL)
            // Run AFTER ModelContainer creates the ZCONTENTTYPERAW column
            migrateContentTypeColumn(at: storeURL)
            return container
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    /// One-time migration: copy ZCONTENTTYPE → ZCONTENTTYPERAW for existing rows
    /// after the storage was changed from enum to raw String.
    /// TODO: Remove after v1.4.0 — by then all users will have migrated.
    /// Also remove the `migrateContentTypeColumn` call in `sharedModelContainer`.
    private static func migrateContentTypeColumn(at storeURL: URL) {
        // v2: previous migration ran before ModelContainer (column didn't exist yet),
        // so reset the old flag to re-run for users who got the broken 1.2.4.
        let key = "contentTypeRawMigrated_v2"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        guard let db = SQLiteConnection(path: storeURL.path) else { return }
        defer { db.close() }
        db.execute("""
            UPDATE ZCLIPITEM SET ZCONTENTTYPERAW = ZCONTENTTYPE
            WHERE ZCONTENTTYPE IS NOT NULL AND ZCONTENTTYPE != ''
            AND (ZCONTENTTYPERAW IS NULL OR ZCONTENTTYPERAW = 'text')
            AND ZCONTENTTYPE != 'text'
        """)
        UserDefaults.standard.set(true, forKey: key)
    }

    private static func ensureIndexes(at storeURL: URL) {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        guard let db = SQLiteConnection(path: storeURL.path) else { return }
        defer { db.close() }
        // 与 SwiftData 的连接共用同一个 WAL 库，下面的 DDL 都要写锁。等一等比撞锁即失败好：
        // 失败的 DDL 以前连日志都没有。
        db.setBusyTimeout(milliseconds: 3000)

        // Drop legacy index on old column name before recreating on correct column.
        // 只在定义还指向旧列时才 DROP：以前每次启动无条件 DROP + 下面再 CREATE，等于
        // 每次启动都开一个写事务把这个索引整个重建一遍。
        let typeIndexSQL = db.queryStrings(
            "SELECT sql FROM sqlite_master WHERE type='index' AND name='idx_clip_type'"
        ).first ?? ""
        if !typeIndexSQL.isEmpty, !typeIndexSQL.contains("ZCONTENTTYPERAW") {
            db.execute("DROP INDEX IF EXISTS idx_clip_type")
        }

        // Defensive: ensure ZPRESERVESITEMS column exists on older stores where
        // SwiftData's lightweight migration may not have run yet. 先查再加——以前是
        // 每次启动跑一条注定报"duplicate column"的 ALTER 靠吞错误实现幂等。
        if !db.columnExists(table: "ZSMARTGROUP", column: "ZPRESERVESITEMS") {
            db.execute("ALTER TABLE ZSMARTGROUP ADD COLUMN ZPRESERVESITEMS INTEGER DEFAULT 0")
        }

        // Regular indexes. 各自 IF NOT EXISTS 幂等，失败只是退化成全表扫描、下次启动自愈，
        // 不需要事务，但要留痕。
        let indexes = [
            "CREATE INDEX IF NOT EXISTS idx_clip_lastused ON ZCLIPITEM (ZLASTUSEDAT DESC)",
            "CREATE INDEX IF NOT EXISTS idx_clip_created ON ZCLIPITEM (ZCREATEDAT DESC)",
            "CREATE INDEX IF NOT EXISTS idx_clip_type ON ZCLIPITEM (ZCONTENTTYPERAW)",
            "CREATE INDEX IF NOT EXISTS idx_clip_pinned_lastused ON ZCLIPITEM (ZISPINNED, ZLASTUSEDAT DESC)",
            "CREATE INDEX IF NOT EXISTS idx_clip_sourceapp ON ZCLIPITEM (ZSOURCEAPP)",
            "CREATE INDEX IF NOT EXISTS idx_clip_itemid ON ZCLIPITEM (ZITEMID)",
            // 启动时孤儿缓存文件清理只查 originalImageFilePath != nil（SwiftData 翻译成
            // `IS NOT NULL`）。不建索引是 SCAN 全表叶子页（万条级库冷启动 ~250ms）；
            // 部分索引只含非空行（几十条），查询变成索引 SEARCH。普通索引对 IS NOT NULL 不生效。
            "CREATE INDEX IF NOT EXISTS idx_clip_originalpath ON ZCLIPITEM (ZORIGINALIMAGEFILEPATH) WHERE ZORIGINALIMAGEFILEPATH IS NOT NULL",
        ]
        for sql in indexes {
            if !db.execute(sql) {
                DiagnosticLog.log("ensureIndexes: index DDL failed: \(db.lastErrorMessage)")
            }
        }

        // FTS5 full-text search table. 整段包进一个 IMMEDIATE 事务：里面有 DROP TRIGGER →
        // CREATE TRIGGER，中间任何一步失败（撞锁、崩溃、强退）都会留下「已删未建」——
        // 新条目再也进不了索引，搜索静默失效直到下次启动（issue #61 的另一个入口）。
        // 事务化后要么全部生效，要么回滚到进入前的完整状态。
        if !db.performInTransaction({ ensureFTS(db: db) }) {
            DiagnosticLog.log("ensureFTS: rolled back, FTS schema left as-is: \(db.lastErrorMessage)")
        }
    }

    /// 在 ensureIndexes 的 IMMEDIATE 事务内调用：任一语句失败返回 false，由调用方整体回滚。
    private static func ensureFTS(db: SQLiteConnection) -> Bool {
        // Migrate from older tokenizers or older schemas to the current trigram-backed schema.
        guard migrateToTrigramIfNeeded(db: db) else { return false }

        // Create FTS5 virtual table with trigram tokenizer for substring search
        guard db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS clip_fts USING fts5(
                itemID UNINDEXED, content, displayTitle, linkTitle, ocrText,
                tokenize='trigram'
            )
        """) else { return logDDLFailure(db, "ensureFTS") }

        // Auto-sync triggers. The `WHEN length(...) <= 262144` guard skips FTS
        // indexing for content over 256 KB — trigram tokenization on multi-MB
        // strings (e.g. inline base64 `data:image/...` URIs) blocks the SQLite
        // commit on the main thread for several seconds. Skipping these from
        // search is acceptable: substring search across megabytes of base64 is
        // not useful, and the row itself remains fully addressable by metadata.
        // Drop & recreate so existing stores pick up the guard.
        guard db.execute("DROP TRIGGER IF EXISTS clip_fts_insert") else { return logDDLFailure(db, "ensureFTS") }
        guard db.execute("DROP TRIGGER IF EXISTS clip_fts_update") else { return logDDLFailure(db, "ensureFTS") }
        guard db.execute("""
            CREATE TRIGGER clip_fts_insert AFTER INSERT ON ZCLIPITEM
            WHEN COALESCE(length(NEW.ZCONTENT), 0) <= 262144
            BEGIN
                INSERT INTO clip_fts(itemID, content, displayTitle, linkTitle, ocrText)
                VALUES (NEW.ZITEMID, COALESCE(NEW.ZCONTENT, ''), COALESCE(NEW.ZDISPLAYTITLE, ''), COALESCE(NEW.ZLINKTITLE, ''), COALESCE(NEW.ZOCRTEXT, ''));
            END
        """) else { return logDDLFailure(db, "ensureFTS") }
        guard db.execute("""
            CREATE TRIGGER IF NOT EXISTS clip_fts_delete AFTER DELETE ON ZCLIPITEM BEGIN
                DELETE FROM clip_fts WHERE itemID = OLD.ZITEMID;
            END
        """) else { return logDDLFailure(db, "ensureFTS") }
        // The DELETE runs unconditionally so a row that grew past the size guard
        // gets removed from FTS even when the new content can't be re-indexed.
        // The INSERT uses a `WHERE` selector instead of a trigger-level `WHEN`
        // so the same trigger can both clean up and (when small enough) re-add.
        guard db.execute("""
            CREATE TRIGGER clip_fts_update AFTER UPDATE OF ZCONTENT, ZDISPLAYTITLE, ZLINKTITLE, ZOCRTEXT ON ZCLIPITEM
            BEGIN
                DELETE FROM clip_fts WHERE itemID = OLD.ZITEMID;
                INSERT INTO clip_fts(itemID, content, displayTitle, linkTitle, ocrText)
                SELECT NEW.ZITEMID, COALESCE(NEW.ZCONTENT, ''), COALESCE(NEW.ZDISPLAYTITLE, ''), COALESCE(NEW.ZLINKTITLE, ''), COALESCE(NEW.ZOCRTEXT, '')
                WHERE COALESCE(length(NEW.ZCONTENT), 0) <= 262144;
            END
        """) else { return logDDLFailure(db, "ensureFTS") }

        // Populate FTS from existing data if empty. Mirror the trigger guard
        // so a one-time backfill doesn't choke on legacy rows that pre-date
        // the size cap (e.g. 10 MB base64 data URIs ingested before the
        // pre-decode landed).
        // 只需判空。FTS5 虚拟表没有行数捷径，COUNT(*) 要走完整个索引（万条级库冷启动
        // ~70ms）；LIMIT 1 探测只读一行。外层 COALESCE 保证查询成功时恰好返回一行
        // "1"/"0"，查询失败（表缺失 / 锁忙）时 queryStrings 返回 []——此时不 backfill，
        // 避免在表其实非空的情况下重复灌入。
        let probe = db.queryStrings("SELECT COALESCE((SELECT 1 FROM clip_fts LIMIT 1), 0)")
        if probe.first == "0" {
            guard db.execute("""
                INSERT INTO clip_fts(itemID, content, displayTitle, linkTitle, ocrText)
                SELECT ZITEMID, COALESCE(ZCONTENT, ''), COALESCE(ZDISPLAYTITLE, ''), COALESCE(ZLINKTITLE, ''), COALESCE(ZOCRTEXT, '')
                FROM ZCLIPITEM
                WHERE COALESCE(length(ZCONTENT), 0) <= 262144
            """) else { return logDDLFailure(db, "ensureFTS") }
        }
        return true
    }

    /// 返回 false 表示 DDL 失败（调用方回滚）；无需迁移也返回 true。
    private static func migrateToTrigramIfNeeded(db: SQLiteConnection) -> Bool {
        guard db.tableExists("clip_fts") else { return true }
        let sql = db.queryStrings(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='clip_fts'"
        )
        guard let createSQL = sql.first else { return true }
        guard !createSQL.contains("trigram") || !createSQL.contains("ocrText") else { return true }
        // Old tokenizer detected — drop everything and recreate
        guard db.execute("DROP TRIGGER IF EXISTS clip_fts_insert") else { return logDDLFailure(db, "migrateToTrigramIfNeeded") }
        guard db.execute("DROP TRIGGER IF EXISTS clip_fts_delete") else { return logDDLFailure(db, "migrateToTrigramIfNeeded") }
        guard db.execute("DROP TRIGGER IF EXISTS clip_fts_update") else { return logDDLFailure(db, "migrateToTrigramIfNeeded") }
        guard db.execute("DROP TABLE clip_fts") else { return logDDLFailure(db, "migrateToTrigramIfNeeded") }
        return true
    }

    private static func logDDLFailure(_ db: SQLiteConnection, _ context: String) -> Bool {
        DiagnosticLog.log("\(context): SQLite DDL failed: \(db.lastErrorMessage)")
        return false
    }
}
