import AppKit
import SwiftData

@MainActor
enum AppMenuActions {

    static func handleExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "pastememo")!]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "PasteMemo-\(formatter.string(from: Date())).pastememo"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let container = PasteMemoApp.sharedModelContainer
        let context = container.mainContext
        guard let items = try? context.fetch(FetchDescriptor<ClipItem>()) else { return }
        let groups = (try? context.fetch(FetchDescriptor<SmartGroup>())) ?? []
        let rules = (try? context.fetch(FetchDescriptor<AutomationRule>())) ?? []

        // Step 1: extract on main thread (SwiftData objects)
        let payload = DataPorter.buildExportPayload(items, groups: groups, rules: rules)
        // Step 2: encode + compress + write on background thread
        Task.detached {
            do {
                let compressed = try DataPorter.encodeAndCompress(payload)
                let fileData = DataPorterCrypto.wrapPlaintext(compressed)
                try fileData.write(to: url)
                await MainActor.run { showAlert(L10n.tr("dataPorter.exportSuccess")) }
            } catch {
                await MainActor.run { showAlert(error.localizedDescription) }
            }
        }
    }

    static func handleImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "pastememo")!]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let container = PasteMemoApp.sharedModelContainer
        let context = container.mainContext

        do {
            let fileData = try Data(contentsOf: url)
            if DataPorterCrypto.isEncrypted(fileData) {
                promptPasswordAndImport(fileData: fileData, context: context)
            } else {
                performImport(fileData: fileData, password: nil, context: context)
            }
        } catch {
            showAlert(error.localizedDescription)
        }
    }

    private static func promptPasswordAndImport(fileData: Data, context: ModelContext) {
        let alert = NSAlert()
        alert.messageText = L10n.tr("dataPorter.enterPassword")
        alert.addButton(withTitle: L10n.tr("action.confirm"))
        alert.addButton(withTitle: L10n.tr("action.cancel"))

        let input = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = input
        alert.window.initialFirstResponder = input

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let password = input.stringValue
        guard !password.isEmpty else { return }
        performImport(fileData: fileData, password: password, context: context)
    }

    private static func performImport(fileData: Data, password: String?, context: ModelContext) {
        // Show the progress panel up front so the user has visible feedback
        // before we touch the heavy work below. Settings panel has its own
        // integrated sheet — this is the menu-action equivalent.
        let coordinator = ImportProgressCoordinator.shared
        coordinator.start(
            title: L10n.tr("dataPorter.import"),
            initialStatus: L10n.tr("dataPorter.decrypting")
        )

        Task { @MainActor in
            do {
                // Let SwiftUI commit the panel's initial render before we hold
                // the main actor with crypto / decode work.
                try? await Task.sleep(for: .milliseconds(32))

                // PBKDF2 (600k iter) + AES.GCM + zlib + JSON decode of a
                // multi-MB payload would freeze the panel and spin the cursor
                // if done on the main actor. Run off-actor, then resume.
                let pwd = password ?? ""
                let payload: ExportPayload = try await Task.detached(priority: .userInitiated) {
                    let jsonData = try DataPorterCrypto.decrypt(fileData: fileData, password: pwd)
                    return try DataPorter.decodePayload(jsonData)
                }.value

                coordinator.updateProgress(current: 0, total: payload.items.count)

                ClipItemStore.isBulkOperation = true
                let result = try await DataPorter.importItems(
                    payload: payload,
                    into: context
                ) { current, total in
                    coordinator.updateProgress(current: current, total: total)
                }
                ClipItemStore.isBulkOperation = false

                // Same reasoning as DataPorterSection.performImport: the
                // throttled save observer is async (`.receive(on: RunLoop.main)`),
                // so a synchronous refresh here keeps the main window in sync
                // before the result phase reveals it behind the panel.
                coordinator.setIndeterminateStage(L10n.tr("dataPorter.refreshing"))
                await Task.yield()
                ClipItemStore.refreshAllStoresNow()

                // Folds the would-be follow-up "import success" alert into the
                // same panel so the user gets one place to ack the result.
                coordinator.showSuccess(result: result)
            } catch let error as CryptoError where error == .wrongPassword {
                coordinator.showFailure(message: L10n.tr("dataPorter.wrongPassword"))
            } catch {
                coordinator.showFailure(message: error.localizedDescription)
            }
        }
    }

    static func showNewGroupAlert() {
        guard let result = GroupEditorPanel.show() else { return }

        let container = PasteMemoApp.sharedModelContainer
        let context = container.mainContext
        let resultName = result.name
        let descriptor = FetchDescriptor<SmartGroup>(predicate: #Predicate { $0.name == resultName })
        if (try? context.fetch(descriptor).first) != nil { return }
        let maxOrder = (try? context.fetch(FetchDescriptor<SmartGroup>()))?.map(\.sortOrder).max() ?? -1
        let group = SmartGroup(name: result.name, icon: result.icon, sortOrder: maxOrder + 1, preservesItems: result.preservesItems)
        context.insert(group)
        try? context.save()
        NotificationCenter.default.post(name: ClipItemStore.itemDidUpdateNotification, object: nil)
    }

    static func showEditGroupAlert(group: SmartGroup, context: ModelContext) {
        guard let result = GroupEditorPanel.show(name: group.name, icon: group.icon, preservesItems: group.preservesItems) else { return }
        group.name = result.name
        group.icon = result.icon
        group.preservesItems = result.preservesItems
        try? context.save()
        NotificationCenter.default.post(name: ClipItemStore.itemDidUpdateNotification, object: nil)
    }

    static func deleteGroup(name: String, context: ModelContext) {
        let descriptor = FetchDescriptor<SmartGroup>(predicate: #Predicate { $0.name == name })
        guard let group = try? context.fetch(descriptor).first else { return }
        let itemDescriptor = FetchDescriptor<ClipItem>(predicate: #Predicate { $0.groupName == name })
        if let items = try? context.fetch(itemDescriptor) {
            for item in items { item.groupName = nil }
        }
        context.delete(group)
        try? context.save()
        NotificationCenter.default.post(name: ClipItemStore.itemDidUpdateNotification, object: nil)
    }

    private static func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
    }
}
