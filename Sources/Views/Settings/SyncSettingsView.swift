import SwiftUI

struct SyncSettingsView: View {
    @AppStorage(SyncSettings.enabledKey) private var syncEnabled = false
    @AppStorage(SyncSettings.clientIDKey) private var syncClientID = ""
    @AppStorage(SyncSettings.serverURLKey) private var syncServerURL = SyncSettings.defaultServerURL
    @AppStorage(SyncSettings.tokenKey) private var syncToken = ""
    @AppStorage(SyncSettings.intervalMinutesKey) private var syncIntervalMinutes = SyncSettings.defaultIntervalMinutes
    @AppStorage(SyncSettings.batchSizeKey) private var syncBatchSize = SyncSettings.defaultBatchSize
    @AppStorage(SyncSettings.autoPausedKey) private var syncAutoPaused = false
    @AppStorage(SyncEncryption.enabledKey) private var syncEncryptionEnabled = false
    @AppStorage(SyncEncryption.passphraseKey) private var encryptionPassphrase = ""

    @State private var alertMessage = ""
    @State private var isAlertPresented = false
    @State private var showRegenerateConfirm = false
    @State private var showDisableEncryptionConfirm = false
    @State private var showFullSyncConfirm = false
    @State private var isFullSyncing = false
    @State private var encryptionDraftEnabled = false
    @State private var isApplyingEncryption = false
    @State private var remoteClients: [SyncRemoteClient] = []
    @State private var selectedPeers: Set<String> = SyncSettings.selectedPeerIDs
    @State private var isLoadingPeers = false
    @State private var peersLoadError: String?
    @State private var peerPassphraseTarget: SyncRemoteClient?
    @State private var peerPassphraseInput = ""
    @State private var peerPassphraseError: String?

    private var scheduler: SyncScheduler { SyncScheduler.shared }

    private var canSyncNow: Bool {
        !syncServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !syncToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !scheduler.isSyncing
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            syncForm
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if syncClientID.isEmpty {
                syncClientID = SyncSettings.ensureClientID()
            }
            if syncServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                syncServerURL = SyncSettings.defaultServerURL
            }
            selectedPeers = SyncSettings.selectedPeerIDs
            SyncSettings.pruneSelectedPeers(matching: displayClientID)
            selectedPeers = SyncSettings.selectedPeerIDs
            encryptionDraftEnabled = syncEncryptionEnabled
            syncIntervalMinutes = SyncSettings.intervalMinutes
            if canRefreshPeers {
                Task { await refreshRemoteClients() }
            }
        }
        .alert(alertMessage, isPresented: $isAlertPresented) {
            Button(L10n.tr("action.confirm")) {}
        }
        .alert(L10n.tr("sync.regenerateClientID.confirm.title"), isPresented: $showRegenerateConfirm) {
            Button(L10n.tr("action.cancel"), role: .cancel) {}
            Button(L10n.tr("sync.regenerateClientID.confirm.ok"), role: .destructive) {
                let oldID = syncClientID
                syncClientID = SyncSettings.regenerateClientID()
                SyncSettings.pruneSelectedPeers(matching: oldID)
                selectedPeers = SyncSettings.selectedPeerIDs
                scheduler.reschedule()
            }
        } message: {
            Text(L10n.tr("sync.regenerateClientID.confirm.message"))
        }
        .alert(L10n.tr("sync.encryption.disable"), isPresented: $showDisableEncryptionConfirm) {
            Button(L10n.tr("action.cancel"), role: .cancel) {}
            Button(L10n.tr("sync.encryption.disable"), role: .destructive) {
                Task { await applyEncryptionSettings(enabled: false) }
            }
        } message: {
            Text(L10n.tr("sync.encryption.disable.confirm"))
        }
        .alert(L10n.tr("sync.fullSync.confirm.title"), isPresented: $showFullSyncConfirm) {
            Button(L10n.tr("action.cancel"), role: .cancel) {}
            Button(L10n.tr("sync.fullSync.confirm.ok"), role: .destructive) {
                Task { await performFullSync() }
            }
        } message: {
            Text(L10n.tr("sync.fullSync.confirm.message"))
        }
        .alert(L10n.tr("sync.peers.passphrase.title"), isPresented: peerPassphrasePresented) {
            SecureField(L10n.tr("sync.peers.passphrase.placeholder"), text: $peerPassphraseInput)
            Button(L10n.tr("action.cancel"), role: .cancel) {
                peerPassphraseTarget = nil
                peerPassphraseInput = ""
                peerPassphraseError = nil
            }
            Button(L10n.tr("action.confirm")) {
                confirmPeerPassphrase()
            }
        } message: {
            if let peerPassphraseError, !peerPassphraseError.isEmpty {
                Text(peerPassphraseError)
            } else {
                Text(L10n.tr("sync.peers.passphrase.prompt"))
            }
        }
    }

    private var syncForm: some View {
        Form {
            Section {
                Text(L10n.tr("sync.description"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.tr("sync.identity")) {
                LabeledContent(L10n.tr("sync.clientID")) {
                    HStack(spacing: 8) {
                        Text(displayClientID)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(L10n.tr("sync.copyClientID")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(displayClientID, forType: .string)
                        }
                        .pointerCursor()
                        Button(L10n.tr("sync.regenerateClientID")) {
                            showRegenerateConfirm = true
                        }
                        .pointerCursor()
                    }
                }
            }

            Section(L10n.tr("sync.server")) {
                TextField(L10n.tr("sync.serverURL"), text: $syncServerURL)
                TextField(L10n.tr("sync.token"), text: $syncToken)
                    .font(.system(.body, design: .monospaced))
            }

            encryptionSection

            peersSection

            Section(L10n.tr("sync.schedule")) {
                Toggle(L10n.tr("sync.enable"), isOn: $syncEnabled)
                    .onChange(of: syncEnabled) {
                        if syncEnabled {
                            syncAutoPaused = false
                        }
                        scheduler.reschedule()
                    }

                if syncEnabled {
                    LabeledContent(L10n.tr("sync.interval")) {
                        HStack(spacing: 6) {
                            TextField("", value: $syncIntervalMinutes, format: .number)
                                .frame(width: 72)
                                .multilineTextAlignment(.trailing)
                            Text(L10n.tr("sync.interval.minutes"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: syncIntervalMinutes) {
                        syncIntervalMinutes = SyncSettings.clampIntervalMinutes(syncIntervalMinutes)
                        scheduler.reschedule()
                    }
                    Text(L10n.tr("sync.interval.hint"))
                        .font(.callout)
                        .foregroundStyle(.tertiary)

                    if syncAutoPaused {
                        Text(L10n.tr("sync.autoPaused"))
                            .font(.callout)
                            .foregroundStyle(.orange)
                        Button(L10n.tr("sync.resumeAuto")) {
                            syncAutoPaused = false
                            scheduler.resumeAutoSync()
                        }
                        .pointerCursor()
                    }
                }

                Picker(L10n.tr("sync.batchSize"), selection: $syncBatchSize) {
                    ForEach(SyncBatchSizeOption.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                Text(L10n.tr("sync.batchSize.hint"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }

            Section(L10n.tr("sync.status")) {
                statusInfo
                actionButtons
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var peerPassphrasePresented: Binding<Bool> {
        Binding(
            get: { peerPassphraseTarget != nil },
            set: { if !$0 { peerPassphraseTarget = nil; peerPassphraseInput = ""; peerPassphraseError = nil } }
        )
    }

    @ViewBuilder
    private var encryptionSection: some View {
        Section(L10n.tr("sync.encryption")) {
            Text(L10n.tr("sync.encryption.description"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(L10n.tr("sync.encryption.enabled"), isOn: $encryptionDraftEnabled)

            if encryptionDraftEnabled || syncEncryptionEnabled {
                LabeledContent(L10n.tr("sync.encryption.passphrase")) {
                    RevealableSecureField(text: $encryptionPassphrase)
                }
            }

            if syncEncryptionEnabled {
                Text(L10n.tr("sync.encryption.active"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Button {
                if !encryptionDraftEnabled && syncEncryptionEnabled {
                    showDisableEncryptionConfirm = true
                } else if encryptionDraftEnabled {
                    Task { await applyEncryptionSettings(enabled: true) }
                }
            } label: {
                HStack {
                    Text(L10n.tr("sync.encryption.apply"))
                    Spacer()
                    if isApplyingEncryption {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .disabled(!canApplyEncryption || isApplyingEncryption)
            .pointerCursor()
        }
    }

    private var canApplyEncryption: Bool {
        guard canRefreshPeers else { return false }
        if !encryptionDraftEnabled && syncEncryptionEnabled {
            return true
        }
        if encryptionDraftEnabled {
            return !encryptionPassphrase.isEmpty
        }
        return false
    }

    private var displayClientID: String {
        syncClientID.isEmpty ? SyncSettings.ensureClientID() : syncClientID
    }

    private var canRefreshPeers: Bool {
        !syncServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !syncToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var peerCandidates: [SyncRemoteClient] {
        remoteClients.filter { !SyncSettings.clientIDsMatch($0.clientID, displayClientID) }
    }

    @ViewBuilder
    private var peersSection: some View {
        Section(L10n.tr("sync.peers")) {
            Text(L10n.tr("sync.peers.description"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task { await refreshRemoteClients() }
            } label: {
                HStack {
                    Text(L10n.tr("sync.peers.refresh"))
                    Spacer()
                    if isLoadingPeers {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(!canRefreshPeers || isLoadingPeers)
            .pointerCursor()

            if let peersLoadError, !peersLoadError.isEmpty {
                Text(peersLoadError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !isLoadingPeers && canRefreshPeers && remoteClients.isEmpty {
                Text(L10n.tr("sync.peers.empty"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            } else if peerCandidates.isEmpty && !remoteClients.isEmpty {
                Text(L10n.tr("sync.peers.onlySelf"))
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }

            ForEach(peerCandidates) { client in
                Toggle(isOn: peerSelectionBinding(for: client)) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(client.displayName)
                                .font(.body)
                            if client.encryptionEnabled {
                                Text(L10n.tr("sync.peers.encrypted"))
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.orange.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                        }
                        Text(L10n.tr("sync.peers.itemCount", client.itemCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if client.needsPeerPassphrase && selectedPeers.contains(client.clientID) {
                            Text(L10n.tr("sync.peers.passphrase.required"))
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Text(client.clientID)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private func peerSelectionBinding(for client: SyncRemoteClient) -> Binding<Bool> {
        Binding(
            get: { selectedPeers.contains(client.clientID) },
            set: { isOn in
                if isOn {
                    if client.needsPeerPassphrase, client.peerEncryptionInfo != nil {
                        peerPassphraseTarget = client
                        peerPassphraseInput = ""
                        peerPassphraseError = nil
                        return
                    }
                    selectedPeers.insert(client.clientID)
                } else {
                    selectedPeers.remove(client.clientID)
                }
                SyncSettings.selectedPeerIDs = selectedPeers
            }
        )
    }

    private func confirmPeerPassphrase() {
        guard let client = peerPassphraseTarget, let info = client.peerEncryptionInfo else { return }
        do {
            try SyncEncryption.savePeerPassphrase(peerPassphraseInput, peerID: client.clientID, info: info)
            selectedPeers.insert(client.clientID)
            SyncSettings.selectedPeerIDs = selectedPeers
            peerPassphraseTarget = nil
            peerPassphraseInput = ""
            peerPassphraseError = nil
        } catch {
            peerPassphraseError = error.localizedDescription
        }
    }

    private func applyEncryptionSettings(enabled: Bool) async {
        guard canRefreshPeers else { return }
        isApplyingEncryption = true
        defer { isApplyingEncryption = false }

        do {
            let resynced = try await SyncEncryption.applyEncryptionChange(
                enabled: enabled,
                passphrase: encryptionPassphrase,
                clientID: displayClientID,
                baseURL: syncServerURL,
                token: syncToken
            )
            syncEncryptionEnabled = enabled
            encryptionDraftEnabled = enabled
            if resynced {
                await scheduler.syncNow()
                if let error = scheduler.lastSyncError, !error.isEmpty {
                    showAlert(L10n.tr("sync.encryption.resync.failed", error))
                    return
                }
                let uploaded = scheduler.lastSyncCount
                showAlert(L10n.tr("sync.encryption.resync.success", uploaded))
            } else {
                showAlert(L10n.tr("sync.encryption.apply.unchanged"))
            }
        } catch {
            showAlert(L10n.tr("sync.encryption.apply.failed", error.localizedDescription))
        }
    }

    private func refreshRemoteClients() async {
        guard canRefreshPeers else { return }
        isLoadingPeers = true
        peersLoadError = nil
        defer { isLoadingPeers = false }

        do {
            remoteClients = try await SyncClientAPI.fetchRemoteClients(
                baseURL: syncServerURL,
                token: syncToken
            )
            for client in remoteClients where client.encryptionEnabled {
                if let info = client.peerEncryptionInfo {
                    if SyncEncryption.peerInfo(for: client.clientID) != info {
                        SyncEncryption.removePeerInfo(for: client.clientID)
                        if selectedPeers.contains(client.clientID) {
                            selectedPeers.remove(client.clientID)
                        }
                    }
                }
            }
            SyncSettings.selectedPeerIDs = selectedPeers
        } catch {
            peersLoadError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var statusInfo: some View {
        if let lastDate = scheduler.lastCompletedAt {
            LabeledContent(L10n.tr("sync.lastSuccess")) {
                Text(lastDate.formatted(date: .abbreviated, time: .standard))
                    .foregroundStyle(.secondary)
            }
            LabeledContent(L10n.tr("sync.lastCount")) {
                Text(L10n.tr("sync.lastCount.detail", scheduler.lastSyncCount, scheduler.lastSyncDownloaded, scheduler.lastSyncDeleted))
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(L10n.tr("sync.neverSynced"))
                .foregroundStyle(.tertiary)
        }

        if let next = scheduler.nextSyncDate, syncEnabled, !syncAutoPaused {
            LabeledContent(L10n.tr("sync.nextRun")) {
                Text(next.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
        }

        if scheduler.isSyncing {
            if scheduler.syncProgressTotal > 0 {
                ProgressView(
                    value: Double(scheduler.syncProgressCurrent),
                    total: Double(scheduler.syncProgressTotal)
                )
                Text("\(scheduler.syncProgressCurrent) / \(scheduler.syncProgressTotal)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }

        if let error = scheduler.lastSyncError, !error.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("sync.lastError"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(L10n.tr("sync.incrementalSync")) {
                performSync()
            }
            .disabled(!canSyncNow || isFullSyncing)
            .pointerCursor()

            Button(L10n.tr("sync.fullSync")) {
                showFullSyncConfirm = true
            }
            .disabled(!canSyncNow || isFullSyncing)
            .pointerCursor()

            if isFullSyncing {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func performSync() {
        Task {
            await scheduler.syncNow()
            if let error = scheduler.lastSyncError, !error.isEmpty {
                showAlert(error)
                return
            }
            let uploaded = scheduler.lastSyncCount
            let downloaded = scheduler.lastSyncDownloaded
            let deleted = scheduler.lastSyncDeleted
            if uploaded == 0 && downloaded == 0 && deleted == 0 {
                showAlert(L10n.tr("sync.success.none"))
            } else {
                showAlert(L10n.tr("sync.success", uploaded, downloaded, deleted))
            }
        }
    }

    private func performFullSync() async {
        guard !isFullSyncing else { return }
        isFullSyncing = true
        defer { isFullSyncing = false }

        do {
            let clientID = displayClientID
            let baseURL = syncServerURL
            let token = syncToken
            let peerIDs = Array(SyncSettings.selectedPeerIDs
                .filter { !SyncSettings.clientIDsMatch($0, clientID) })

            // Purge this client's data and every selected peer's data on the server,
            // then drop local copies of peer items so they get re-imported cleanly.
            try await SyncEngine.purgeAllForFullSync(
                clientID: clientID,
                peerIDs: peerIDs,
                baseURL: baseURL,
                token: token
            )
            SyncEngine.deleteLocalItemsFromPeers(peerIDs: peerIDs, container: scheduler.modelContainer)
            SyncEncryption.resetSyncWatermarks()

            await scheduler.syncNow()
            if let error = scheduler.lastSyncError, !error.isEmpty {
                showAlert(L10n.tr("sync.fullSync.failed", error))
                return
            }
            let uploaded = scheduler.lastSyncCount
            let downloaded = scheduler.lastSyncDownloaded
            let deleted = scheduler.lastSyncDeleted
            if uploaded == 0 && downloaded == 0 && deleted == 0 {
                showAlert(L10n.tr("sync.fullSync.success.none"))
            } else {
                showAlert(L10n.tr("sync.fullSync.success", uploaded, downloaded, deleted))
            }
        } catch {
            showAlert(L10n.tr("sync.fullSync.failed", error.localizedDescription))
        }
    }

    private func showAlert(_ message: String) {
        alertMessage = message
        isAlertPresented = true
    }
}
