// BackupImporter.swift
// Handles importing a JSON backup created by BackupExporter.

import Foundation
import SwiftData

private enum ImportBatchDetailView_PreviewHelpers {
    static func perBatchPreviewDirectory(for batch: ImportBatch) -> URL? {
        let fm = FileManager.default
        if let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
            return caches.appendingPathComponent("StatementPreviews", isDirectory: true)
                .appendingPathComponent(batch.id.uuidString, isDirectory: true)
        }
        return nil
    }
}

struct BackupImportSummary: Sendable {
    var settingsUpdated: Bool = false
    var accountsInserted = 0
    var accountsUpdated = 0
    var batchesInserted = 0
    var batchesUpdated = 0
    var balanceSnapsInserted = 0
    var balanceSnapsUpdated = 0
    var csvMappingsInserted = 0
    var csvMappingsUpdated = 0
    var cashFlowsInserted = 0
    var cashFlowsUpdated = 0
    var linksInserted = 0
    var linksUpdated = 0
    var transactionsSkipped = 0
    var holdingsSkipped = 0
}

enum BackupImporter {
    static func importBackup(wrapper: FileWrapper, context: ModelContext, settings: SettingsStore) throws -> BackupImportSummary {
        // Find and read manifest.json
        guard let files = wrapper.fileWrappers,
              let manifest = files["manifest.json"],
              let manifestData = manifest.regularFileContents else {
            throw NSError(domain: "BackupImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing manifest.json in backup."])
        }
        var summary = try importBackup(data: manifestData, context: context, settings: settings)

        // Locate statements directory
        if let statements = files["statements"], statements.isDirectory, let children = statements.fileWrappers {
            // For each batch folder, expect <batchID>/<sourceFileName>
            for (batchIDString, batchFolder) in children where batchFolder.isDirectory {
                guard let batchUUID = UUID(uuidString: batchIDString), let batchChildren = batchFolder.fileWrappers else { continue }
                // Find the batch by id
                let pred = #Predicate<ImportBatch> { $0.id == batchUUID }
                let fetch = FetchDescriptor<ImportBatch>(predicate: pred)
                let batches = (try? context.fetch(fetch)) ?? []
                guard let batch = batches.first else { continue }
                // Expect a single file (prefer .pdf)
                if let pdfEntry = batchChildren.values.first(where: { ($0.preferredFilename ?? "").lowercased().hasSuffix(".pdf") }),
                   let data = pdfEntry.regularFileContents {
                    // Write into per-batch cache and update sourceFileLocalPath
                    if let dir = ImportBatchDetailView_PreviewHelpers.perBatchPreviewDirectory(for: batch) {
                        let fm = FileManager.default
                        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                        let dest = dir.appendingPathComponent(pdfEntry.preferredFilename ?? "statement.pdf")
                        try? data.write(to: dest, options: .atomic)
                        batch.sourceFileLocalPath = dest.path
                        try? context.save()
                    }
                }
            }
        }
        return summary
    }

    static func importBackup(data: Data, context: ModelContext, settings: SettingsStore) throws -> BackupImportSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(DataBackup.self, from: data)

        var summary = BackupImportSummary()

        // Update settings
        settings.currencyCode = backup.settings.currencyCode
        settings.importAutoApplyMappings = backup.settings.importAutoApplyMappings
        settings.creditCardFlipDefault = backup.settings.creditCardFlipDefault
        settings.defaultPayoffStrategyRaw = backup.settings.defaultPayoffStrategyRaw
        settings.useNetForDebtBudgetDefault = backup.settings.useNetForDebtBudgetDefault
        settings.showHintBars = backup.settings.showHintBars
        settings.hapticsEnabled = backup.settings.hapticsEnabled
        summary.settingsUpdated = true

        // Preload existing objects into maps by id
        let existingAccounts: [UUID: Account] = {
            let all = (try? context.fetch(FetchDescriptor<Account>())) ?? []
            return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        }()
        var accountMap = existingAccounts // mutable for newly inserted

        let existingBatches: [UUID: ImportBatch] = {
            let all = (try? context.fetch(FetchDescriptor<ImportBatch>())) ?? []
            return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        }()
        var batchMap = existingBatches

        let existingBalances: [UUID: BalanceSnapshot] = {
            let all = (try? context.fetch(FetchDescriptor<BalanceSnapshot>())) ?? []
            return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        }()
        var balanceMap = existingBalances

        let existingMappings: [UUID: CSVColumnMapping] = {
            let all = (try? context.fetch(FetchDescriptor<CSVColumnMapping>())) ?? []
            return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        }()
        var mappingMap = existingMappings

        let existingCashFlows: [UUID: CashFlowItem] = {
            let all = (try? context.fetch(FetchDescriptor<CashFlowItem>())) ?? []
            return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        }()
        var cashMap = existingCashFlows

        // Accounts (upsert)
        for dto in backup.accounts {
            if let existing = accountMap[dto.id] {
                existing.name = dto.name
                existing.typeRaw = dto.typeRaw
                existing.institutionName = dto.institutionName
                existing.currencyCode = dto.currencyCode
                existing.last4 = dto.last4
                existing.createdAt = dto.createdAt
                existing.loanTerms = dto.loanTerms
                existing.creditCardPaymentModeRaw = dto.creditCardPaymentModeRaw
                summary.accountsUpdated += 1
            } else {
                let acct = Account(
                    id: dto.id,
                    name: dto.name,
                    type: Account.AccountType(rawValue: dto.typeRaw) ?? .other,
                    institutionName: dto.institutionName,
                    currencyCode: dto.currencyCode,
                    last4: dto.last4,
                    createdAt: dto.createdAt
                )
                acct.loanTerms = dto.loanTerms
                acct.creditCardPaymentModeRaw = dto.creditCardPaymentModeRaw
                context.insert(acct)
                accountMap[dto.id] = acct
                summary.accountsInserted += 1
            }
        }

        // Import batches (upsert)
        for dto in backup.importBatches {
            if let existing = batchMap[dto.id] {
                existing.createdAt = dto.createdAt
                existing.label = dto.label
                existing.sourceFileName = dto.sourceFileName
                existing.parserId = dto.parserId
                summary.batchesUpdated += 1
            } else {
                let b = ImportBatch(id: dto.id, createdAt: dto.createdAt, label: dto.label, sourceFileName: dto.sourceFileName, parserId: dto.parserId)
                context.insert(b)
                batchMap[dto.id] = b
                summary.batchesInserted += 1
            }
        }

        // CSV mappings (upsert)
        for dto in backup.csvMappings {
            if let existing = mappingMap[dto.id] {
                existing.label = dto.label
                existing.mappings = dto.mappings
                existing.amountMode = dto.amountMode
                existing.parsingOptions = dto.parsingOptions
                summary.csvMappingsUpdated += 1
            } else {
                let m = CSVColumnMapping(id: dto.id, label: dto.label, mappings: dto.mappings, amountMode: dto.amountMode, parsingOptions: dto.parsingOptions)
                context.insert(m)
                mappingMap[dto.id] = m
                summary.csvMappingsInserted += 1
            }
        }

        // Cash flow items (upsert)
        for dto in backup.cashFlowItems {
            if let existing = cashMap[dto.id] {
                existing.kindRaw = dto.kindRaw
                existing.name = dto.name
                existing.amount = dto.amount
                existing.frequencyRaw = dto.frequencyRaw
                existing.dayOfMonth = dto.dayOfMonth
                existing.firstPaymentDate = dto.firstPaymentDate
                existing.notes = dto.notes
                existing.account = dto.accountID.flatMap { accountMap[$0] }
                existing.createdAt = dto.createdAt
                summary.cashFlowsUpdated += 1
            } else {
                let item = CashFlowItem(
                    id: dto.id,
                    kind: CashFlowItem.Kind(rawValue: dto.kindRaw) ?? .bill,
                    name: dto.name,
                    amount: dto.amount,
                    frequency: PaymentFrequency(rawValue: dto.frequencyRaw) ?? .monthly,
                    dayOfMonth: dto.dayOfMonth,
                    firstPaymentDate: dto.firstPaymentDate,
                    notes: dto.notes,
                    account: dto.accountID.flatMap { accountMap[$0] },
                    createdAt: dto.createdAt
                )
                context.insert(item)
                cashMap[dto.id] = item
                summary.cashFlowsInserted += 1
            }
        }

        // Balance snapshots (upsert)
        for dto in backup.balanceSnapshots {
            let acct = dto.accountID.flatMap { accountMap[$0] }
            let batch = dto.importBatchID.flatMap { batchMap[$0] }
            if let existing = balanceMap[dto.id] {
                existing.asOfDate = dto.asOfDate
                existing.balance = dto.balance
                existing.interestRateAPR = dto.interestRateAPR
                existing.interestRateScale = dto.interestRateScale
                existing.isExcluded = dto.isExcluded
                existing.isUserModified = dto.isUserModified
                existing.account = acct
                existing.importBatch = batch
                summary.balanceSnapsUpdated += 1
            } else {
                let snap = BalanceSnapshot(
                    id: dto.id,
                    asOfDate: dto.asOfDate,
                    balance: dto.balance,
                    interestRateAPR: dto.interestRateAPR,
                    interestRateScale: dto.interestRateScale,
                    account: acct,
                    importBatch: batch,
                    isUserCreated: false,
                    isExcluded: dto.isExcluded,
                    isUserModified: dto.isUserModified
                )
                context.insert(snap)
                balanceMap[dto.id] = snap
                summary.balanceSnapsInserted += 1
            }
        }

        // Asset-Liability Links (upsert by asset+liability)
        do {
            let allLinks = try context.fetch(FetchDescriptor<AssetLiabilityLink>())
            for dto in backup.assetLiabilityLinks {
                guard let asset = accountMap[dto.assetID], let liability = accountMap[dto.liabilityID] else { continue }
                if let existing = allLinks.first(where: { $0.asset.id == asset.id && $0.liability.id == liability.id && $0.endDate == nil }) {
                    existing.startDate = dto.startDate
                    existing.endDate = dto.endDate
                    summary.linksUpdated += 1
                } else {
                    let link = AssetLiabilityLink(asset: asset, liability: liability, startDate: dto.startDate, endDate: dto.endDate)
                    context.insert(link)
                    summary.linksInserted += 1
                }
            }
        } catch {
            // Ignore link import errors silently
        }

        // Transactions & Holdings are currently skipped to avoid initializer mismatches.
        summary.transactionsSkipped = backup.transactions.count
        summary.holdingsSkipped = backup.holdingSnapshots.count

        try context.save()
        return summary
    }
}
