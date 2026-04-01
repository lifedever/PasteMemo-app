import SwiftUI
import SwiftData

struct BackupSettingsSection: View {
    @ObservedObject private var proManager = ProManager.shared
    @AppStorage("backupEnabled") private var backupEnabled = false
    @AppStorage("backupFrequency") private var backupFrequency = "1d"
    @AppStorage("backupMaxSlots") private var maxSlots = 3
    @AppStorage("backupDestinationType") private var destinationType = "local"
    @AppStorage("webdavURL") private var webdavURL = ""
    @AppStorage("webdavUsername") private var webdavUsername = ""

    @AppStorage("webdavPassword") private var webdavPassword = ""
    @State private var isTestingConnection = false
    @State private var isBackingUp = false
    @State private var isRestoring = false
    @State private var showRestoreSheet = false
    @State private var alertMessage = ""
    @State private var isAlertPresented = false
    @State private var pendingRestore: (backup: BackupMetadata, strategy: RestoreStrategy)?
    @State private var showRestoreConfirm = false

    var body: some View {
        Section {
            backupToggle
            if backupEnabled {
                frequencyPicker
                maxSlotsPicker
                destinationPicker
                if destinationType == "local" {
                    localPathConfig
                }
                if destinationType == "webdav" {
                    webdavConfig
                }
                statusInfo
                actionButtons
            }
        } header: {
            HStack {
                Text(L10n.tr("backup.section"))
                if !proManager.isPro {
                    ProBadge()
                }
            }
        }
        .onAppear {}
        .alert(alertMessage, isPresented: $isAlertPresented) {
            Button(L10n.tr("action.confirm")) {}
        }
        .sheet(isPresented: $showRestoreSheet) {
            RestoreSheetView(
                isPresented: $showRestoreSheet,
                pendingRestore: $pendingRestore,
                showRestoreConfirm: $showRestoreConfirm
            )
        }
        .alert(L10n.tr("backup.restore.confirm"), isPresented: $showRestoreConfirm) {
            Button(L10n.tr("action.cancel"), role: .cancel) { pendingRestore = nil }
            Button(pendingRestore?.strategy == .overwrite
                   ? L10n.tr("backup.restore.overwrite") : L10n.tr("backup.restore.merge"),
                   role: pendingRestore?.strategy == .overwrite ? .destructive : nil
            ) {
                guard let pending = pendingRestore else { return }
                pendingRestore = nil
                performRestore(pending.backup, strategy: pending.strategy)
            }
        } message: {
            Text(pendingRestore?.strategy == .overwrite
                 ? L10n.tr("backup.restore.confirmOverwrite")
                 : L10n.tr("backup.restore.confirmMerge"))
        }
    }

    // MARK: - Subviews

    private var backupToggle: some View {
        Toggle(L10n.tr("backup.enable"), isOn: $backupEnabled)
            .disabled(!proManager.isPro)
            .onChange(of: backupEnabled) {
                BackupScheduler.shared.reschedule()
            }
    }

    private var frequencyPicker: some View {
        Picker(L10n.tr("backup.frequency"), selection: $backupFrequency) {
            ForEach(BackupFrequency.allCases, id: \.rawValue) { freq in
                Text(freq.displayName).tag(freq.rawValue)
            }
        }
        .onChange(of: backupFrequency) {
            BackupScheduler.shared.reschedule()
        }
    }

    private var maxSlotsPicker: some View {
        Picker(L10n.tr("backup.maxSlots"), selection: $maxSlots) {
            ForEach(1...10, id: \.self) { n in
                Text("\(n)").tag(n)
            }
        }
    }

    private var destinationPicker: some View {
        Picker(L10n.tr("backup.destination"), selection: $destinationType) {
            ForEach(BackupDestinationType.allCases, id: \.rawValue) { type in
                Text(type.displayName).tag(type.rawValue)
            }
        }
        .onChange(of: destinationType) {
            UserDefaults.standard.set(0, forKey: "backupCurrentSlot")
            BackupScheduler.shared.reschedule()
        }
    }

    private var localPathConfig: some View {
        LabeledContent(L10n.tr("backup.path")) {
            HStack(spacing: 8) {
                Text(LocalBackupDestination.backupDirectory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .onTapGesture { openBackupDirectory() }
                    .pointerCursor()
                Button(L10n.tr("backup.changePath")) { chooseBackupDirectory() }
                    .controlSize(.small)
                    .pointerCursor()
            }
        }
    }

    private var webdavConfig: some View {
        Group {
            TextField(L10n.tr("backup.webdav.url"), text: $webdavURL)
                .lineLimit(1)
                .truncationMode(.tail)
            LabeledContent(L10n.tr("backup.webdav.username")) {
                TextField("", text: $webdavUsername)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent(L10n.tr("backup.webdav.password")) {
                SecureField("", text: $webdavPassword)
            }
            HStack {
                Spacer()
                Button(L10n.tr("backup.webdav.test")) { testConnection() }
                    .disabled(isTestingConnection || webdavURL.isEmpty)
                    .pointerCursor()
            }
        }
    }

    private var statusInfo: some View {
        Group {
            if let lastDate = BackupScheduler.shared.lastBackupDate {
                LabeledContent(L10n.tr("backup.lastBackup")) {
                    Text(lastDate, style: .date)
                    Text(lastDate, style: .time)
                }
            }
            if let nextDate = BackupScheduler.shared.nextBackupDate {
                LabeledContent(L10n.tr("backup.nextBackup")) {
                    Text(nextDate, style: .date)
                    Text(nextDate, style: .time)
                }
            }
            if let error = BackupScheduler.shared.lastBackupError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    private var actionButtons: some View {
        HStack {
            Button(L10n.tr("backup.backupNow")) { performBackup() }
                .disabled(isBackingUp || BackupScheduler.shared.isBackingUp)
                .pointerCursor()
            Button(L10n.tr("backup.restore")) { loadBackupList() }
                .disabled(isRestoring)
                .pointerCursor()
        }
    }

    // MARK: - Actions

    private func performBackup() {
        isBackingUp = true
        Task {
            await BackupScheduler.shared.backupNow()
            isBackingUp = false
            if BackupScheduler.shared.lastBackupError == nil {
                showAlert(L10n.tr("backup.success"))
            } else {
                showAlert(BackupScheduler.shared.lastBackupError ?? "")
            }
        }
    }

    private func loadBackupList() {
        showRestoreSheet = true
    }

    private func performRestore(_ backup: BackupMetadata, strategy: RestoreStrategy) {
        isRestoring = true
        Task {
            defer { isRestoring = false }
            guard let container = BackupScheduler.shared.modelContainer else { return }
            let destination = BackupScheduler.shared.buildDestination()
            do {
                let result = try await BackupEngine.restore(
                    from: backup,
                    destination: destination,
                    strategy: strategy,
                    container: container
                )
                let msg = L10n.tr("backup.restore.success")
                    + " (\(result.restoredCount) imported, \(result.skippedCount) skipped)"
                showAlert(msg)
            } catch {
                showAlert(error.localizedDescription)
            }
        }
    }

    private func testConnection() {
        isTestingConnection = true
        Task {
            let ok = await WebDAVBackupDestination.testConnection(
                serverURL: webdavURL,
                username: webdavUsername,
                password: webdavPassword
            )
            isTestingConnection = false
            showAlert(ok ? L10n.tr("backup.webdav.testSuccess") : L10n.tr("backup.webdav.testFailed"))
        }
    }

    private func chooseBackupDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = LocalBackupDestination.backupDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        LocalBackupDestination.setBackupDirectory(url)
    }

    private func openBackupDirectory() {
        let path = LocalBackupDestination.backupDirectory.path
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        }
    }


    private func showAlert(_ message: String) {
        alertMessage = message
        isAlertPresented = true
    }

}

// MARK: - Restore Sheet (standalone view, loads data in onAppear)

private struct RestoreSheetView: View {
    @Binding var isPresented: Bool
    @Binding var pendingRestore: (backup: BackupMetadata, strategy: RestoreStrategy)?
    @Binding var showRestoreConfirm: Bool
    @State private var backups: [BackupMetadata] = []
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.tr("backup.restore.title"))
                .font(.headline)

            if isLoading {
                ProgressView()
                    .padding(.vertical, 20)
            } else if backups.isEmpty {
                Text(L10n.tr("backup.restore.empty"))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                List(backups, id: \.fileName) { backup in
                    restoreRow(backup)
                }
                .frame(height: min(CGFloat(backups.count) * 60 + 20, 400))
            }

            Button(L10n.tr("action.cancel")) { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(minWidth: 420)
        .onAppear { loadBackups() }
    }

    private func restoreRow(_ backup: BackupMetadata) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(backup.createdAt, style: .date)
                    Text(backup.createdAt, style: .time)
                }
                .font(.body)
                Text(backupSubtitle(backup))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu(L10n.tr("backup.restore")) {
                Button(L10n.tr("backup.restore.merge")) {
                    isPresented = false
                    pendingRestore = (backup, .merge)
                    showRestoreConfirm = true
                }
                Button(L10n.tr("backup.restore.overwrite"), role: .destructive) {
                    isPresented = false
                    pendingRestore = (backup, .overwrite)
                    showRestoreConfirm = true
                }
            }
            .fixedSize()
        }
    }

    private func loadBackups() {
        let destination = BackupScheduler.shared.buildDestination()
        Task { @MainActor in
            do {
                backups = try await destination.list()
            } catch {
                backups = []
            }
            isLoading = false
        }
    }

    private func backupSubtitle(_ backup: BackupMetadata) -> String {
        let size = formattedSize(backup.fileSize)
        if backup.itemCount > 0 {
            return "\(backup.itemCount) items · \(size)"
        }
        return size
    }

    private func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
