import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import UIKit

struct BackupRestoreView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var backupCoordinator: BackupOpenCoordinator
    @Environment(\.dismiss) private var dismiss

    // Export
    @State private var backupDoc: BackupPackageDocument? = nil
    @State private var showExporter = false

    // Import
    @State private var showImporter = false

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
                Section("Backup & Restore") {
                    Button {
                        do {
                            let (wrapper, filename) = try BackupExporter.makeBackupPackage(context: modelContext, settings: settings)
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
                            let name = "AwareMoney-Backup-\(df.string(from: Date())).ambackup"
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
                contentType: .awareMoneyBackup,
                defaultFilename: "AwareMoney-Backup"
            ) { result in
                switch result {
                case .success:
                    AMLogging.always("Backup exported successfully", component: "BackupRestoreView")
                case .failure(let err):
                    AMLogging.error("Backup export error: \(err.localizedDescription)", component: "BackupRestoreView")
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [UTType.awareMoneyBackup, .json, .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let started = url.startAccessingSecurityScopedResource()
                    defer { if started { url.stopAccessingSecurityScopedResource() } }
                    do {
                        // Try to read as a file package (directory). If not a directory, fall back to Data.
                        var isDir: ObjCBool = false
                        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                        if isDir.boolValue {
                            let wrapper = try FileWrapper(url: url, options: .immediate)
                            let summary = try BackupImporter.importBackup(wrapper: wrapper, context: modelContext, settings: settings)
                            backupCoordinator.alertMessage = makeSummaryText(from: summary)
                        } else {
                            let data = try Data(contentsOf: url)
                            let summary = try BackupImporter.importBackup(data: data, context: modelContext, settings: settings)
                            backupCoordinator.alertMessage = makeSummaryText(from: summary)
                        }
                    } catch {
                        backupCoordinator.alertMessage = "Import failed: \(error.localizedDescription)"
                    }
                case .failure(let err):
                    backupCoordinator.alertMessage = "Import canceled: \(err.localizedDescription)"
                }
            }
            .alert("Import Backup", isPresented: Binding(get: { backupCoordinator.alertMessage != nil }, set: { if !$0 { backupCoordinator.alertMessage = nil } })) {
                Button("OK", role: .cancel) { backupCoordinator.alertMessage = nil }
            } message: {
                Text(backupCoordinator.alertMessage ?? "")
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
