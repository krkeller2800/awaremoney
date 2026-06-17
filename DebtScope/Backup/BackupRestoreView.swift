import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

struct BackupRestoreView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var backupCoordinator: BackupOpenCoordinator
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var purchases = PurchaseManager.shared

    @State private var showPaywall = false

    // Export
    @State private var backupDoc: BackupPackageDocument? = nil
    @State private var showExporter = false

    // Import
    @State private var showImporter = false
    @State private var pendingRestore: PendingRestore? = nil
    @State private var pendingRestoreSummary: BackupRestorePreflight.RestoreSummary? = nil

    private enum PendingRestore {
        case wrapper(FileWrapper)
        case data(Data)
    }

    private var restoreAllowedContentTypes: [UTType] {
        [.debtScopeBackup, .json, .data]
    }

    // Share
    @State private var shareURL: URL? = nil
    private struct ShareItem: Identifiable {
        let url: URL
        var id: String { url.path }
    }
    @State private var shareItem: ShareItem? = nil

    var body: some View {
        NavigationStack {
            List {
                premiumSupportSection

                Section("Backup & Restore") {
                    Button {
                        do {
                            let (wrapper, _) = try BackupExporter.makeBackupPackage(context: modelContext, settings: settings)
                            self.backupDoc = BackupPackageDocument(wrapper: wrapper)
                            self.showExporter = true
                        } catch {
                            AMLogging.error("Backup export failed: \(error.localizedDescription)", component: "BackupRestoreView")
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "externaldrive")
                            Text("Export Backup…")
                        }
                    }

                    Button {
                        do {
                            let (data, _) = try BackupExporter.makeBackup(context: modelContext, settings: settings)
                            let df = DateFormatter()
                            df.dateFormat = "yyyy-MM-dd_HHmmss"
                            let name = "DebtScope-Backup-\(df.string(from: Date())).ambackup"
                            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                            try? FileManager.default.removeItem(at: tmp)
                            try data.write(to: tmp, options: .atomic)
                            self.shareURL = tmp
                            self.shareItem = ShareItem(url: tmp)
                        } catch {
                            AMLogging.error("Backup share build failed: \(error.localizedDescription)", component: "BackupRestoreView")
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share Backup…")
                        }
                    }

                    Button {
                        showImporter = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.down.doc")
                            Text("Restore from Backup…")
                        }
                    }
                }
            }
            .navigationTitle("Backup & Restore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileExporter(
                isPresented: $showExporter,
                document: backupDoc,
                contentType: .debtScopeBackupPackage,
                defaultFilename: "DebtScope-Backup"
            ) { result in
                switch result {
                case .success:
                    AMLogging.log("Backup exported successfully", component: "BackupRestoreView")
                case .failure(let err):
                    AMLogging.error("Backup export error: \(err.localizedDescription)", component: "BackupRestoreView")
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: restoreAllowedContentTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    prepareRestore(from: url)
                case .failure(let err):
                    backupCoordinator.alertMessage = "Import canceled: \(err.localizedDescription)"
                }
            }
            .sheet(item: $pendingRestoreSummary) { summary in
                BackupRestoreConfirmationView(summary: summary) {
                    pendingRestore = nil
                    pendingRestoreSummary = nil
                } onRestore: {
                    if let pendingRestore {
                        performRestore(pendingRestore)
                    }
                    pendingRestore = nil
                    pendingRestoreSummary = nil
                }
            }
            .sheet(item: $shareItem, onDismiss: {
                if let url = shareURL {
                    try? FileManager.default.removeItem(at: url)
                    shareURL = nil
                }
            }) { item in
                ActivityView(activityItems: [item.url])
                    .ignoresSafeArea()
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(source: .backupRestore)
                    .environmentObject(PurchaseManager.shared)
            }
        }
    }

    private var premiumSupportSection: some View {
        Section("Premium") {
            Label {
                Text("Premium supports unlimited imports and long-term local data portability.")
            } icon: {
                Image(systemName: "star.circle.fill")
                    .foregroundStyle(.yellow)
            }

            Text("Backup export, sharing, and restore remain available below.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if !purchases.hasPremiumAccess {
                Button {
                    showPaywall = true
                } label: {
                    Label("Upgrade to Premium", systemImage: "star.fill")
                }
            }
        }
    }

    private func prepareRestore(from url: URL) {
        guard isSupportedRestoreURL(url) else {
            backupCoordinator.alertMessage = "Unsupported file type."
            return
        }

        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }

        do {
            let payload = try readRestorePayload(from: url)
            if BackupRestorePreflight.shouldConfirmRestore(context: modelContext) {
                pendingRestore = payload
                pendingRestoreSummary = try restoreSummary(for: payload)
            } else {
                performRestore(payload)
            }
        } catch {
            backupCoordinator.alertMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func isSupportedRestoreURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return UTType.debtScopeBackupExtensions.contains(ext) || ext == "json"
    }

    private func readRestorePayload(from url: URL) throws -> PendingRestore {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            return .wrapper(try FileWrapper(url: url, options: .immediate))
        }
        return .data(try Data(contentsOf: url))
    }

    private func restoreSummary(for restore: PendingRestore) throws -> BackupRestorePreflight.RestoreSummary {
        let appCounts = BackupRestorePreflight.appDataCounts(context: modelContext)
        let backupCounts: BackupRestorePreflight.BackupDataCounts
        switch restore {
        case .wrapper(let wrapper):
            backupCounts = try BackupRestorePreflight.backupDataCounts(wrapper: wrapper)
        case .data(let data):
            backupCounts = try BackupRestorePreflight.backupDataCounts(data: data)
        }
        return BackupRestorePreflight.restoreSummary(appCounts: appCounts, backupCounts: backupCounts)
    }

    private func performRestore(_ restore: PendingRestore) {
        do {
            let summary: BackupImportSummary
            switch restore {
            case .wrapper(let wrapper):
                summary = try BackupImporter.importBackup(wrapper: wrapper, context: modelContext, settings: settings)
            case .data(let data):
                summary = try BackupImporter.importBackup(data: data, context: modelContext, settings: settings)
            }
            backupCoordinator.alertMessage = makeSummaryText(from: summary)
        } catch {
            backupCoordinator.alertMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    fileprivate func makeSummaryText(from s: BackupImportSummary) -> String {
        var parts: [String] = []
        if s.settingsUpdated { parts.append("Settings updated") }
        parts.append("Accounts: +\(s.accountsInserted), \(s.accountsUpdated) updated")
        parts.append("Batches: +\(s.batchesInserted), \(s.batchesUpdated) updated")
        parts.append("Balances: +\(s.balanceSnapsInserted), \(s.balanceSnapsUpdated) updated")
        parts.append("CSV Mappings: +\(s.csvMappingsInserted), \(s.csvMappingsUpdated) updated")
        parts.append("Cash Flow Items: +\(s.cashFlowsInserted), \(s.cashFlowsUpdated) updated")
        parts.append("Links: +\(s.linksInserted), \(s.linksUpdated) updated")
        parts.append("Transactions: +\(s.transactionsInserted), \(s.transactionsUpdated) updated")
        if s.transactionsSkipped > 0 { parts.append("Transactions skipped: \(s.transactionsSkipped)") }
        if s.holdingsSkipped > 0 { parts.append("Holdings skipped: \(s.holdingsSkipped)") }
        return parts.joined(separator: "\n")
    }
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    var excludedActivityTypes: [UIActivity.ActivityType]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        vc.excludedActivityTypes = excludedActivityTypes
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // no-op
    }
}

#Preview {
    BackupRestoreView()
        .environmentObject(SettingsStore())
        .environmentObject(BackupOpenCoordinator())
}
