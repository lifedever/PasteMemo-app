import SwiftUI
import SwiftData
import AppKit

@main
struct PasteMemoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("appearanceMode") private var appearanceMode: String = "system"
    @AppStorage("menuBarIconStyle") private var menuBarIconStyle: String = "outline"
    @ObservedObject private var clipboardManager = ClipboardManager.shared
    @AppStorage("alwaysOnTop") private var alwaysOnTop = false

    var body: some Scene {
        Window(L10n.tr("app.name"), id: "main") {
            MainWindowView()
                .environmentObject(ClipboardManager.shared)
                .modelContainer(Self.sharedModelContainer)
        }
        .defaultSize(width: 900, height: 560)
        .commands {
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
                Button(L10n.tr("menu.newGroup")) {
                    AppMenuActions.showNewGroupAlert()
                }
                Button(L10n.tr("snippet.new")) {
                    AppAction.shared.showNewSnippetWindow?()
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

        Window(L10n.tr("automation.window.title"), id: "automationManager") {
            AutomationManagerView()
                .modelContainer(Self.sharedModelContainer)
        }
        .defaultSize(width: 700, height: 500)

        Settings {
            SettingsView()
                .environmentObject(ClipboardManager.shared)
                .modelContainer(Self.sharedModelContainer)
        }

        MenuBarExtra {
            MenuBarContent()
        } label: {
            if let image = Self.menuBarIcon(paused: clipboardManager.isPaused, relay: RelayManager.shared.isActive, filled: menuBarIconStyle == "filled") {
                Image(nsImage: image)
            } else {
                Image(systemName: "doc.on.clipboard")
            }
        }
        .menuBarExtraStyle(.menu)
    }

    // MARK: - Menu Bar Icon

    static func menuBarIconPreview(filled: Bool) -> NSImage? {
        return menuBarIcon(paused: false, filled: filled)
    }

    private static func menuBarIcon(paused: Bool, relay: Bool = false, filled: Bool = false) -> NSImage? {
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
        let schema = Schema([ClipItem.self, SnippetItem.self, AutomationRule.self, SmartGroup.self])
        let bundleID = Bundle.main.bundleIdentifier ?? "com.lifedever.pastememo"
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let storeDir = appSupport.appendingPathComponent(bundleID)
        try? FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let storeURL = storeDir.appendingPathComponent("PasteMemo.store")
        ensureIndexes(at: storeURL)
        let config = ModelConfiguration(url: storeURL)
        do {
            let container = try ModelContainer(for: schema, configurations: [config])
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

        // Drop legacy index on old column name before recreating on correct column
        db.execute("DROP INDEX IF EXISTS idx_clip_type")

        // Regular indexes
        let indexes = [
            "CREATE INDEX IF NOT EXISTS idx_clip_lastused ON ZCLIPITEM (ZLASTUSEDAT DESC)",
            "CREATE INDEX IF NOT EXISTS idx_clip_created ON ZCLIPITEM (ZCREATEDAT DESC)",
            "CREATE INDEX IF NOT EXISTS idx_clip_type ON ZCLIPITEM (ZCONTENTTYPERAW)",
            "CREATE INDEX IF NOT EXISTS idx_clip_pinned_lastused ON ZCLIPITEM (ZISPINNED, ZLASTUSEDAT DESC)",
            "CREATE INDEX IF NOT EXISTS idx_clip_sourceapp ON ZCLIPITEM (ZSOURCEAPP)",
            "CREATE INDEX IF NOT EXISTS idx_clip_itemid ON ZCLIPITEM (ZITEMID)",
        ]
        for sql in indexes { db.execute(sql) }

        // FTS5 full-text search table
        ensureFTS(db: db)
    }

    private static func ensureFTS(db: SQLiteConnection) {
        // Migrate from older tokenizers or older schemas to the current trigram-backed schema.
        migrateToTrigramIfNeeded(db: db)

        // Create FTS5 virtual table with trigram tokenizer for substring search
        db.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS clip_fts USING fts5(
                itemID UNINDEXED, content, displayTitle, linkTitle, ocrText,
                tokenize='trigram'
            )
        """)

        // Auto-sync triggers
        db.execute("""
            CREATE TRIGGER IF NOT EXISTS clip_fts_insert AFTER INSERT ON ZCLIPITEM BEGIN
                INSERT INTO clip_fts(itemID, content, displayTitle, linkTitle, ocrText)
                VALUES (NEW.ZITEMID, COALESCE(NEW.ZCONTENT, ''), COALESCE(NEW.ZDISPLAYTITLE, ''), COALESCE(NEW.ZLINKTITLE, ''), COALESCE(NEW.ZOCRTEXT, ''));
            END
        """)
        db.execute("""
            CREATE TRIGGER IF NOT EXISTS clip_fts_delete AFTER DELETE ON ZCLIPITEM BEGIN
                DELETE FROM clip_fts WHERE itemID = OLD.ZITEMID;
            END
        """)
        db.execute("""
            CREATE TRIGGER IF NOT EXISTS clip_fts_update AFTER UPDATE OF ZCONTENT, ZDISPLAYTITLE, ZLINKTITLE, ZOCRTEXT ON ZCLIPITEM BEGIN
                DELETE FROM clip_fts WHERE itemID = OLD.ZITEMID;
                INSERT INTO clip_fts(itemID, content, displayTitle, linkTitle, ocrText)
                VALUES (NEW.ZITEMID, COALESCE(NEW.ZCONTENT, ''), COALESCE(NEW.ZDISPLAYTITLE, ''), COALESCE(NEW.ZLINKTITLE, ''), COALESCE(NEW.ZOCRTEXT, ''));
            END
        """)

        // Populate FTS from existing data if empty
        let count = db.queryStrings("SELECT COUNT(*) FROM clip_fts")
        if count.first == "0" {
            db.execute("""
                INSERT INTO clip_fts(itemID, content, displayTitle, linkTitle, ocrText)
                SELECT ZITEMID, COALESCE(ZCONTENT, ''), COALESCE(ZDISPLAYTITLE, ''), COALESCE(ZLINKTITLE, ''), COALESCE(ZOCRTEXT, '')
                FROM ZCLIPITEM
            """)
        }
    }

    private static func migrateToTrigramIfNeeded(db: SQLiteConnection) {
        guard db.tableExists("clip_fts") else { return }
        let sql = db.queryStrings(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='clip_fts'"
        )
        guard let createSQL = sql.first else { return }
        guard !createSQL.contains("trigram") || !createSQL.contains("ocrText") else { return }
        // Old tokenizer detected — drop everything and recreate
        db.execute("DROP TRIGGER IF EXISTS clip_fts_insert")
        db.execute("DROP TRIGGER IF EXISTS clip_fts_delete")
        db.execute("DROP TRIGGER IF EXISTS clip_fts_update")
        db.execute("DROP TABLE clip_fts")
    }
}
