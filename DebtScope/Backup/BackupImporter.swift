// BackupImporter.swift
// Handles importing a JSON backup created by BackupExporter.

import Foundation
import SwiftData

private enum ImportBatchDetailView_PreviewHelpers {
    static func perBatchPreviewDirectory(for batch: ImportBatch) -> URL? {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else {
            return nil
        }
        let dir = appSupport
            .appendingPathComponent("StatementPreviews", isDirectory: true)
            .appendingPathComponent(batch.id.uuidString, isDirectory: true)

        // Ensure directory exists and is excluded from iCloud backups
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var dirCopy = dir
            try dirCopy.setResourceValues(resourceValues)
        } catch {
            // Best effort; still return dir
        }

        return dir
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
    var billFundingAllocationsInserted = 0
    var billFundingAllocationsUpdated = 0
    var linksInserted = 0
    var linksUpdated = 0
    var transactionsSkipped = 0
    var holdingsSkipped = 0
}

enum BackupImporter {
    static func importBackup(wrapper: FileWrapper, context: ModelContext, settings: SettingsStore) throws -> BackupImportSummary {
        // Resolve manifest data from a package or a single-file fallback
        let files = wrapper.fileWrappers
        let manifestData: Data
        if let files,
           let manifest = files["manifest.json"],
           let data = manifest.regularFileContents {
            manifestData = data
            AMLogging.log("BackupImporter: manifest.json read from package — size=\(data.count) bytes", component: "BackupImporter")
        } else if !wrapper.isDirectory, let data = wrapper.regularFileContents {
            // Fallback: wrapper is a single file containing the manifest JSON
            manifestData = data
            AMLogging.log("BackupImporter: single-file manifest read — size=\(data.count) bytes", component: "BackupImporter")
        } else {
            throw NSError(domain: "BackupImporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing manifest.json in backup."])
        }

        let summary = try importBackup(data: manifestData, context: context, settings: settings)
        AMLogging.log(
            "BackupImporter: core data import complete — settingsUpdated=\(summary.settingsUpdated) accounts(i=\(summary.accountsInserted), u=\(summary.accountsUpdated)) batches(i=\(summary.batchesInserted), u=\(summary.batchesUpdated)) balances(i=\(summary.balanceSnapsInserted), u=\(summary.balanceSnapsUpdated)) mappings(i=\(summary.csvMappingsInserted), u=\(summary.csvMappingsUpdated)) cashFlows(i=\(summary.cashFlowsInserted), u=\(summary.cashFlowsUpdated)) links(i=\(summary.linksInserted), u=\(summary.linksUpdated)) skipped(tx=\(summary.transactionsSkipped), holdings=\(summary.holdingsSkipped))",
            component: "BackupImporter"
        )

        // Locate statements directory if present in package
        if let files,
           let statements = files["statements"], statements.isDirectory, let children = statements.fileWrappers {
            AMLogging.log("BackupImporter: statements directory found — batchFolderCount=\(children.count)", component: "BackupImporter")
            // For each batch folder, expect <batchID>/<sourceFileName>
            for (batchIDString, batchFolder) in children where batchFolder.isDirectory {
                AMLogging.log("BackupImporter: processing statements folder — idString=\(batchIDString)", component: "BackupImporter")
                guard let batchUUID = UUID(uuidString: batchIDString), let batchChildren = batchFolder.fileWrappers else { continue }
                // Find the batch by id
                let pred = #Predicate<ImportBatch> { $0.id == batchUUID }
                let fetch = FetchDescriptor<ImportBatch>(predicate: pred)
                let batches = (try? context.fetch(fetch)) ?? []
                if let batch = batches.first {
                    AMLogging.log("BackupImporter: inspecting batch folder — childCount=\(batchChildren.count) label=\(batch.label)", component: "BackupImporter")
                    // Expect a single file (prefer .pdf)
                    if let pdfEntry = batchChildren.values.first(where: { ($0.preferredFilename ?? "").lowercased().hasSuffix(".pdf") }),
                       let data = pdfEntry.regularFileContents {
                        AMLogging.log("BackupImporter: PDF entry found — filename=\(pdfEntry.preferredFilename ?? "(unnamed)") bytes=\(data.count)", component: "BackupImporter")
                        // Write into per-batch cache and update sourceFileLocalPath
                        if let dir = ImportBatchDetailView_PreviewHelpers.perBatchPreviewDirectory(for: batch) {
                            AMLogging.log("BackupImporter: per-batch preview directory resolved — path=\(dir.path)", component: "BackupImporter")
                            let fm = FileManager.default
                            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                            let dest = dir.appendingPathComponent(pdfEntry.preferredFilename ?? "statement.pdf")
                            AMLogging.log("BackupImporter: writing PDF cache — dest=\(dest.path)", component: "BackupImporter")
                            try? data.write(to: dest, options: .atomic)
                            AMLogging.log("BackupImporter: cached PDF for batch id=\(batch.id) at path=\(dest.path)", component: "BackupImporter")
                            batch.sourceFileLocalPath = dest.path
                            try? context.save()
                            AMLogging.log("BackupImporter: updated batch.sourceFileLocalPath and saved context for batch id=\(batch.id)", component: "BackupImporter")
                        }
                    } else {
                        AMLogging.log("BackupImporter: no PDF found in statements folder for batch id=\(batch.id) (children=\(batchChildren.keys))", component: "BackupImporter")
                    }
                } else {
                    AMLogging.log("BackupImporter: no ImportBatch found for id=\(String(describing: batchUUID)) — skipping folder", component: "BackupImporter")
                    continue
                }
            }
        }

        // Notify UI to refresh after restoring data and caching PDFs
        NotificationCenter.default.post(name: .accountsDidChange, object: nil)
        NotificationCenter.default.post(name: .transactionsDidChange, object: nil)

        return summary
    }

    static func importBackup(data: Data, context: ModelContext, settings: SettingsStore) throws -> BackupImportSummary {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(DataBackup.self, from: data)
        AMLogging.log("BackupImporter: data manifest decoded — version=\(backup.version) accounts=\(backup.accounts.count) tx=\(backup.transactions.count) balances=\(backup.balanceSnapshots.count) holdings=\(backup.holdingSnapshots.count) batches=\(backup.importBatches.count) mappings=\(backup.csvMappings.count) cashFlows=\(backup.cashFlowItems.count) fundingAllocations=\(backup.billFundingAllocations?.count ?? 0) links=\(backup.assetLiabilityLinks.count) embedded=\(backup.embeddedStatements?.count ?? 0)", component: "BackupImporter")

        var summary = BackupImportSummary()

        // Update settings
        settings.currencyCode = backup.settings.currencyCode
        settings.importAutoApplyMappings = backup.settings.importAutoApplyMappings
        settings.creditCardFlipDefault = backup.settings.creditCardFlipDefault
        settings.defaultPayoffStrategyRaw = backup.settings.defaultPayoffStrategyRaw
        settings.useNetForDebtBudgetDefault = backup.settings.useNetForDebtBudgetDefault
        settings.showHintBars = backup.settings.showHintBars
        settings.hapticsEnabled = backup.settings.hapticsEnabled

        let defaults = UserDefaults.standard
        if let value = backup.settings.baselineBudgetSourceRaw {
            defaults.set(value, forKey: "baselineBudgetSourceRaw")
        }
        if let value = backup.settings.useFixedDebtBudget {
            defaults.set(value, forKey: "useFixedDebtBudget")
        }
        if let value = backup.settings.debtBudgetOverrideAmount {
            defaults.set(value, forKey: "debtBudgetOverrideAmount")
        }
        if let value = backup.settings.lastFixedDebtBudgetAmount {
            defaults.set(value, forKey: "lastFixedDebtBudgetAmount")
        }
        if let value = backup.settings.includeNonMonthlyIncomeSpreads {
            defaults.set(value, forKey: "includeNonMonthlyIncomeSpreads")
        }
        if let value = backup.settings.oneTimeIncomeDefaultSpreadMonths {
            defaults.set(value, forKey: "oneTimeIncomeDefaultSpreadMonths")
        }
        if let value = backup.settings.debtPlanStartModeRaw {
            defaults.set(value, forKey: "debtPlanStartModeRaw")
        }
        if let value = backup.settings.debtPlanStartDateEpoch {
            defaults.set(value, forKey: "debtPlanStartDate")
        }
        if let value = backup.settings.debtPaymentReinvestmentRate {
            defaults.set(value, forKey: "debtPaymentReinvestmentRate")
        }

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

        let existingFundingAllocations: [UUID: BillFundingAllocation] = {
            let all = (try? context.fetch(FetchDescriptor<BillFundingAllocation>())) ?? []
            return Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        }()
        var fundingAllocationMap = existingFundingAllocations

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

        // Restore embedded statement PDFs (if present) now that batches exist
        if let embedded = backup.embeddedStatements {
            AMLogging.log("BackupImporter: embedded statements in manifest — count=\(embedded.count)", component: "BackupImporter")
            let fm = FileManager.default
            for item in embedded {
                guard let batch = batchMap[item.batchID] else {
                    AMLogging.log("BackupImporter: embedded PDF skipped — no batch found for id=\(item.batchID)", component: "BackupImporter")
                    continue
                }
                if let dir = ImportBatchDetailView_PreviewHelpers.perBatchPreviewDirectory(for: batch) {
                    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent(item.fileName)
                    try? item.data.write(to: dest, options: .atomic)
                    batch.sourceFileLocalPath = dest.path
                    try? context.save()
                    AMLogging.log("BackupImporter: restored embedded PDF for batch id=\(batch.id) at path=\(dest.path)", component: "BackupImporter")
                }
            }
        } else {
            AMLogging.log("BackupImporter: no embedded statements in manifest", component: "BackupImporter")
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
                existing.ssaWednesday = dto.ssaWednesday
                existing.account = dto.accountID.flatMap { accountMap[$0] }
                existing.createdAt = dto.createdAt
                if let reserveBalance = dto.reserveBalance {
                    existing.reserveBalance = reserveBalance
                }
                if let reserveCycleStart = dto.reserveCycleStart {
                    existing.reserveCycleStart = reserveCycleStart
                }
                if let reserveLastSeededCycleStart = dto.reserveLastSeededCycleStart {
                    existing.reserveLastSeededCycleStart = reserveLastSeededCycleStart
                }
                if let reserveAutoEnabled = dto.reserveAutoEnabled {
                    existing.reserveAutoEnabled = reserveAutoEnabled
                }
                existing.fundingIncomeID = dto.fundingIncomeID
                if let fundingAmount = dto.fundingAmount {
                    existing.fundingAmount = fundingAmount
                }
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
                    ssaWednesday: dto.ssaWednesday,
                    account: dto.accountID.flatMap { accountMap[$0] },
                    createdAt: dto.createdAt,
                    reserveBalance: dto.reserveBalance ?? 0,
                    reserveCycleStart: dto.reserveCycleStart,
                    reserveLastSeededCycleStart: dto.reserveLastSeededCycleStart,
                    reserveAutoEnabled: dto.reserveAutoEnabled ?? false,
                    fundingIncomeID: dto.fundingIncomeID,
                    fundingAmount: dto.fundingAmount ?? 0
                )
                context.insert(item)
                cashMap[dto.id] = item
                summary.cashFlowsInserted += 1
            }
        }

        // Bill funding allocations (upsert)
        for dto in backup.billFundingAllocations ?? [] {
            if let existing = fundingAllocationMap[dto.id] {
                existing.billID = dto.billID
                existing.incomeID = dto.incomeID
                existing.amount = dto.amount
                existing.createdAt = dto.createdAt
                summary.billFundingAllocationsUpdated += 1
            } else {
                let allocation = BillFundingAllocation(
                    id: dto.id,
                    billID: dto.billID,
                    incomeID: dto.incomeID,
                    amount: dto.amount,
                    createdAt: dto.createdAt
                )
                context.insert(allocation)
                fundingAllocationMap[dto.id] = allocation
                summary.billFundingAllocationsInserted += 1
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
        AMLogging.log(
            "BackupImporter: data import complete — settingsUpdated=\(summary.settingsUpdated) accounts(i=\(summary.accountsInserted), u=\(summary.accountsUpdated)) batches(i=\(summary.batchesInserted), u=\(summary.batchesUpdated)) balances(i=\(summary.balanceSnapsInserted), u=\(summary.balanceSnapsUpdated)) mappings(i=\(summary.csvMappingsInserted), u=\(summary.csvMappingsUpdated)) cashFlows(i=\(summary.cashFlowsInserted), u=\(summary.cashFlowsUpdated)) links(i=\(summary.linksInserted), u=\(summary.linksUpdated)) skipped(tx=\(summary.transactionsSkipped), holdings=\(summary.holdingsSkipped))",
            component: "BackupImporter"
        )

        // Notify UI to refresh after core data import completes
        NotificationCenter.default.post(name: .accountsDidChange, object: nil)
        NotificationCenter.default.post(name: .transactionsDidChange, object: nil)

        return summary
    }

    static func importBackup(at url: URL, context: ModelContext, settings: SettingsStore) throws -> BackupImportSummary {
        AMLogging.log("BackupImporter: opening backup at URL — path=\(url.path)", component: "BackupImporter")
        let wrapper = try FileWrapper(url: url, options: .immediate)
        return try importBackup(wrapper: wrapper, context: context, settings: settings)
    }
}
