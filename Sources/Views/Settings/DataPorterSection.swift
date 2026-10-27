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

    var body: some View {
        Section(L10n.tr("dataPorter.importExport")) {
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
        }
        .sheet(isPresented: $isProcessing) {
            VStack(spacing: 16) {
                Text(progressTitle)
                    .font(.headline)
                // Switch between indeterminate and determinate so stages with no
                // measurable progress (decrypt / parse / refresh) still animate
                // instead of sitting at 0% and looking frozen.
                if progressValue > 0 && progressValue < 1.0 {
                    ProgressView(value: progressValue, total: 1.0)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
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
        let snapshotItems = clipItems
        Task { @MainActor in
            do {
                // Streamed straight to disk, original images included: building the whole
                // document in memory first costs several times the export's size.
                try await DataPorter.writeExportFile(
                    clipItems: snapshotItems,
                    groups: snapshotGroups,
                    rules: snapshotRules,
                    to: url,
                    password: encrypt ? password : nil
                ) { current, total in
                    importProgress = "\(current) / \(total)"
                    progressValue = Double(current) / Double(max(total, 1))
                    if current == total { importProgress = L10n.tr("dataPorter.compressing") }
                }
                isProcessing = false
                showAlert(L10n.tr("dataPorter.exportSuccess"))
                resetExportFields()
            } catch {
                isProcessing = false
                showAlert(error.localizedDescription)
            }
        }
    }

    private func handleImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "pastememo")!]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            // Mapped: the import streams through it once.
            let fileData = try Data(contentsOf: url, options: .mappedIfSafe)
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
        importProgress = L10n.tr("dataPorter.decrypting")
        progressValue = 0
        Task { @MainActor in
            defer {
                isProcessing = false
                importProgress = ""
                progressValue = 0
            }
            do {
                // SwiftUI may not have committed the `isProcessing = true` state
                // change yet — without this fence the main actor gets grabbed
                // by the heavy work below before the sheet renders, so the user
                // sees a frozen window with a spinning cursor instead of the
                // progress sheet they're meant to see.
                try? await Task.sleep(for: .milliseconds(32))

                // PBKDF2 (600k iter) + AES.GCM + zlib + JSON decode on a multi-MB
                // payload easily eats several seconds. Doing it inline on the
                // main actor freezes the progress sheet and spins the cursor —
                // the symptoms the user reported. Run off-actor, then resume.
                let pwd = password ?? ""
                let jsonData = try await Task.detached(priority: .userInitiated) {
                    try DataPorterCrypto.decrypt(fileData: fileData, password: pwd)
                }.value

                // Streams the items past instead of decoding the whole file: exports carry
                // the original images and would take several times their size in memory.
                ClipItemStore.isBulkOperation = true
                defer { ClipItemStore.isBulkOperation = false }
                let result = try await DataPorter.importStreaming(
                    jsonData,
                    into: modelContext
                ) { current, total in
                    importProgress = "\(current) / \(total)"
                    progressValue = Double(current) / Double(max(total, 1))
                }
                ClipItemStore.isBulkOperation = false

                // Keep the progress sheet on screen with a "refreshing" stage
                // and synchronously rebuild every live store BEFORE we let the
                // sheet close. Without this, the immediate save observer fires
                // on `.receive(on: RunLoop.main)` (async), so the sheet closes
                // first and the user sees an empty main window flash for a few
                // seconds before items materialise.
                importProgress = L10n.tr("dataPorter.refreshing")
                progressValue = 1.0
                await Task.yield()
                ClipItemStore.refreshAllStoresNow()

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

}
