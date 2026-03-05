// BackupExporter.swift
// Provides a JSON backup export of key SwiftData models and app settings.

import Foundation
import SwiftData
import UniformTypeIdentifiers

// MARK: - Backup DTOs

struct DataBackup: Codable {
    let version: Int
    let generatedAt: Date
    let settings: SettingsBackup

    let accounts: [AccountDTO]
    let transactions: [TransactionDTO]
    let balanceSnapshots: [BalanceSnapshotDTO]
    let holdingSnapshots: [HoldingSnapshotDTO]
    let importBatches: [ImportBatchDTO]
    let csvMappings: [CSVColumnMappingDTO]
    let cashFlowItems: [CashFlowItemDTO]
    let assetLiabilityLinks: [AssetLiabilityLinkDTO]
}

struct SettingsBackup: Codable {
    let currencyCode: String
    let importAutoApplyMappings: Bool
    let creditCardFlipDefault: Bool
    let defaultPayoffStrategyRaw: String
    let useNetForDebtBudgetDefault: Bool
    let showHintBars: Bool
    let hapticsEnabled: Bool
}

struct AccountDTO: Codable {
    let id: UUID
    let name: String
    let typeRaw: String
    let institutionName: String?
    let currencyCode: String
    let last4: String?
    let createdAt: Date
    let loanTerms: LoanTerms?
    let creditCardPaymentModeRaw: String?
}

struct TransactionDTO: Codable {
    let id: UUID
    let accountID: UUID?
    let importBatchID: UUID?
    let datePosted: Date
    let amount: Decimal
    let payee: String
    let memo: String?
    let kindRaw: String?
    let isExcluded: Bool
    let isUserEdited: Bool?
    let isUserModified: Bool
    let originalAmount: Decimal?
    let originalDate: Date?
    let hashKey: String
    let importHashKey: String?
    let symbol: String?
    let quantity: Decimal?
}

struct BalanceSnapshotDTO: Codable {
    let id: UUID
    let accountID: UUID?
    let importBatchID: UUID?
    let asOfDate: Date
    let balance: Decimal
    let interestRateAPR: Decimal?
    let interestRateScale: Int?
    let isExcluded: Bool
    let isUserModified: Bool
}

struct HoldingSnapshotDTO: Codable {
    let id: UUID
    let accountID: UUID?
    let importBatchID: UUID?
    let symbol: String?
    let marketValue: Decimal?
}

struct ImportBatchDTO: Codable {
    let id: UUID
    let createdAt: Date
    let label: String
    let sourceFileName: String
    let parserId: String?
}

struct CSVColumnMappingDTO: Codable {
    let id: UUID
    let label: String?
    let mappings: [CSVColumnMapping.Field: String]
    let amountMode: CSVColumnMapping.AmountMode
    let parsingOptions: CSVColumnMapping.ParsingOptions
}

struct CashFlowItemDTO: Codable {
    let id: UUID
    let kindRaw: String
    let name: String
    let amount: Decimal
    let frequencyRaw: String
    let dayOfMonth: Int?
    let firstPaymentDate: Date?
    let notes: String?
    let accountID: UUID?
    let createdAt: Date
}

struct AssetLiabilityLinkDTO: Codable {
    let assetID: UUID
    let liabilityID: UUID
    let startDate: Date
    let endDate: Date?
}

// MARK: - Backup Exporter

enum BackupExporter {
    /// Builds a JSON backup `Data` and a suggested filename.
    static func makeBackup(context: ModelContext, settings: SettingsStore) throws -> (data: Data, filename: String) {
        // Fetch all model objects
        let accounts: [Account] = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let transactions: [Transaction] = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let balances: [BalanceSnapshot] = (try? context.fetch(FetchDescriptor<BalanceSnapshot>())) ?? []
        let holdings: [HoldingSnapshot] = (try? context.fetch(FetchDescriptor<HoldingSnapshot>())) ?? []
        let batches: [ImportBatch] = (try? context.fetch(FetchDescriptor<ImportBatch>())) ?? []
        let mappings: [CSVColumnMapping] = (try? context.fetch(FetchDescriptor<CSVColumnMapping>())) ?? []
        let cashFlows: [CashFlowItem] = (try? context.fetch(FetchDescriptor<CashFlowItem>())) ?? []
        let links: [AssetLiabilityLink] = (try? context.fetch(FetchDescriptor<AssetLiabilityLink>())) ?? []

        // Map to DTOs
        let accountDTOs: [AccountDTO] = accounts.map { acct in
            AccountDTO(
                id: acct.id,
                name: acct.name,
                typeRaw: acct.typeRaw,
                institutionName: acct.institutionName,
                currencyCode: acct.currencyCode,
                last4: acct.last4,
                createdAt: acct.createdAt,
                loanTerms: acct.loanTerms,
                creditCardPaymentModeRaw: acct.creditCardPaymentModeRaw
            )
        }

        let txDTOs: [TransactionDTO] = transactions.map { tx in
            TransactionDTO(
                id: tx.id,
                accountID: tx.account?.id,
                importBatchID: tx.importBatch?.id,
                datePosted: tx.datePosted,
                amount: tx.amount,
                payee: tx.payee,
                memo: tx.memo,
                kindRaw: (tx as AnyObject).value(forKey: "kindRaw") as? String, // best-effort if available
                isExcluded: tx.isExcluded,
                isUserEdited: (tx as AnyObject).value(forKey: "isUserEdited") as? Bool,
                isUserModified: tx.isUserModified,
                originalAmount: tx.originalAmount,
                originalDate: tx.originalDate,
                hashKey: tx.hashKey,
                importHashKey: tx.importHashKey,
                symbol: tx.symbol,
                quantity: tx.quantity
            )
        }

        let balDTOs: [BalanceSnapshotDTO] = balances.map { bs in
            BalanceSnapshotDTO(
                id: bs.id,
                accountID: bs.account?.id,
                importBatchID: bs.importBatch?.id,
                asOfDate: bs.asOfDate,
                balance: bs.balance,
                interestRateAPR: bs.interestRateAPR,
                interestRateScale: bs.interestRateScale,
                isExcluded: bs.isExcluded,
                isUserModified: bs.isUserModified
            )
        }

        let holdDTOs: [HoldingSnapshotDTO] = holdings.map { hs in
            HoldingSnapshotDTO(
                id: hs.id,
                accountID: hs.account?.id,
                importBatchID: hs.importBatch?.id,
                symbol: hs.security?.symbol,
                marketValue: hs.marketValue
            )
        }

        let batchDTOs: [ImportBatchDTO] = batches.map { b in
            ImportBatchDTO(
                id: b.id,
                createdAt: b.createdAt,
                label: b.label,
                sourceFileName: b.sourceFileName,
                parserId: b.parserId
            )
        }

        let mappingDTOs: [CSVColumnMappingDTO] = mappings.map { m in
            CSVColumnMappingDTO(
                id: m.id,
                label: m.label,
                mappings: m.mappings,
                amountMode: m.amountMode,
                parsingOptions: m.parsingOptions
            )
        }

        let cashDTOs: [CashFlowItemDTO] = cashFlows.map { c in
            CashFlowItemDTO(
                id: c.id,
                kindRaw: c.kindRaw,
                name: c.name,
                amount: c.amount,
                frequencyRaw: c.frequencyRaw,
                dayOfMonth: c.dayOfMonth,
                firstPaymentDate: c.firstPaymentDate,
                notes: c.notes,
                accountID: c.account?.id,
                createdAt: c.createdAt
            )
        }

        let linkDTOs: [AssetLiabilityLinkDTO] = links.map { link in
            AssetLiabilityLinkDTO(
                assetID: link.asset.id,
                liabilityID: link.liability.id,
                startDate: link.startDate,
                endDate: link.endDate
            )
        }

        let settingsDTO = SettingsBackup(
            currencyCode: settings.currencyCode,
            importAutoApplyMappings: settings.importAutoApplyMappings,
            creditCardFlipDefault: settings.creditCardFlipDefault,
            defaultPayoffStrategyRaw: settings.defaultPayoffStrategyRaw,
            useNetForDebtBudgetDefault: settings.useNetForDebtBudgetDefault,
            showHintBars: settings.showHintBars,
            hapticsEnabled: settings.hapticsEnabled
        )

        let payload = DataBackup(
            version: 1,
            generatedAt: Date(),
            settings: settingsDTO,
            accounts: accountDTOs,
            transactions: txDTOs,
            balanceSnapshots: balDTOs,
            holdingSnapshots: holdDTOs,
            importBatches: batchDTOs,
            csvMappings: mappingDTOs,
            cashFlowItems: cashDTOs,
            assetLiabilityLinks: linkDTOs
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if #available(iOS 15.0, macOS 12.0, *) {
            encoder.outputFormatting.insert(.sortedKeys)
        }
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(payload)
        let filename = BackupExporter.suggestedFilename()
        return (data, filename)
    }

    private static func suggestedFilename() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = df.string(from: Date())
        return "AwareMoney-Backup-\(stamp)"
    }
}

// MARK: - FileDocument wrapper for fileExporter

import SwiftUI

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.awareMoneyBackup] }
    static var writableContentTypes: [UTType] { [.awareMoneyBackup] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: data)
    }
}
