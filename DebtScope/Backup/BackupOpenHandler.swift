import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Foundation
import Combine

@MainActor
final class BackupOpenCoordinator: ObservableObject {
    @Published var alertMessage: String? = nil
    @Published var pendingRestoreSummary: BackupRestorePreflight.RestoreSummary? = nil

    private enum PendingRestore {
        case wrapper(FileWrapper)
        case data(Data)
    }

    private var pendingRestore: PendingRestore? = nil

    func handleOpen(url: URL, context: ModelContext, settings: SettingsStore) async {
        let ext = url.pathExtension.lowercased()
        guard UTType.debtScopeBackupExtensions.contains(ext) || ext == "json" else {
            alertMessage = "Unsupported file type."
            return
        }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            let payload = try Self.readRestorePayload(from: url)
            if BackupRestorePreflight.shouldConfirmRestore(context: context) {
                pendingRestore = payload
                pendingRestoreSummary = try Self.restoreSummary(for: payload, context: context)
            } else {
                let summary = try Self.importRestore(payload, context: context, settings: settings)
                alertMessage = Self.makeSummaryText(from: summary)
            }
        } catch {
            alertMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    func cancelPendingRestore() {
        pendingRestore = nil
        pendingRestoreSummary = nil
    }

    func performPendingRestore(context: ModelContext, settings: SettingsStore) {
        guard let pendingRestore else { return }
        self.pendingRestore = nil
        pendingRestoreSummary = nil

        do {
            let summary = try Self.importRestore(pendingRestore, context: context, settings: settings)
            alertMessage = Self.makeSummaryText(from: summary)
        } catch {
            alertMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private nonisolated static func readRestorePayload(from url: URL) throws -> PendingRestore {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            return .wrapper(try FileWrapper(url: url, options: .immediate))
        }
        return .data(try Data(contentsOf: url))
    }

    private static func importRestore(_ restore: PendingRestore, context: ModelContext, settings: SettingsStore) throws -> BackupImportSummary {
        switch restore {
        case .wrapper(let wrapper):
            return try BackupImporter.importBackup(wrapper: wrapper, context: context, settings: settings)
        case .data(let data):
            return try BackupImporter.importBackup(data: data, context: context, settings: settings)
        }
    }

    private static func restoreSummary(for restore: PendingRestore, context: ModelContext) throws -> BackupRestorePreflight.RestoreSummary {
        let appCounts = BackupRestorePreflight.appDataCounts(context: context)
        let backupCounts: BackupRestorePreflight.BackupDataCounts
        switch restore {
        case .wrapper(let wrapper):
            backupCounts = try BackupRestorePreflight.backupDataCounts(wrapper: wrapper)
        case .data(let data):
            backupCounts = try BackupRestorePreflight.backupDataCounts(data: data)
        }
        return BackupRestorePreflight.restoreSummary(appCounts: appCounts, backupCounts: backupCounts)
    }

    private static func makeSummaryText(from s: BackupImportSummary) -> String {
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
