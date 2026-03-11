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
    let embeddedStatements: [EmbeddedStatementDTO]?
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

struct EmbeddedStatementDTO: Codable {
    let batchID: UUID
    let fileName: String
    let data: Data
}

// MARK: - Backup Exporter

enum BackupExporter {

    /// Collect available statement PDFs for all import batches and return as embedded DTOs.
    private static func collectStatementPDFs(context: ModelContext) -> [EmbeddedStatementDTO] {
        let batches: [ImportBatch] = (try? context.fetch(FetchDescriptor<ImportBatch>())) ?? []
        AMLogging.log("BackupExporter: collectStatementPDFs — batches fetched=\(batches.count)", component: "BackupExporter")
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        var results: [EmbeddedStatementDTO] = []
        for b in batches {
            let fileName = b.sourceFileName
            if fileName.isEmpty || !fileName.lowercased().hasSuffix(".pdf") { continue }
            var sourceURL: URL? = nil
            if let path = b.sourceFileLocalPath, !path.isEmpty, fm.fileExists(atPath: path) {
                sourceURL = URL(fileURLWithPath: path)
            } else if let caches, fm.fileExists(atPath: caches.appendingPathComponent(fileName).path) {
                sourceURL = caches.appendingPathComponent(fileName)
            }
            guard let src = sourceURL, let data = try? Data(contentsOf: src) else { continue }
            results.append(EmbeddedStatementDTO(batchID: b.id, fileName: fileName, data: data))
        }
        AMLogging.log("BackupExporter: collectStatementPDFs — embedded count=\(results.count)", component: "BackupExporter")
        return results
    }

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

        let embeddedStatementDTOs: [EmbeddedStatementDTO] = Self.collectStatementPDFs(context: context)

        AMLogging.log(
            "BackupExporter: preparing manifest — accounts=\(accountDTOs.count) tx=\(txDTOs.count) balances=\(balDTOs.count) holdings=\(holdDTOs.count) batches=\(batchDTOs.count) mappings=\(mappingDTOs.count) cashFlows=\(cashDTOs.count) links=\(linkDTOs.count)",
            component: "BackupExporter"
        )

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
            assetLiabilityLinks: linkDTOs,
            embeddedStatements: embeddedStatementDTOs
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        if #available(iOS 15.0, macOS 12.0, *) {
            encoder.outputFormatting.insert(.sortedKeys)
        }
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(payload)

        AMLogging.log("BackupExporter: manifest encoded — size=\(data.count) bytes", component: "BackupExporter")

        let filename = BackupExporter.suggestedFilename()
        return (data, filename)
    }

    /// Builds a backup package as a directory FileWrapper containing:
    /// - manifest.json (the JSON manifest)
    /// - statements/<batchID>/<sourceFileName> (PDFs when available)
    /// Returns the root FileWrapper and a suggested filename (without extension).
    static func makeBackupPackage(context: ModelContext, settings: SettingsStore) throws -> (wrapper: FileWrapper, filename: String) {
        // Reuse the existing JSON manifest builder
        let (manifestData, filename) = try makeBackup(context: context, settings: settings)
        AMLogging.log("BackupExporter: package build start — manifest size=\(manifestData.count) bytes filename=\(filename)", component: "BackupExporter")
        AMLogging.log("BackupExporter: building package backup", component: "BackupExporter")

        var children: [String: FileWrapper] = [:]
        let manifest = FileWrapper(regularFileWithContents: manifestData)
        manifest.preferredFilename = "manifest.json"
        children["manifest.json"] = manifest

        // Build statements directory
        let statementsDir = FileWrapper(directoryWithFileWrappers: [:])
        statementsDir.preferredFilename = "statements"

        let statementDTOs = Self.collectStatementPDFs(context: context)
        var batchFolders: [UUID: FileWrapper] = [:]
        var embeddedCount = 0
        var includedSummaries: [String] = []
        for dto in statementDTOs {
            let batchID = dto.batchID
            let fileName = dto.fileName
            let data = dto.data
            let batchFolder: FileWrapper
            if let existing = batchFolders[batchID] {
                batchFolder = existing
            } else {
                let folder = FileWrapper(directoryWithFileWrappers: [:])
                folder.preferredFilename = batchID.uuidString
                _ = statementsDir.addFileWrapper(folder)
                batchFolder = folder
                batchFolders[batchID] = folder
            }
            let pdfWrapper = FileWrapper(regularFileWithContents: data)
            pdfWrapper.preferredFilename = fileName
            _ = batchFolder.addFileWrapper(pdfWrapper)
            embeddedCount += 1
            includedSummaries.append("[id=\(batchID), file=\(fileName), bytes=\(data.count)]")
        }

        AMLogging.log("BackupExporter: embedded PDFs summary — count=\(embeddedCount) items=\(includedSummaries.joined(separator: ", "))", component: "BackupExporter")

        AMLogging.log("BackupExporter: statements directory children=\(statementsDir.fileWrappers?.count ?? 0) PDFs included=\(embeddedCount)", component: "BackupExporter")

        // Attach statements directory if it has any children
        if let count = statementsDir.fileWrappers?.count, count > 0 {
            children["statements"] = statementsDir
            AMLogging.log("BackupExporter: attached statements directory to package", component: "BackupExporter")
        }

        let root = FileWrapper(directoryWithFileWrappers: children)
        AMLogging.log("BackupExporter: package build complete (filename=\(filename))", component: "BackupExporter")
        return (root, filename)
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

@MainActor final class BackupPackageDocument: @preconcurrency FileDocument {
    static var readableContentTypes: [UTType] { [.awareMoneyBackup] }
    static var writableContentTypes: [UTType] { [.awareMoneyBackup] }

    let rootWrapper: FileWrapper

    init(wrapper: FileWrapper) { self.rootWrapper = wrapper }

    init(configuration: ReadConfiguration) throws {
        // For exporting, we don't rely on reading; provide an empty directory by default
        self.rootWrapper = configuration.file
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return rootWrapper
    }
}

