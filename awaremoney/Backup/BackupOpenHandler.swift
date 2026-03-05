import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Foundation
import Combine

@MainActor
final class BackupOpenCoordinator: ObservableObject {
    @Published var alertMessage: String? = nil

    nonisolated func handleOpen(url: URL, context: ModelContext, settings: SettingsStore) async {
        guard url.pathExtension == "ambackup" || url.pathExtension == "json" else {
            await MainActor.run { self.alertMessage = "Unsupported file type." }
            return
        }
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let summary = try await BackupImporter.importBackup(data: data, context: context, settings: settings)
            let text = await Self.makeSummaryText(from: summary)
            await MainActor.run { self.alertMessage = text }
        } catch {
            await MainActor.run { self.alertMessage = "Import failed: \(error.localizedDescription)" }
        }
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
        if s.transactionsSkipped > 0 { parts.append("Transactions skipped: \(s.transactionsSkipped)") }
        if s.holdingsSkipped > 0 { parts.append("Holdings skipped: \(s.holdingsSkipped)") }
        return parts.joined(separator: "\n")
    }
}
