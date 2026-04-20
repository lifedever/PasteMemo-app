import SwiftUI
import SwiftData

struct DataPorterSection: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var clipItems: [ClipItem]
    @Query private var groups: [SmartGroup]
    @Query private var rules: [AutomationRule]

    @State private var isEncryptExport = false
    @State private var exportPassword = ""
    @State private var confirmPassword = ""
    @State private var alertMessage = ""
    @State private var isAlertPresented = false
    @State private var isPasswordSheetPresented = false
    @State private var importPassword = ""
    @State private var pendingImportData: Data?
    @State private var isProcessing = false
    @State private var importProgress = ""
    @State private var progressValue: Double = 0
    @State private var progressTitle = ""
    @State private var showClearMenu = false

    var body: some View {
        Section(L10n.tr("dataPorter.section")) {
            exportControls
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var exportControls: some View {
        Toggle(L10n.tr("dataPorter.encrypt"), isOn: $isEncryptExport)

        if isEncryptExport {
            SecureField(L10n.tr("dataPorter.password"), text: $exportPassword)
            SecureField(L10n.tr("dataPorter.confirmPassword"), text: $confirmPassword)
        }

        HStack {
            Button(L10n.tr("dataPorter.export")) { handleExport() }
                .disabled(isProcessing)
                .pointerCursor()
            Button(L10n.tr("dataPorter.import")) { handleImport() }
                .disabled(isProcessing)
                .pointerCursor()
            Spacer()
            clearDataButton
        }
        .sheet(isPresented: $isProcessing) {
            VStack(spacing: 16) {
                Text(progressTitle)
                    .font(.headline)
                ProgressView(value: progressValue, total: 1.0)
                    .progressViewStyle(.linear)
                Text(importProgress)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(30)
            .frame(width: 300)
            .interactiveDismissDisabled()
        }
        .alert(alertMessage, isPresented: $isAlertPresented) {
            Button(L10n.tr("action.confirm")) {}
        }
        .sheet(isPresented: $isPasswordSheetPresented) {
            passwordSheet
        }
    }

    private var passwordSheet: some View {
        VStack(spacing: 16) {
            Text(L10n.tr("dataPorter.enterPassword"))
                .font(.headline)
            SecureField(L10n.tr("dataPorter.password"), text: $importPassword)
                .frame(width: 260)
            HStack {
                Button(L10n.tr("settings.general")) { // Cancel
                    isPasswordSheetPresented = false
                    importPassword = ""
                    pendingImportData = nil
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.tr("action.confirm")) { decryptAndImport() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(importPassword.isEmpty)
            }
        }
        .padding(24)
    }

    // MARK: - Actions

    private func handleExport() {
        guard validateExportPasswords() else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "pastememo")!]
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        panel.nameFieldStringValue = "PasteMemo-\(timestamp).pastememo"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        progressTitle = L10n.tr("dataPorter.export")
        isProcessing = true
        importProgress = ""
        progressValue = 0
        let encrypt = isEncryptExport
        let password = exportPassword
        let snapshotGroups = groups
        let snapshotRules = rules
        Task { @MainActor in
            let total = clipItems.count
            var exportItems: [ExportItem] = []
            exportItems.reserveCapacity(total)
            let batchSize = 100
            for i in stride(from: 0, to: total, by: batchSize) {
                let end = min(i + batchSize, total)
                for j in i..<end {
                    exportItems.append(DataPorter.buildSingleExportItem(clipItems[j]))
                }
                importProgress = "\(end) / \(total)"
                progressValue = Double(end) / Double(max(total, 1))
                await Task.yield()
            }
            let payload = ExportPayload(
                version: DataPorter.currentVersion,
                exportDate: Date(),
                items: exportItems,
                groups: snapshotGroups.map(DataPorter.buildSingleExportGroup),
                rules: snapshotRules.map(DataPorter.buildSingleExportRule)
            )
            importProgress = L10n.tr("dataPorter.compressing")
            await Task.yield()
            Task.detached {
                do {
                    let compressed = try DataPorter.encodeAndCompress(payload)
                    let fileData = encrypt
                        ? try DataPorterCrypto.encrypt(data: compressed, password: password)
                        : DataPorterCrypto.wrapPlaintext(compressed)
                    try fileData.write(to: url)
                    await MainActor.run {
                        isProcessing = false
                        showAlert(L10n.tr("dataPorter.exportSuccess"))
                        resetExportFields()
                    }
                } catch {
                    await MainActor.run {
                        isProcessing = false
                        showAlert(error.localizedDescription)
                    }
                }
            }
        }
    }

    private func handleImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "pastememo")!]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let fileData = try Data(contentsOf: url)
            if DataPorterCrypto.isEncrypted(fileData) {
                pendingImportData = fileData
                importPassword = ""
                isPasswordSheetPresented = true
            } else {
                performImport(with: fileData, password: nil)
            }
        } catch {
            showAlert(error.localizedDescription)
        }
    }

    private func decryptAndImport() {
        isPasswordSheetPresented = false
        guard let fileData = pendingImportData else { return }
        performImport(with: fileData, password: importPassword)
        importPassword = ""
        pendingImportData = nil
    }

    private func performImport(with fileData: Data, password: String?) {
        progressTitle = L10n.tr("dataPorter.import")
        isProcessing = true
        importProgress = ""
        progressValue = 0
        Task { @MainActor in
            defer {
                isProcessing = false
                importProgress = ""
                progressValue = 0
            }
            do {
                let jsonData: Data
                if let password {
                    jsonData = try DataPorterCrypto.decrypt(fileData: fileData, password: password)
                } else {
                    jsonData = try DataPorterCrypto.decrypt(fileData: fileData, password: "")
                }
                ClipItemStore.isBulkOperation = true
                let result = try await DataPorter.importItems(
                    from: jsonData,
                    into: modelContext
                ) { current, total in
                    importProgress = "\(current) / \(total)"
                    progressValue = Double(current) / Double(max(total, 1))
                }
                ClipItemStore.isBulkOperation = false
                var extras: [String] = []
                if result.importedGroups > 0 { extras.append("+\(result.importedGroups) groups") }
                if result.importedRules > 0 { extras.append("+\(result.importedRules) rules") }
                let extrasText = extras.isEmpty ? "" : ", " + extras.joined(separator: ", ")
                showAlert(L10n.tr("dataPorter.importSuccess") + " (\(result.imported) imported, \(result.skipped) skipped\(extrasText))")
            } catch let error as CryptoError where error == .wrongPassword {
                showAlert(L10n.tr("dataPorter.wrongPassword"))
            } catch {
                showAlert(error.localizedDescription)
            }
        }
    }

    // MARK: - Helpers

    private func validateExportPasswords() -> Bool {
        guard isEncryptExport else { return true }
        guard exportPassword == confirmPassword else {
            showAlert(L10n.tr("dataPorter.passwordMismatch"))
            return false
        }
        guard !exportPassword.isEmpty else {
            showAlert(L10n.tr("dataPorter.password"))
            return false
        }
        return true
    }

    private func resetExportFields() {
        exportPassword = ""
        confirmPassword = ""
    }

    private func showAlert(_ message: String) {
        alertMessage = message
        isAlertPresented = true
    }

    private var clearDataButton: some View {
        Menu {
            Button(L10n.tr("settings.clearData.1month")) { confirmClear(days: 30) }
            Button(L10n.tr("settings.clearData.3months")) { confirmClear(days: 90) }
            Button(L10n.tr("settings.clearData.6months")) { confirmClear(days: 180) }
            Button(L10n.tr("settings.clearData.1year")) { confirmClear(days: 365) }
            Divider()
            Button(L10n.tr("settings.clearData.all"), role: .destructive) { confirmClear(days: 0) }
        } label: {
            Label(L10n.tr("settings.clearData"), systemImage: "trash")
        }
        .pointerCursor()
        .alert(L10n.tr("settings.clearData"), isPresented: $showClearConfirm) {
            Button(L10n.tr("action.delete"), role: .destructive) { clearItems(olderThan: pendingClearDays) }
            Button(L10n.tr("action.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("action.clearConfirm"))
        }
        .alert(alertMessage, isPresented: $showClearResult) {
            Button(L10n.tr("action.confirm")) {}
        }
    }

    private func confirmClear(days: Int) {
        pendingClearDays = days
        showClearConfirm = true
    }

    @State private var showClearResult = false
    @State private var showClearConfirm = false
    @State private var pendingClearDays = 0

    private func clearItems(olderThan days: Int) {
        progressTitle = L10n.tr("settings.clearData")
        isProcessing = true
        importProgress = ""
        progressValue = 0
        Task { @MainActor in
            defer {
                isProcessing = false
                importProgress = ""
                ClipItemStore.isBulkOperation = false
            }
            ClipItemStore.isBulkOperation = true

            let preservedGroupNames = SmartGroupRetention.preservedGroupNames(in: modelContext)
            let descriptor: FetchDescriptor<ClipItem>
            if days > 0 {
                let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
                descriptor = FetchDescriptor<ClipItem>(
                    predicate: #Predicate { !$0.isPinned && $0.createdAt < cutoff }
                )
            } else {
                descriptor = FetchDescriptor<ClipItem>(
                    predicate: #Predicate { !$0.isPinned }
                )
            }
            guard let fetchedItems = try? modelContext.fetch(descriptor) else { return }
            let items = SmartGroupRetention.filterDeletableItems(fetchedItems, preservedGroupNames: preservedGroupNames)
            let total = items.count
            let batchSize = 100

            for i in stride(from: 0, to: total, by: batchSize) {
                let end = min(i + batchSize, total)
                for j in i..<end {
                    modelContext.delete(items[j])
                }
                try? modelContext.save()
                importProgress = "\(end) / \(total)"
                progressValue = Double(end) / Double(max(total, 1))
                await Task.yield()
            }

            ClipboardManager.shared.recalculateAllGroupCounts(context: modelContext)
            alertMessage = L10n.tr("settings.clearData.result", total)
            showClearResult = true
        }
    }
}
