//
//  ImportViewModel.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import Foundation
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Combine

@MainActor
final class ImportViewModel: ObservableObject {
    @Published var staged: StagedImport?
    @Published var errorMessage: String?
    @Published var selectedAccountID: UUID?
    @Published var newAccountName: String = ""
    @Published var newAccountType: Account.AccountType = .checking
    @Published var userInstitutionName: String = ""
    @Published var mappingSession: MappingSession? // non-nil when user needs to map columns
    @Published var infoMessage: String?
    @Published var isPDFTransactionsImporterPresented: Bool = false
    @Published var isImporting: Bool = false

    private let importer = StatementImporter()

    private let parsers: [StatementParser]

    init(parsers: [StatementParser]) {
        self.parsers = parsers
    }

    // Resolve the currently selected account ID into a live Account in the provided context
    func resolveSelectedAccount(in context: ModelContext) throws -> Account? {
        guard let id = selectedAccountID else { return nil }
        let predicate = #Predicate<Account> { $0.id == id }
        var descriptor = FetchDescriptor<Account>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    func handlePickedURL(_ url: URL) {
        AMLogging.log("Picked URL: \(url.absoluteString)", component: "ImportViewModel")  // DEBUG LOG

        // Show spinner immediately
        self.isImporting = true

        Task.detached { [weak self] in
            guard let self else { return }
            // Begin security-scoped access for files picked from the Files app
            let didStart = url.startAccessingSecurityScopedResource()
            defer {
                if didStart { url.stopAccessingSecurityScopedResource() }
            }

            do {
                // If the file is in iCloud, trigger a download if needed
                if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
                   values.isUbiquitousItem == true {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                }

                // Run the coordinator on main actor to get confidence/warnings (method is @MainActor)
                var coordinatorResult: StatementImportResult? = nil
                do {
                    coordinatorResult = try await MainActor.run {
                        try self.importer.importStatement(from: url, prefer: .summaryOnly)
                    }
                } catch {
                    // Ignore coordinator errors here; continue with legacy path
                }

                // Extract rows/headers (heavy work)
                let ext = url.pathExtension.lowercased()
                let rowsAndHeaders: ([[String]], [String])
                if ext == "pdf" {
                    rowsAndHeaders = try await MainActor.run {
                        try PDFStatementExtractor.parse(url: url)
                    }
                } else {
                    let data = try Data(contentsOf: url)
                    rowsAndHeaders = try await MainActor.run {
                        try CSV.read(data: data)
                    }
                }
                let (rows, headers) = rowsAndHeaders

                await MainActor.run { [coordinatorResult] in
                    guard !headers.isEmpty else {
                        self.errorMessage = ImportError.invalidCSV.localizedDescription
                        self.infoMessage = nil
                        self.staged = nil
                        self.isImporting = false
                        return
                    }
                    AMLogging.always("Import picked — ext: \(ext), rows: \(rows.count), headers: \(headers)", component: "ImportViewModel")

                    let matchingParsers = self.parsers.compactMap { $0.canParse(headers: headers) ? String(describing: type(of: $0)) : nil }
                    AMLogging.always("Parsers matching headers: \(matchingParsers)", component: "ImportViewModel")
                    if let parser = self.parsers.first(where: { $0.canParse(headers: headers) }) {
                        AMLogging.log("Using parser: \(String(describing: type(of: parser)))", component: "ImportViewModel")  // DEBUG LOG
                        do {
                            var stagedImport = try parser.parse(rows: rows, headers: headers)
                            stagedImport.sourceFileName = url.lastPathComponent
                            AMLogging.always("Parser '\(String(describing: type(of: parser)))' produced — tx: \(stagedImport.transactions.count), holdings: \(stagedImport.holdings.count), balances: \(stagedImport.balances.count)", component: "ImportViewModel")
                            if stagedImport.transactions.isEmpty && (!stagedImport.holdings.isEmpty || !stagedImport.balances.isEmpty) {
                                AMLogging.always("Note: Parser produced no transactions but did produce holdings/balances. This is expected for statement-summary files.", component: "ImportViewModel")
                            }

                            // Guess account type
                            let sampleForGuess = Array(rows.prefix(50))
                            if let guessedType = self.guessAccountType(from: stagedImport.sourceFileName, headers: headers, sampleRows: sampleForGuess) {
                                stagedImport.suggestedAccountType = guessedType
                            }
                            if let suggested = stagedImport.suggestedAccountType {
                                self.newAccountType = suggested
                            }

                            self.staged = stagedImport

                            // Build info messages
                            var messages: [String] = []
                            if let res = coordinatorResult {
                                for w in res.warnings { if !messages.contains(w) { messages.append(w) } }
                                if res.source == .pdf && res.confidence <= .low {
                                    let warn = "Low confidence parsing PDF. Consider importing a CSV for best results."
                                    if !messages.contains(warn) { messages.append(warn) }
                                }
                            }
                            if (stagedImport.suggestedAccountType == .brokerage || self.newAccountType == .brokerage),
                               stagedImport.balances.isEmpty,
                               stagedImport.holdings.isEmpty,
                               !stagedImport.transactions.isEmpty {
                                let hint = "Brokerage activity won't affect Net Worth until you import a statement with balances/holdings or set a starting balance."
                                if !messages.contains(hint) { messages.append(hint) }
                            }
                            self.infoMessage = messages.isEmpty ? nil : messages.joined(separator: "\n")
                        } catch {
                            self.errorMessage = error.localizedDescription
                            self.infoMessage = nil
                            self.staged = nil
                        }
                    } else {
                        AMLogging.always("No parser matched headers. Starting mapping session. Headers: \(headers)", component: "ImportViewModel")
                        let sample = Array(rows.prefix(10))
                        self.mappingSession = MappingSession(kind: .bank, headers: headers, sampleRows: sample, dateIndex: nil, descriptionIndex: nil, amountIndex: nil, debitIndex: nil, creditIndex: nil, balanceIndex: nil, dateFormat: nil)
                        if let res = coordinatorResult, (!res.warnings.isEmpty || res.confidence <= .low) {
                            var msgs: [String] = []
                            for w in res.warnings { if !msgs.contains(w) { msgs.append(w) } }
                            if res.source == .pdf && res.confidence <= .low {
                                let warn = "Low confidence parsing PDF. Consider importing a CSV for best results."
                                if !msgs.contains(warn) { msgs.append(warn) }
                            }
                            self.infoMessage = msgs.joined(separator: "\n")
                        } else {
                            self.infoMessage = nil
                        }
                    }

                    self.isImporting = false
                }
            } catch {
                await MainActor.run {
                    let userMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    AMLogging.always("Importer error (user-facing): \(userMessage)", component: "ImportViewModel")
                    self.errorMessage = userMessage
                    self.infoMessage = nil
                    self.staged = nil
                    self.isImporting = false
                }
            }
        }
    }

    func handlePickedPDFTransactionsURL(_ url: URL) {
        AMLogging.log("Picked PDF (transactions): \(url.absoluteString)", component: "ImportViewModel")
        self.isImporting = true

        Task.detached { [weak self] in
            guard let self else { return }
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            do {
                // Ensure iCloud download if needed
                if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]), values.isUbiquitousItem == true {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                }

                // Coordinator for confidence/warnings in transactions mode (method is @MainActor)
                var coordinatorResult: StatementImportResult? = nil
                do {
                    coordinatorResult = try await MainActor.run {
                        try self.importer.importStatement(from: url, prefer: .transactions)
                    }
                } catch {
                    // Ignore coordinator errors here; continue with legacy path
                }

                // Use extractor in transactions mode (heavy)
                let (rows, headers) = try await MainActor.run {
                    try PDFStatementExtractor.parse(url: url, mode: .transactions)
                }
                await MainActor.run { [coordinatorResult] in
                    guard !headers.isEmpty else {
                        self.errorMessage = ImportError.unknownFormat.localizedDescription
                        self.infoMessage = nil
                        self.staged = nil
                        self.isImporting = false
                        return
                    }
                    AMLogging.always("PDF Transactions — rows: \(rows.count), headers: \(headers)", component: "ImportViewModel")

                    let parser: StatementParser = PDFBankTransactionsParser()
                    do {
                        var stagedImport = try parser.parse(rows: rows, headers: headers)
                        stagedImport.sourceFileName = url.lastPathComponent

                        // Guess account type (bank/credit card heuristic)
                        let sampleForGuess = Array(rows.prefix(50))
                        if let guessedType = self.guessAccountType(from: stagedImport.sourceFileName, headers: headers, sampleRows: sampleForGuess) {
                            stagedImport.suggestedAccountType = guessedType
                        }
                        if let suggested = stagedImport.suggestedAccountType { self.newAccountType = suggested }

                        self.staged = stagedImport
                        var messages: [String] = ["PDF transactions are experimental. Please review signs before saving."]
                        if let res = coordinatorResult {
                            for w in res.warnings { if !messages.contains(w) { messages.append(w) } }
                            if res.confidence <= .low {
                                let warn = "Low confidence parsing PDF. Consider importing a CSV for best results."
                                if !messages.contains(warn) { messages.append(warn) }
                            }
                        }
                        self.infoMessage = messages.joined(separator: "\n")
                    } catch {
                        self.errorMessage = error.localizedDescription
                        self.infoMessage = nil
                        self.staged = nil
                    }

                    self.isImporting = false
                }
            } catch {
                await MainActor.run {
                    let userMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    AMLogging.always("PDF Transactions importer error (user-facing): \(userMessage)", component: "ImportViewModel")
                    self.errorMessage = userMessage
                    self.infoMessage = nil
                    self.staged = nil
                    self.isImporting = false
                }
            }
        }
    }

    func approveAndSave(context: ModelContext) throws {
        guard let staged else { return }
        AMLogging.log("Approve & Save started", component: "ImportViewModel")  // DEBUG LOG
        AMLogging.log("Staged counts — tx: \(staged.transactions.count), holdings: \(staged.holdings.count), balances: \(staged.balances.count)", component: "ImportViewModel")  // DEBUG LOG

        let batch = ImportBatch(
            label: staged.sourceFileName,
            sourceFileName: staged.sourceFileName,
            parserId: staged.parserId
        )
        context.insert(batch)
        
        let providedInst = userInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenInst = providedInst.isEmpty ? guessInstitutionName(from: staged.sourceFileName) : providedInst
        AMLogging.always("Approve: chosen institution: \(chosenInst ?? "(nil)") from file '\(staged.sourceFileName)'", component: "ImportViewModel")

        // Helper to normalize PDF labels to canonical strings
        func normalizedLabel(_ raw: String?) -> String? {
            guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !s.isEmpty else { return nil }
            if s.contains("checking") { return "checking" }
            if s.contains("savings") { return "savings" }
            return nil
        }
        func typeForLabel(_ label: String?) -> Account.AccountType? {
            switch normalizedLabel(label) {
            case "checking": return .checking
            case "savings": return .savings
            default: return nil
            }
        }

        // Compute included transactions
        let includedTransactions = staged.transactions.filter { ($0.include) }
        let excludedCount = staged.transactions.count - includedTransactions.count

        // Group transactions by source account label (checking/savings). Unlabeled will be handled separately.
        var labeledGroups: [String: [StagedTransaction]] = [:]
        var unlabeled: [StagedTransaction] = []
        for t in includedTransactions {
            if let key = normalizedLabel(t.sourceAccountLabel) {
                labeledGroups[key, default: []].append(t)
            } else {
                unlabeled.append(t)
            }
        }
        AMLogging.always("Approve: label groups => \(labeledGroups.map { "\($0.key): \($0.value.count)" }.joined(separator: ", ")), unlabeled: \(unlabeled.count)", component: "ImportViewModel")

        // Function to resolve or create an account for a given type/institution
        func resolveAccount(ofType resolvedType: Account.AccountType, institutionName: String?, preferExisting existing: Account?) -> Account {
            // If an existing account was provided and matches the type and institution (or institution empty), reuse it
            if let existing {
                if existing.type == resolvedType {
                    if let inst = institutionName, !inst.isEmpty {
                        // If institution provided differs, update or switch to a matching account
                        if let current = existing.institutionName, !current.isEmpty, normalizeInstitutionName(current) != normalizeInstitutionName(inst) {
                            if let found = findAccount(ofType: resolvedType, institutionName: inst, context: context) {
                                AMLogging.always("Switching to existing account for institution: \(inst) and type: \(resolvedType.rawValue)", component: "ImportViewModel")
                                return found
                            } else {
                                AMLogging.always("Creating new account for institution: \(inst) and type: \(resolvedType.rawValue)", component: "ImportViewModel")
                                let acct = Account(
                                    name: inst,
                                    type: resolvedType,
                                    institutionName: inst,
                                    currencyCode: "USD"
                                )
                                context.insert(acct)
                                return acct
                            }
                        } else {
                            // Ensure institution name is set
                            if existing.institutionName == nil || existing.institutionName?.isEmpty == true {
                                existing.institutionName = inst
                            }
                        }
                    }
                    return existing
                }
            }
            // No suitable existing: find by institution, else create
            if let inst = institutionName, let found = findAccount(ofType: resolvedType, institutionName: inst, context: context) {
                AMLogging.always("Reusing existing account for institution: \(inst) and type: \(resolvedType.rawValue)", component: "ImportViewModel")
                return found
            } else {
                let name = institutionName ?? ""
                let acct = Account(
                    name: name,
                    type: resolvedType,
                    institutionName: institutionName,
                    currencyCode: "USD"
                )
                AMLogging.always("Creating new account with institution: \(institutionName ?? "(nil)") and type: \(resolvedType.rawValue)", component: "ImportViewModel")
                context.insert(acct)
                return acct
            }
        }

        // Resolve selected account if any (used as anchor for matching label/type)
        var selectedAccount: Account? = nil
        if let selectedID = selectedAccountID, let fetched = try? {
            let predicate = #Predicate<Account> { $0.id == selectedID }
            var descriptor = FetchDescriptor<Account>(predicate: predicate)
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first
        }() {
            let target = fetched
            AMLogging.always("Selected account before resolution — name: \(target.name), type: \(target.type.rawValue), inst: \(target.institutionName ?? "(nil)")", component: "ImportViewModel")

            // Apply user-selected account type override so it always carries through
            if target.type != self.newAccountType {
                AMLogging.always("Applying user-selected account type override: \(target.type.rawValue) -> \(self.newAccountType.rawValue)", component: "ImportViewModel")
                target.type = self.newAccountType
            }

            if !providedInst.isEmpty {
                AMLogging.always("Applying user-provided institution to selected account: '\(providedInst)'", component: "ImportViewModel")
                target.institutionName = providedInst
            } else if (target.institutionName == nil) || (target.institutionName?.isEmpty == true) {
                AMLogging.always("Filling missing institution on selected account with: \(chosenInst ?? "(nil)")", component: "ImportViewModel")
                if let chosenInst { target.institutionName = chosenInst }
            } else if let chosenInst, let current = target.institutionName, !current.isEmpty, normalizeInstitutionName(current) != normalizeInstitutionName(chosenInst) {
                AMLogging.always("Institution mismatch — selected: \(current), chosen: \(chosenInst).", component: "ImportViewModel")
                // We'll allow per-label account resolution below to create/find matching accounts for other labels
            }
            selectedAccount = target
        }

        // Build accounts per label (checking/savings). If no label groups exist, fall back to single-account path.
        var accountsByLabel: [String: Account] = [:]
        if labeledGroups.isEmpty {
            // Single-account path (original behavior)
            let resolvedType = self.newAccountType
            let account = resolveAccount(ofType: resolvedType, institutionName: chosenInst, preferExisting: selectedAccount)
            AMLogging.log("Resolved account — id: \(account.id), name: \(account.name), type: \(account.type.rawValue), existing tx count: \(account.transactions.count)", component: "ImportViewModel")  // DEBUG LOG
            AMLogging.always("Using account — id: \(account.id), name: \(account.name), type: \(account.type.rawValue), inst: \(account.institutionName ?? "(nil)")", component: "ImportViewModel")
            self.selectedAccountID = account.id
            accountsByLabel["default"] = account
        } else {
            // Multi-account path: resolve an account for each label
            for (label, group) in labeledGroups {
                let resolvedType = typeForLabel(label) ?? self.newAccountType
                let preferExisting: Account? = {
                    // If user selected an account whose type matches this label, prefer it for this label
                    if let sel = selectedAccount, sel.type == resolvedType { return sel }
                    return nil
                }()
                let acct = resolveAccount(ofType: resolvedType, institutionName: chosenInst, preferExisting: preferExisting)
                accountsByLabel[label] = acct
                AMLogging.always("Label '\(label)' -> account id: \(acct.id), name: \(acct.name), type: \(acct.type.rawValue)", component: "ImportViewModel")
                AMLogging.always("Group counts — label: \(label), tx: \(group.count)", component: "ImportViewModel")
            }
            // Assign unlabeled transactions: prefer selected account, else any resolved account, else create default using newAccountType
            if !unlabeled.isEmpty {
                let unlabeledAccount: Account = {
                    if let sel = selectedAccount { return sel }
                    if let any = accountsByLabel.values.first { return any }
                    return resolveAccount(ofType: self.newAccountType, institutionName: chosenInst, preferExisting: nil)
                }()
                accountsByLabel["unlabeled"] = unlabeledAccount
                AMLogging.always("Unlabeled -> account id: \(unlabeledAccount.id), name: \(unlabeledAccount.name)", component: "ImportViewModel")
            }
            // Keep UI selection pointing at the first account for continuity
            if let first = accountsByLabel.values.first { self.selectedAccountID = first.id }
        }

        // Helper for credit card sign decision per account
        func shouldFlipCreditCardAmounts(for account: Account, transactions: [StagedTransaction]) -> Bool {
            guard account.type == .creditCard else { return false }
            let includedTransactions = transactions
            func isPaymentLike(_ payee: String?, _ memo: String?) -> Bool {
                let text = ((payee ?? "") + " " + (memo ?? "")).lowercased()
                let keywords = [
                    "payment","auto pay","autopay","online payment","thank you","pmt","cardmember serv","card member serv","ach credit","ach payment","directpay","direct pay","bill pay","billpay"
                ]
                return keywords.contains { text.contains($0) }
            }
            let paymentRows = includedTransactions.filter { isPaymentLike($0.payee, $0.memo) }
            let purchaseRows = includedTransactions.filter { !isPaymentLike($0.payee, $0.memo) }
            let paymentPos = paymentRows.filter { $0.amount > 0 }.count
            let paymentNeg = paymentRows.filter { $0.amount < 0 }.count
            if paymentPos != paymentNeg && (paymentPos + paymentNeg) > 0 { return paymentNeg > paymentPos }
            let purchasePos = purchaseRows.filter { $0.amount > 0 }.count
            let purchaseNeg = purchaseRows.filter { $0.amount < 0 }.count
            if purchasePos != purchaseNeg && (purchasePos + purchaseNeg) > 0 { return purchasePos > purchaseNeg }
            let positives = includedTransactions.filter { $0.amount > 0 }.count
            let negatives = includedTransactions.filter { $0.amount < 0 }.count
            if positives == negatives {
                let total = includedTransactions.reduce(Decimal.zero) { $0 + $1.amount }
                return total > 0
            } else {
                return positives > negatives
            }
        }

        // Insert transactions per account group
        var insertedTxCount = 0
        var newlyInserted: [Transaction] = []

        // Build a map of label -> transactions array to iterate (include unlabeled and default paths)
        var groupsToProcess: [(label: String, transactions: [StagedTransaction]) ] = []
        if labeledGroups.isEmpty {
            let all = labeledGroups["default"] != nil ? [] : includedTransactions
            groupsToProcess.append((label: "default", transactions: all))
        } else {
            for (label, list) in labeledGroups { groupsToProcess.append((label: label, transactions: list)) }
            if !unlabeled.isEmpty { groupsToProcess.append((label: "unlabeled", transactions: unlabeled)) }
        }

        for entry in groupsToProcess {
            guard let account = accountsByLabel[entry.label] else { continue }
            AMLogging.always("Processing group '\(entry.label)' for account: \(account.name) — tx: \(entry.transactions.count)", component: "ImportViewModel")
            let shouldFlip = shouldFlipCreditCardAmounts(for: account, transactions: entry.transactions)
            AMLogging.always("Credit card sign decision (data-driven) — flip: \(shouldFlip) for account: \(account.name)", component: "ImportViewModel")

            // De-dupe set per account
            let existingHashes = try existingTransactionHashes(for: account, context: context)

            // Compute new transactions for this account
            let newTransactions = entry.transactions.filter { t in
                let adjustedAmount = (account.type == .creditCard && shouldFlip) ? -t.amount : t.amount
                let saveKey = Hashing.hashKey(
                    date: t.datePosted,
                    amount: adjustedAmount,
                    payee: t.payee,
                    memo: t.memo,
                    symbol: t.symbol,
                    quantity: t.quantity
                )
                return !existingHashes.contains(saveKey)
            }

            for t in newTransactions {
                let adjustedAmount = (account.type == .creditCard && shouldFlip) ? -t.amount : t.amount
                let saveKey = Hashing.hashKey(
                    date: t.datePosted,
                    amount: adjustedAmount,
                    payee: t.payee,
                    memo: t.memo,
                    symbol: t.symbol,
                    quantity: t.quantity
                )

                let tx = Transaction(
                    datePosted: t.datePosted,
                    amount: adjustedAmount,
                    payee: t.payee,
                    memo: t.memo,
                    kind: t.kind,
                    externalId: t.externalId,
                    hashKey: saveKey,
                    symbol: t.symbol,
                    quantity: t.quantity,
                    price: t.price,
                    fees: t.fees,
                    account: account,
                    importBatch: batch,
                    importHashKey: saveKey
                )
                context.insert(tx)
                insertedTxCount += 1
                AMLogging.log("Inserted tx — date: \(t.datePosted), amount: \(adjustedAmount), payee: \(t.payee), hash: \(saveKey))", component: "ImportViewModel")  // DEBUG LOG
                newlyInserted.append(tx)
                batch.transactions.append(tx)
            }
        }

        AMLogging.always("Inserted transactions this batch: \(insertedTxCount) of included: \(includedTransactions.count), excluded: \(excludedCount)", component: "ImportViewModel")

        // Attempt to reconcile transfers across accounts for newly inserted transactions (±3 days)
        do {
            try reconcileTransfers(for: newlyInserted, context: context)
            AMLogging.log("ReconcileTransfers completed for \(newlyInserted.count) inserted transactions", component: "ImportViewModel")  // DEBUG LOG
        } catch {
            AMLogging.log("ReconcileTransfers failed: \(error)", component: "ImportViewModel")  // DEBUG LOG
        }

        // Save holdings (create Security as needed) — attach to the first resolved account if multiple
        var insertedHoldingsCount = 0
        let firstAccountForAssets: Account? = accountsByLabel.values.first
        for h in staged.holdings where (h.include) {
            let accountForHolding = firstAccountForAssets ?? accountsByLabel.values.first
            guard let targetAccount = accountForHolding else { continue }
            let security = fetchOrCreateSecurity(symbol: h.symbol, context: context)
            let hs = HoldingSnapshot(
                asOfDate: h.asOfDate,
                quantity: h.quantity,
                marketValue: h.marketValue,
                account: targetAccount,
                security: security,
                importBatch: batch
            )
            context.insert(hs)
            batch.holdings.append(hs)
            insertedHoldingsCount += 1
            AMLogging.log("Inserted holding — symbol: \(h.symbol), qty: \(h.quantity), mv: \(String(describing: h.marketValue))", component: "ImportViewModel")  // DEBUG LOG
        }

        // Save balances — attach to the first resolved account if multiple
        var insertedBalancesCount = 0
        for b in staged.balances where (b.include) {
            let accountForBalance = firstAccountForAssets ?? accountsByLabel.values.first
            guard let targetAccount = accountForBalance else { continue }
            let bs = BalanceSnapshot(
                asOfDate: b.asOfDate,
                balance: b.balance,
                account: targetAccount,
                importBatch: batch
            )
            context.insert(bs)
            batch.balances.append(bs)
            insertedBalancesCount += 1
            AMLogging.log("Inserted balance — asOf: \(b.asOfDate), balance: \(b.balance)", component: "ImportViewModel")  // DEBUG LOG
        }

        AMLogging.log("Insert summary — tx: \(insertedTxCount), holdings: \(insertedHoldingsCount), balances: \(insertedBalancesCount)", component: "ImportViewModel")  // DEBUG LOG

        if newlyInserted.isEmpty {
            // Surface a helpful message if nothing was saved due to duplicates/exclusions
            self.errorMessage = "No new transactions to save (all duplicates or excluded)."
        } else {
            self.errorMessage = nil
        }

        do {
            try context.save()
            AMLogging.log("Context save succeeded", component: "ImportViewModel")  // DEBUG LOG

            // Debug: post-save counts
            do {
                let totalTx = try context.fetchCount(FetchDescriptor<Transaction>())
                AMLogging.log("Post-save counts — total transactions: \(totalTx)", component: "ImportViewModel")  // DEBUG LOG

                // Additional diagnostics: counts of other models
                let accountCount = try context.fetchCount(FetchDescriptor<Account>())
                let balanceCount = try context.fetchCount(FetchDescriptor<BalanceSnapshot>())
                let holdingCount = try context.fetchCount(FetchDescriptor<HoldingSnapshot>())
                AMLogging.log("Post-save counts — accounts: \(accountCount), balances: \(balanceCount), holdings: \(holdingCount)", component: "ImportViewModel")  // DEBUG LOG

                // Sample a few transactions to verify visibility
                var sampleDesc = FetchDescriptor<Transaction>(
                    sortBy: [SortDescriptor(\Transaction.datePosted, order: .reverse)]
                )
                sampleDesc.fetchLimit = 3
                let samples = try context.fetch(sampleDesc)
                if samples.isEmpty {
                    AMLogging.log("Post-save sample fetch: no transactions returned", component: "ImportViewModel")  // DEBUG LOG
                } else {
                    for (idx, s) in samples.enumerated() {
                        let acctLabel = s.account?.name ?? "(no account)"
                        AMLogging.log("Sample[\(idx)] — date: \(s.datePosted), amount: \(s.amount), payee: \(s.payee), account: \(acctLabel)", component: "ImportViewModel")  // DEBUG LOG
                    }
                }
            } catch {
                AMLogging.log("Post-save diagnostics failed: \(error)", component: "ImportViewModel")  // DEBUG LOG
            }

            // Additional: per-account snapshot of values for debugging Net Worth grouping
            do {
                let accounts = try context.fetch(FetchDescriptor<Account>())
                AMLogging.always("Accounts snapshot (\(accounts.count)):", component: "ImportViewModel")
                for acct in accounts {
                    let latest = try latestBalance(for: acct, context: context)
                    let derived = acct.transactions.reduce(Decimal.zero) { $0 + $1.amount }
                    let value = latest ?? derived
                    AMLogging.always("• \(acct.name) — type: \(acct.type.rawValue), inst: \(acct.institutionName ?? "(nil)"), value: \(value), tx: \(acct.transactions.count), balances: \(acct.balanceSnapshots.count)", component: "ImportViewModel")
                }
            } catch {
                AMLogging.always("Accounts snapshot failed: \(error)", component: "ImportViewModel")
            }

            // Notify UI that transactions changed (helps tabs refresh if needed)
            NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
            NotificationCenter.default.post(name: .accountsDidChange, object: nil)

            self.staged = nil
            self.userInstitutionName = ""
            self.infoMessage = nil
        } catch {
            AMLogging.log("Context save failed: \(error)", component: "ImportViewModel")  // DEBUG LOG
            self.errorMessage = error.localizedDescription
            throw error
        }
    }

    func applyBankMapping() {
        guard let session = mappingSession else { return }
        // Require at least date and (amount or debit/credit)
        guard let dateIdx = session.dateIndex else { return }
        let descIdx = session.descriptionIndex
        let amountIdx = session.amountIndex
        let debitIdx = session.debitIndex
        let creditIdx = session.creditIndex

        // Build rows using the full set of available rows (not only sample)
        // Re-read the last picked file is complex here; for MVP we'll reuse sampleRows as the body and headers as header
        let rows = session.sampleRows
        _ = session.headers

        // Convert to StagedTransactions
        var stagedTx: [StagedTransaction] = []
        let dateFormats = [session.dateFormat].compactMap { $0 } + ["MM/dd/yyyy", "yyyy-MM-dd", "M/d/yyyy"]

        func parseDate(_ s: String) -> Date? {
            for fmt in dateFormats {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.timeZone = TimeZone(secondsFromGMT: 0)
                df.dateFormat = fmt
                if let d = df.date(from: s) { return d }
            }
            return nil
        }

        func sanitize(_ s: String) -> String {
            s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "")
        }

        for row in rows {
            let dateStr = row[safe: dateIdx] ?? ""
            guard let date = parseDate(dateStr) else { continue }
            let payee = descIdx.flatMap { row[safe: $0] } ?? "Unknown"

            var amount: Decimal = 0
            if let aIdx = amountIdx, let a = Decimal(string: sanitize(row[safe: aIdx] ?? "")) {
                amount = a
            } else if let dIdx = debitIdx, let dec = Decimal(string: sanitize(row[safe: dIdx] ?? "")) {
                amount = -dec
            } else if let cIdx = creditIdx, let dec = Decimal(string: sanitize(row[safe: cIdx] ?? "")) {
                amount = dec
            } else {
                continue
            }

            let hashKey = Hashing.hashKey(date: date, amount: amount, payee: payee, memo: nil, symbol: nil, quantity: nil)
            let tx = StagedTransaction(
                datePosted: date,
                amount: amount,
                payee: payee,
                memo: nil,
                kind: .bank,
                externalId: nil,
                symbol: nil,
                quantity: nil,
                price: nil,
                fees: nil,
                hashKey: hashKey
            )
            stagedTx.append(tx)
        }

        let stagedImport = StagedImport(
            parserId: "mapping.bank",
            sourceFileName: "Mapped.csv",
            suggestedAccountType: .checking,
            transactions: stagedTx,
            holdings: [],
            balances: []
        )
        self.staged = stagedImport
        self.mappingSession = nil
    }

    private func existingTransactionHashes(for account: Account, context: ModelContext) throws -> Set<String> {
        let keys = account.transactions.map { $0.importHashKey ?? $0.hashKey }
        return Set(keys)
    }

    private func fetchOrCreateSecurity(symbol: String, context: ModelContext) -> Security {
        if let s = try? context.fetch(FetchDescriptor<Security>()).first(where: { $0.symbol == symbol }) {
            return s
        }
        let sec = Security(symbol: symbol)
        context.insert(sec)
        return sec
    }

    // Normalize institution names for matching (e.g., "Fidelity" vs "Fidelity Investments")
    private func normalizeInstitutionName(_ raw: String?) -> String {
        guard let raw = raw else { return "" }
        let lower = raw.lowercased()
        // Replace punctuation with spaces, collapse multiple spaces, and split into tokens
        let separators = CharacterSet(charactersIn: ",./-_&()[]{}:")
        let spaced = lower.components(separatedBy: separators).joined(separator: " ")
        let tokens = spaced
            .split(separator: " ")
            .map { String($0) }
        // Remove common suffix/generic tokens that shouldn't affect identity
        let banned: Set<String> = [
            "investment", "investments", "inc", "corp", "co", "company", "llc", "l.l.c", "na", "n.a", "services", "financial", "fsb"
        ]
        let filtered = tokens.filter { !banned.contains($0) }
        // Join without spaces for robust comparison
        return filtered.joined()
    }

    // Find an existing account by type and institution name (case-insensitive)
    private func findAccount(ofType type: Account.AccountType, institutionName: String, context: ModelContext) -> Account? {
        let needle = normalizeInstitutionName(institutionName)
        if let accounts = try? context.fetch(FetchDescriptor<Account>()) {
            return accounts.first { acct in
                guard acct.type == type else { return false }
                let hay = normalizeInstitutionName(acct.institutionName)
                return hay == needle && !hay.isEmpty
            }
        }
        return nil
    }

    // Infer an institution name from a downloaded file name (best-effort)
    func guessInstitutionName(from fileName: String) -> String? {
        let base = (fileName as NSString).deletingPathExtension
        let lower = base.lowercased()
        let normalized = lower
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        let known: [(pattern: String, display: String)] = [
            ("americanexpress", "American Express"),
            ("amex", "American Express"),
            ("bankofamerica", "Bank of America"),
            ("boa", "Bank of America"),
            ("wellsfargo", "Wells Fargo"),
            ("capitalone", "Capital One"),
            ("capone", "Capital One"),
            ("charlesschwab", "Charles Schwab"),
            ("schwab", "Charles Schwab"),
            ("fidelity", "Fidelity"),
            ("vanguard", "Vanguard"),
            ("robinhood", "Robinhood"),
            ("discover", "Discover"),
            ("citibank", "Citi"),
            ("citi", "Citi"),
            ("chase", "Chase"),
            ("sofi", "SoFi")
        ]
        if let match = known.first(where: { normalized.contains($0.pattern) }) {
            return match.display
        }

        // No fallback to tokens from filename — require explicit user input if no known match
        return nil
    }

    // Best-effort account type inference from filename/headers and sample row content
    private func guessAccountType(from fileName: String, headers: [String], sampleRows: [[String]]) -> Account.AccountType? {
        let normalizedFile = fileName
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        let lowerHeaders = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        // 1) Brokerage signals in headers
        let brokerageHeaderSignals = [
            "symbol", "ticker", "cusip", "qty", "quantity", "shares", "share", "price", "security"
        ]
        let hasBrokerageHeader = lowerHeaders.contains { h in
            brokerageHeaderSignals.contains { sig in h == sig || h.contains(sig) }
        }
        if hasBrokerageHeader {
            AMLogging.always("GuessAccountType: Brokerage by header signal", component: "ImportViewModel")
            return .brokerage
        }

        // 2) Brokerage signals in row descriptions (buy/sell/dividend/options, etc.)
        // Try to find a likely description column
        func probableDescriptionIndex() -> Int? {
            let keys = ["description", "activity", "action", "details", "detail", "type", "transaction type"]
            for (idx, h) in lowerHeaders.enumerated() {
                if keys.contains(where: { h == $0 || h.contains($0) }) { return idx }
            }
            return nil
        }
        let descIdx = probableDescriptionIndex()
        let brokerageKeywords = [
            "buy", "bought", "sell", "sold", "dividend", "reinvest", "reinvestment", "interest", "cap gain", "capital gain",
            "distribution", "split", "spinoff", "spin-off", "option", "call", "put", "exercise", "assign", "assignment", "expiration",
            "short", "cover"
        ]
        var brokerageHits = 0
        for row in sampleRows {
            let text: String = {
                if let i = descIdx, row.indices.contains(i) { return row[i] } else { return row.joined(separator: " ") }
            }().lowercased()
            if brokerageKeywords.contains(where: { text.contains($0) }) {
                brokerageHits += 1
                if brokerageHits >= 2 { break }
            }
        }
        if brokerageHits >= 2 || (brokerageHits == 1 && sampleRows.count <= 5) {
            AMLogging.always("GuessAccountType: Brokerage by row keyword hits = \(brokerageHits)", component: "ImportViewModel")
            return .brokerage
        }

        // 3) Credit card heuristics (applied only if no brokerage signals)
        let hasCategory = lowerHeaders.contains(where: { $0.contains("category") })
        let hasType = lowerHeaders.contains(where: { $0 == "type" || $0.contains("transaction type") || $0.contains("type") })
        let hasDebitCredit = lowerHeaders.contains("debit") || lowerHeaders.contains("credit")
        let hasBalance = lowerHeaders.contains(where: { $0.contains("balance") })
        if hasCategory && hasType && !hasDebitCredit && !hasBalance {
            AMLogging.always("GuessAccountType: CreditCard by header heuristic", component: "ImportViewModel")
            return .creditCard
        }

        // 4) Filename-based hints (fallback only)
        if normalizedFile.contains("creditcard") || (normalizedFile.contains("credit") && normalizedFile.contains("card")) || normalizedFile.contains("cc") {
            AMLogging.always("GuessAccountType: CreditCard by filename", component: "ImportViewModel")
            return .creditCard
        }

        return nil
    }

    // Helpers for diagnostics
    private func latestBalance(for account: Account, context: ModelContext) throws -> Decimal? {
        let accountID = account.id
        let predicate = #Predicate<BalanceSnapshot> { snap in
            snap.account?.id == accountID
        }
        var descriptor = FetchDescriptor<BalanceSnapshot>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        descriptor.fetchLimit = 1
        let snapshots = try context.fetch(descriptor)
        return snapshots.first?.balance
    }

    private func derivedBalanceFromTransactions(for account: Account) -> Decimal {
        return account.transactions.reduce(Decimal.zero) { $0 + $1.amount }
    }

    // MARK: - Transfer reconciliation
    private func reconcileTransfers(for insertedTransactions: [Transaction], context: ModelContext) throws {
        // Link likely transfer pairs across different accounts within a ±3 day window
        let dayWindow: TimeInterval = 3 * 24 * 60 * 60

        // Fetch all transactions once and filter in-memory for simplicity and reliability
        var descriptor = FetchDescriptor<Transaction>()
        descriptor.sortBy = [SortDescriptor(\Transaction.datePosted)]
        let allTx = try context.fetch(descriptor)

        for tx in insertedTransactions {
            // Skip if already linked or not a bank-like transaction
            guard tx.linkedTransactionId == nil, tx.kind == .bank else { continue }

            let thisAccountID = tx.account?.id
            let absAmount = (tx.amount as NSDecimalNumber).decimalValue.magnitude
            let startDate = tx.datePosted.addingTimeInterval(-dayWindow)
            let endDate = tx.datePosted.addingTimeInterval(dayWindow)

            // Candidates in other accounts with opposite sign, same magnitude, and within window
            let candidates = allTx.filter { cand in
                guard cand.id != tx.id,
                      cand.account?.id != thisAccountID,
                      cand.linkedTransactionId == nil,
                      cand.kind == .bank else { return false }

                let oppositeSign = (cand.amount < 0) != (tx.amount < 0)
                let sameMagnitude = ((cand.amount as NSDecimalNumber).decimalValue.magnitude == absAmount)
                let withinWindow = (cand.datePosted >= startDate && cand.datePosted <= endDate)
                return oppositeSign && sameMagnitude && withinWindow
            }

            // Choose the closest by date
            let best = candidates.min { a, b in
                abs(a.datePosted.timeIntervalSince(tx.datePosted)) < abs(b.datePosted.timeIntervalSince(tx.datePosted))
            }

            if let match = best {
                tx.kind = .transfer
                match.kind = .transfer
                tx.linkedTransactionId = match.id
                match.linkedTransactionId = tx.id

                // Optional memo annotation to aid UI/debugging
                if let aName = tx.account?.name, let bName = match.account?.name {
                    let note = "Linked transfer: \(aName) ⇄ \(bName)"
                    if (tx.memo ?? "").isEmpty { tx.memo = note }
                    if (match.memo ?? "").isEmpty { match.memo = note }
                }
            }
        }
    }
}

struct MappingSession {
    enum Kind { case bank }
    var kind: Kind
    var headers: [String]
    var sampleRows: [[String]]
    // User-selected column indices
    var dateIndex: Int?
    var descriptionIndex: Int?
    var amountIndex: Int?
    var debitIndex: Int?
    var creditIndex: Int?
    var balanceIndex: Int?
    var dateFormat: String? // optional override
}

extension Notification.Name {
    static let transactionsDidChange = Notification.Name("TransactionsDidChange")
    static let accountsDidChange = Notification.Name("AccountsDidChange")
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}

