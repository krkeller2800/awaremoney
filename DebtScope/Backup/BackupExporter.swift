// BackupExporter.swift
// Provides a JSON backup export of key SwiftData models and app settings.

import Foundation
import SwiftData
import UniformTypeIdentifiers
import CryptoKit

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
    let billFundingAllocations: [BillFundingAllocationDTO]?
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
    let baselineBudgetSourceRaw: String?
    let useFixedDebtBudget: Bool?
    let debtBudgetOverrideAmount: Double?
    let lastFixedDebtBudgetAmount: Double?
    let includeNonMonthlyIncomeSpreads: Bool?
    let oneTimeIncomeDefaultSpreadMonths: Int?
    let debtPlanStartModeRaw: String?
    let debtPlanStartDateEpoch: Double?
    let debtPaymentReinvestmentRate: Double?
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
    let ssaWednesday: Int?
    let accountID: UUID?
    let createdAt: Date
    let reserveBalance: Decimal?
    let reserveCycleStart: Date?
    let reserveLastSeededCycleStart: Date?
    let reserveAutoEnabled: Bool?
    let fundingIncomeID: UUID?
    let fundingAmount: Decimal?
}

struct BillFundingAllocationDTO: Codable {
    let id: UUID
    let billID: UUID
    let incomeID: UUID
    let amount: Decimal
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

    /// Deterministically derive a UUID from an arbitrary string (first 16 bytes of SHA256)
    private static func deterministicUUID(from string: String) -> UUID {
        let data = Data(string.utf8)
        let digest = SHA256.hash(data: data)
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Surrogate ID based on SwiftData persistentModelID so we can avoid touching model.id
    private static func surrogateID<T: PersistentModel>(for model: T) -> UUID {
        let s = String(describing: model.persistentModelID)
        return deterministicUUID(from: s)
    }

    /// Safely reflect a property by name without relying on KVC. Returns nil if the key isn't present.
    private static func reflectValue<T>(_ object: Any, key: String, as type: T.Type) -> T? {
        var mirror: Mirror? = Mirror(reflecting: object)
        while let m = mirror {
            if let match = m.children.first(where: { $0.label == key }) {
                return match.value as? T
            }
            mirror = m.superclassMirror
        }
        return nil
    }

    /// Collect available statement PDFs for all import batches and return as embedded DTOs.
    private static func collectStatementPDFs(context: ModelContext) -> [EmbeddedStatementDTO] {
        let batches: [ImportBatch] = (try? context.fetch(FetchDescriptor<ImportBatch>())) ?? []
        AMLogging.log("BackupExporter: collectStatementPDFs — batches fetched=\(batches.count)", component: "BackupExporter")

        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
        var results: [EmbeddedStatementDTO] = []

        func perBatchPreviewDirectory(for id: UUID) -> URL? {
            guard let caches else { return nil }
            return caches.appendingPathComponent("StatementPreviews", isDirectory: true)
                .appendingPathComponent(id.uuidString, isDirectory: true)
        }

        for b in batches {
            let surrogate = surrogateID(for: b)
            let fileName = b.sourceFileName
            let isPDF = !fileName.isEmpty && fileName.lowercased().hasSuffix(".pdf")
            guard isPDF else {
                AMLogging.log("BackupExporter: skip batch sid=\(surrogate) — non-PDF sourceFileName='\(fileName)'", component: "BackupExporter")
                continue
            }

            var sourceURL: URL? = nil

            // 1) Preferred: explicit per-batch local path
            if let path = b.sourceFileLocalPath, !path.isEmpty, fm.fileExists(atPath: path) {
                sourceURL = URL(fileURLWithPath: path)
                AMLogging.log("BackupExporter: using sourceFileLocalPath for batch sid=\(surrogate) path=\(path)", component: "BackupExporter")
            }

            // 2) Legacy fallback: Caches/<sourceFileName>
            if sourceURL == nil, let caches {
                let legacy = caches.appendingPathComponent(fileName)
                if fm.fileExists(atPath: legacy.path) {
                    sourceURL = legacy
                    AMLogging.log("BackupExporter: using legacy Caches path for batch sid=\(surrogate) path=\(legacy.path)", component: "BackupExporter")
                }
            }

            // 3) New fallback: per-batch preview directory by convention
            if sourceURL == nil, let dir = perBatchPreviewDirectory(for: b.id) {
                let expected = dir.appendingPathComponent(fileName)
                if fm.fileExists(atPath: expected.path) {
                    sourceURL = expected
                    AMLogging.log("BackupExporter: using per-batch preview path for batch sid=\(surrogate) path=\(expected.path)", component: "BackupExporter")
                } else if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil),
                          let anyPDF = items.first(where: { $0.lastPathComponent.lowercased().hasSuffix(".pdf") }) {
                    // Heuristic: if the exact name isn't present, pick any PDF in the per-batch folder
                    sourceURL = anyPDF
                    AMLogging.log("BackupExporter: using first discovered PDF in per-batch dir for batch sid=\(surrogate) path=\(anyPDF.path)", component: "BackupExporter")
                } else {
                    AMLogging.log("BackupExporter: no PDF found in per-batch dir for batch sid=\(surrogate) dir=\(dir.path)", component: "BackupExporter")
                }
            }

            guard let src = sourceURL else {
                AMLogging.log("BackupExporter: skipped batch sid=\(surrogate) — cached PDF not found for '\(fileName)'", component: "BackupExporter")
                continue
            }

            guard let data = try? Data(contentsOf: src) else {
                AMLogging.log("BackupExporter: failed to read PDF data for batch sid=\(surrogate) at \(src.path)", component: "BackupExporter")
                continue
            }

            results.append(EmbeddedStatementDTO(batchID: surrogate, fileName: src.lastPathComponent, data: data))
        }

        AMLogging.log("BackupExporter: collectStatementPDFs — embedded count=\(results.count)", component: "BackupExporter")
        return results
    }

    /// Builds a JSON backup `Data` and a suggested filename.
    static func makeBackup(context: ModelContext, settings: SettingsStore, includeEmbeddedStatements: Bool = true) throws -> (data: Data, filename: String) {
        // Fetch all model objects
        let accounts: [Account] = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let transactions: [Transaction] = (try? context.fetch(FetchDescriptor<Transaction>())) ?? []
        let balances: [BalanceSnapshot] = (try? context.fetch(FetchDescriptor<BalanceSnapshot>())) ?? []
        let holdings: [HoldingSnapshot] = (try? context.fetch(FetchDescriptor<HoldingSnapshot>())) ?? []
        let batches: [ImportBatch] = (try? context.fetch(FetchDescriptor<ImportBatch>())) ?? []
        let mappings: [CSVColumnMapping] = (try? context.fetch(FetchDescriptor<CSVColumnMapping>())) ?? []
        let cashFlows: [CashFlowItem] = (try? context.fetch(FetchDescriptor<CashFlowItem>())) ?? []
        let billFundingAllocations: [BillFundingAllocation] = (try? context.fetch(FetchDescriptor<BillFundingAllocation>())) ?? []
        let links: [AssetLiabilityLink] = (try? context.fetch(FetchDescriptor<AssetLiabilityLink>())) ?? []

        // Map to DTOs
        let accountDTOs: [AccountDTO] = accounts.map { acct in
            AccountDTO(
                id: surrogateID(for: acct),
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
                id: surrogateID(for: tx),
                accountID: tx.account.map { surrogateID(for: $0) },
                importBatchID: tx.importBatch.map { surrogateID(for: $0) },
                datePosted: tx.datePosted,
                amount: tx.amount,
                payee: tx.payee,
                memo: tx.memo,
                kindRaw: tx.kind.rawValue,
                isExcluded: tx.isExcluded,
                isUserEdited: Self.reflectValue(tx, key: "isUserEdited", as: Bool.self),
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
                id: surrogateID(for: bs),
                accountID: bs.account.map { surrogateID(for: $0) },
                importBatchID: bs.importBatch.map { surrogateID(for: $0) },
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
                id: surrogateID(for: hs),
                accountID: hs.account.map { surrogateID(for: $0) },
                importBatchID: hs.importBatch.map { surrogateID(for: $0) },
                symbol: hs.security?.symbol,
                marketValue: hs.marketValue
            )
        }

        let batchDTOs: [ImportBatchDTO] = batches.map { b in
            ImportBatchDTO(
                id: surrogateID(for: b),
                createdAt: b.createdAt,
                label: b.label,
                sourceFileName: b.sourceFileName,
                parserId: b.parserId
            )
        }

        let mappingDTOs: [CSVColumnMappingDTO] = mappings.map { m in
            CSVColumnMappingDTO(
                id: surrogateID(for: m),
                label: m.label,
                mappings: m.mappings,
                amountMode: m.amountMode,
                parsingOptions: m.parsingOptions
            )
        }

        let cashFlowExportIDs = Dictionary(uniqueKeysWithValues: cashFlows.map { ($0.id, surrogateID(for: $0)) })

        let cashDTOs: [CashFlowItemDTO] = cashFlows.map { c in
            CashFlowItemDTO(
                id: surrogateID(for: c),
                kindRaw: c.kindRaw,
                name: c.name,
                amount: c.amount,
                frequencyRaw: c.frequencyRaw,
                dayOfMonth: c.dayOfMonth,
                firstPaymentDate: c.firstPaymentDate,
                notes: c.notes,
                ssaWednesday: c.ssaWednesday,
                accountID: c.account.map { surrogateID(for: $0) },
                createdAt: c.createdAt,
                reserveBalance: c.reserveBalance,
                reserveCycleStart: c.reserveCycleStart,
                reserveLastSeededCycleStart: c.reserveLastSeededCycleStart,
                reserveAutoEnabled: c.reserveAutoEnabled,
                fundingIncomeID: c.fundingIncomeID.flatMap { cashFlowExportIDs[$0] },
                fundingAmount: c.fundingAmount
            )
        }

        let fundingDTOs: [BillFundingAllocationDTO] = billFundingAllocations.compactMap { allocation in
            guard let billID = cashFlowExportIDs[allocation.billID],
                  let incomeID = cashFlowExportIDs[allocation.incomeID] else {
                return nil
            }
            return BillFundingAllocationDTO(
                id: allocation.id,
                billID: billID,
                incomeID: incomeID,
                amount: allocation.amount,
                createdAt: allocation.createdAt
            )
        }

        let linkDTOs: [AssetLiabilityLinkDTO] = links.map { link in
            AssetLiabilityLinkDTO(
                assetID: surrogateID(for: link.asset),
                liabilityID: surrogateID(for: link.liability),
                startDate: link.startDate,
                endDate: link.endDate
            )
        }

        let embeddedStatementDTOs: [EmbeddedStatementDTO]? = includeEmbeddedStatements ? Self.collectStatementPDFs(context: context) : nil

        AMLogging.log(
            "BackupExporter: preparing manifest — accounts=\(accountDTOs.count) tx=\(txDTOs.count) balances=\(balDTOs.count) holdings=\(holdDTOs.count) batches=\(batchDTOs.count) mappings=\(mappingDTOs.count) cashFlows=\(cashDTOs.count) fundingAllocations=\(fundingDTOs.count) links=\(linkDTOs.count) embedded=\(embeddedStatementDTOs?.count ?? 0)",
            component: "BackupExporter"
        )

        let defaults = UserDefaults.standard
        let settingsDTO = SettingsBackup(
            currencyCode: settings.currencyCode,
            importAutoApplyMappings: settings.importAutoApplyMappings,
            creditCardFlipDefault: settings.creditCardFlipDefault,
            defaultPayoffStrategyRaw: settings.defaultPayoffStrategyRaw,
            useNetForDebtBudgetDefault: settings.useNetForDebtBudgetDefault,
            showHintBars: settings.showHintBars,
            hapticsEnabled: settings.hapticsEnabled,
            baselineBudgetSourceRaw: defaults.string(forKey: "baselineBudgetSourceRaw") ?? "recurringNet",
            useFixedDebtBudget: defaults.bool(forKey: "useFixedDebtBudget"),
            debtBudgetOverrideAmount: defaults.double(forKey: "debtBudgetOverrideAmount"),
            lastFixedDebtBudgetAmount: defaults.double(forKey: "lastFixedDebtBudgetAmount"),
            includeNonMonthlyIncomeSpreads: defaults.object(forKey: "includeNonMonthlyIncomeSpreads") as? Bool ?? true,
            oneTimeIncomeDefaultSpreadMonths: defaults.object(forKey: "oneTimeIncomeDefaultSpreadMonths") as? Int ?? 12,
            debtPlanStartModeRaw: defaults.string(forKey: "debtPlanStartModeRaw") ?? "currentInputs",
            debtPlanStartDateEpoch: defaults.double(forKey: "debtPlanStartDate"),
            debtPaymentReinvestmentRate: defaults.object(forKey: "debtPaymentReinvestmentRate") as? Double ?? 1
        )

        let payload = DataBackup(
            version: 4,
            generatedAt: Date(),
            settings: settingsDTO,
            accounts: accountDTOs,
            transactions: txDTOs,
            balanceSnapshots: balDTOs,
            holdingSnapshots: holdDTOs,
            importBatches: batchDTOs,
            csvMappings: mappingDTOs,
            cashFlowItems: cashDTOs,
            billFundingAllocations: fundingDTOs,
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
        let (manifestData, filename) = try makeBackup(context: context, settings: settings, includeEmbeddedStatements: false)
        let pkgExt = "dsbackup" // enforce the known-good extension
        let filenameWithExt = filename.hasSuffix(".\(pkgExt)") ? filename : "\(filename).\(pkgExt)"
        AMLogging.log("BackupExporter: package build start — manifest size=\(manifestData.count) bytes filename=\(filename)", component: "BackupExporter")
        AMLogging.log("BackupExporter: building package backup (embedded PDFs excluded to avoid base64 bloat)", component: "BackupExporter")

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
        root.preferredFilename = filenameWithExt
        AMLogging.log("BackupExporter: package build complete (filename=\(filename))", component: "BackupExporter")
        return (root, filenameWithExt)
    }

    private static func suggestedFilename() -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = df.string(from: Date())
        return "DebtScope-Backup-\(stamp)"
    }
}

// MARK: - FileDocument wrapper for fileExporter

import SwiftUI

@MainActor final class BackupPackageDocument: @preconcurrency FileDocument {
    static var readableContentTypes: [UTType] { [.debtScopeBackup] }
    static var writableContentTypes: [UTType] { [.debtScopeBackup] }

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
