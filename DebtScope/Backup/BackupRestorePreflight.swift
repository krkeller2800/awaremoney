import Foundation
import SwiftData

struct BackupRestorePreflight {
    struct AppDataCounts {
        let accounts: Int
        let transactions: Int
        let balances: Int
        let holdings: Int
        let batches: Int
        let csvMappings: Int
        let cashFlowItems: Int
        let billFundingAllocations: Int
        let assetLiabilityLinks: Int
        let accountImportMappings: Int

        var hasRestorableData: Bool {
            accounts > 0
                || transactions > 0
                || balances > 0
                || holdings > 0
                || batches > 0
                || csvMappings > 0
                || cashFlowItems > 0
                || billFundingAllocations > 0
                || assetLiabilityLinks > 0
                || accountImportMappings > 0
        }
    }

    struct BackupDataCounts {
        let generatedAt: Date
        let accounts: Int
        let transactions: Int
        let balances: Int
        let holdings: Int
        let batches: Int
        let csvMappings: Int
        let cashFlowItems: Int
        let billFundingAllocations: Int
        let assetLiabilityLinks: Int
        let embeddedStatements: Int
    }

    struct RestoreSummary: Identifiable {
        let id = UUID()
        let appCounts: AppDataCounts
        let backupCounts: BackupDataCounts
    }

    static let warningLead = "Restoring this backup may add duplicate accounts, transactions, balances, bills, and settings. DebtScope restores backups by adding the backup's saved data to the current app."
    static let warningClose = "Cancel restore unless you are restoring into a fresh app or intentionally adding this backup's data."

    static func appDataCounts(context: ModelContext) -> AppDataCounts {
        AppDataCounts(
            accounts: fetchCount(Account.self, context: context),
            transactions: fetchCount(Transaction.self, context: context),
            balances: fetchCount(BalanceSnapshot.self, context: context),
            holdings: fetchCount(HoldingSnapshot.self, context: context),
            batches: fetchCount(ImportBatch.self, context: context),
            csvMappings: fetchCount(CSVColumnMapping.self, context: context),
            cashFlowItems: fetchCount(CashFlowItem.self, context: context),
            billFundingAllocations: fetchCount(BillFundingAllocation.self, context: context),
            assetLiabilityLinks: fetchCount(AssetLiabilityLink.self, context: context),
            accountImportMappings: fetchCount(AccountImportMapping.self, context: context)
        )
    }

    static func backupDataCounts(data: Data) throws -> BackupDataCounts {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(DataBackup.self, from: data)
        return BackupDataCounts(
            generatedAt: backup.generatedAt,
            accounts: backup.accounts.count,
            transactions: backup.transactions.count,
            balances: backup.balanceSnapshots.count,
            holdings: backup.holdingSnapshots.count,
            batches: backup.importBatches.count,
            csvMappings: backup.csvMappings.count,
            cashFlowItems: backup.cashFlowItems.count,
            billFundingAllocations: backup.billFundingAllocations?.count ?? 0,
            assetLiabilityLinks: backup.assetLiabilityLinks.count,
            embeddedStatements: backup.embeddedStatements?.count ?? 0
        )
    }

    static func backupDataCounts(wrapper: FileWrapper) throws -> BackupDataCounts {
        let data = try manifestData(from: wrapper)
        return try backupDataCounts(data: data)
    }

    static func shouldConfirmRestore(context: ModelContext) -> Bool {
        appDataCounts(context: context).hasRestorableData
    }

    static func restoreSummary(appCounts: AppDataCounts, backupCounts: BackupDataCounts) -> RestoreSummary {
        RestoreSummary(appCounts: appCounts, backupCounts: backupCounts)
    }

    static func appSummaryRows(for counts: AppDataCounts) -> [(String, Int)] {
        [
            ("Accounts", counts.accounts),
            ("Transactions", counts.transactions),
            ("Balances", counts.balances),
            ("Holdings", counts.holdings),
            ("Imports", counts.batches),
            ("Bills & income", counts.cashFlowItems),
            ("Bill funding", counts.billFundingAllocations),
            ("Mappings", counts.csvMappings + counts.accountImportMappings),
            ("Asset links", counts.assetLiabilityLinks)
        ].filter { $0.1 > 0 }
    }

    static func backupSummaryRows(for counts: BackupDataCounts) -> [(String, Int)] {
        [
            ("Accounts", counts.accounts),
            ("Transactions", counts.transactions),
            ("Balances", counts.balances),
            ("Holdings", counts.holdings),
            ("Imports", counts.batches),
            ("Bills & income", counts.cashFlowItems),
            ("Bill funding", counts.billFundingAllocations),
            ("Mappings", counts.csvMappings),
            ("Asset links", counts.assetLiabilityLinks),
            ("Statement files", counts.embeddedStatements)
        ].filter { $0.1 > 0 }
    }

    static func formattedBackupDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }


    private static func manifestData(from wrapper: FileWrapper) throws -> Data {
        if let files = wrapper.fileWrappers,
           let manifest = files["manifest.json"],
           let data = manifest.regularFileContents {
            return data
        }
        if !wrapper.isDirectory, let data = wrapper.regularFileContents {
            return data
        }
        throw NSError(domain: "BackupRestorePreflight", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing manifest.json in backup."])
    }

    private static func fetchCount<T: PersistentModel>(_ type: T.Type, context: ModelContext) -> Int {
        (try? context.fetch(FetchDescriptor<T>()).count) ?? 0
    }
}
