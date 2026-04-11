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
        let descriptor = FetchDescriptor<ClipItem>()
        guard let items = try? context.fetch(descriptor) else { return }

        // Step 1: extract on main thread (SwiftData objects)
        let payload = DataPorter.buildExportPayload(items)
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
        Task { @MainActor in
            do {
                let jsonData = try DataPorterCrypto.decrypt(fileData: fileData, password: password ?? "")
                let result = try DataPorter.importItems(from: jsonData, into: context)
                showAlert(L10n.tr("dataPorter.importSuccess") + " (\(result.imported) imported, \(result.skipped) skipped)")
            } catch {
                showAlert(L10n.tr("dataPorter.wrongPassword"))
            }
        }
    }

    static func showNewGroupAlert() {
        GroupEditorPanel.show() { result in
            guard let result else { return }

            let container = PasteMemoApp.sharedModelContainer
            let context = container.mainContext
            let resultName = result.name
            let descriptor = FetchDescriptor<SmartGroup>(predicate: #Predicate { $0.name == resultName })
            if (try? context.fetch(descriptor).first) != nil { return }
            let maxOrder = (try? context.fetch(FetchDescriptor<SmartGroup>()))?.map(\.sortOrder).max() ?? -1
            let group = SmartGroup(name: result.name, icon: result.icon, sortOrder: maxOrder + 1)
            context.insert(group)
            try? context.save()
            NotificationCenter.default.post(name: ClipItemStore.itemDidUpdateNotification, object: nil)
        }
    }

    static func showEditGroupAlert(
        group: SmartGroup,
        context: ModelContext,
        onComplete: ((String, String) -> Void)? = nil
    ) {
        GroupEditorPanel.show(name: group.name, icon: group.icon) { result in
            guard let result else { return }
            let oldName = group.name
            group.name = result.name
            group.icon = result.icon
            try? context.save()
            NotificationCenter.default.post(name: ClipItemStore.itemDidUpdateNotification, object: nil)
            onComplete?(oldName, result.name)
        }
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
