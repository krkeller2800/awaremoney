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

            let data = try Data(contentsOf: url)
            let (rows, headers) = try CSV.read(data: data)
            AMLogging.log("CSV read: headers=\(headers), rowCount=\(rows.count)", component: "ImportViewModel")  // DEBUG LOG
            guard !headers.isEmpty else { throw ImportError.invalidCSV }

            if let parser = parsers.first(where: { $0.canParse(headers: headers) }) {
                AMLogging.log("Using parser: \(String(describing: type(of: parser)))", component: "ImportViewModel")  // DEBUG LOG
                var stagedImport = try parser.parse(rows: rows, headers: headers)
                stagedImport.sourceFileName = url.lastPathComponent

                // Guess account type from filename and/or headers (e.g., credit card statements)
                if let guessedType = guessAccountType(from: stagedImport.sourceFileName, headers: headers) {
                    stagedImport.suggestedAccountType = guessedType
                }

                // Preselect the new account type in the UI if creating a new account
                if let suggested = stagedImport.suggestedAccountType {
                    self.newAccountType = suggested
                }

                self.staged = stagedImport
            } else {
                throw ImportError.unknownFormat
            }
        } catch {
            let ns = error as NSError
            AMLogging.log("Importer error: \(ns.domain) (\(ns.code)) — \(ns.localizedDescription) — \(ns.userInfo)", component: "ImportViewModel")  // DEBUG LOG
            self.errorMessage = ns.localizedDescription
            self.staged = nil
        }
    }

    func approveAndSave(context: ModelContext) throws {
        guard let staged else { return }
        AMLogging.log("Approve & Save started", component: "ImportViewModel")  // DEBUG LOG
        AMLogging.log("Staged counts — tx: \(staged.transactions.count), holdings: \(staged.holdings.count), balances: \(staged.balances.count)", component: "ImportViewModel")  // DEBUG LOG

        let batch = ImportBatch(
            label: staged.sourceFileName, sourceFileName: staged.sourceFileName
        )
        context.insert(batch)
        AMLogging.log("Created ImportBatch with label: \(batch.label)", component: "ImportViewModel")  // DEBUG LOG

        AMLogging.always("Approve: guessed institution from file '\(staged.sourceFileName)': \(guessInstitutionName(from: staged.sourceFileName) ?? "(nil)")", component: "ImportViewModel")

        // Ensure account exists
        let guessedInst = guessInstitutionName(from: staged.sourceFileName)
        let account: Account
        if let selectedID = selectedAccountID, let fetched = try? {
            let predicate = #Predicate<Account> { $0.id == selectedID }
            var descriptor = FetchDescriptor<Account>(predicate: predicate)
            descriptor.fetchLimit = 1
            return try context.fetch(descriptor).first
        }() {
            var target = fetched
            AMLogging.always("Selected account before resolution — name: \(target.name), type: \(target.type.rawValue), inst: \(target.institutionName ?? "(nil)")", component: "ImportViewModel")

            // If selected account has no institution, fill it
            if (target.institutionName == nil) || (target.institutionName?.isEmpty == true) {
                AMLogging.always("Filling missing institution on selected account with: \(guessedInst ?? "(nil)")", component: "ImportViewModel")
                if let guessedInst { target.institutionName = guessedInst }
            } else if let guessedInst, let current = target.institutionName, !current.isEmpty, current.lowercased() != guessedInst.lowercased() {
                AMLogging.always("Institution mismatch — selected: \(current), guessed: \(guessedInst). Will find or create target account.", component: "ImportViewModel")
                // Institution mismatch: find or create an account for the guessed institution
                if let existing = findAccount(ofType: target.type, institutionName: guessedInst, context: context) {
                    AMLogging.always("Switching to existing account for institution: \(guessedInst)", component: "ImportViewModel")
                    target = existing
                } else {
                    AMLogging.always("Creating new account for institution: \(guessedInst)", component: "ImportViewModel")
                    let acct = Account(
                        name: "\(guessedInst) \(target.type.rawValue.capitalized)",
                        type: target.type,
                        institutionName: guessedInst,
                        currencyCode: "USD"
                    )
                    context.insert(acct)
                    target = acct
                }
            }
            account = target
        } else {
            let name = newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
            let acct = Account(
                name: name.isEmpty ? "Imported \(Date.now.formatted(date: .abbreviated, time: .omitted))" : name,
                type: newAccountType,
                institutionName: guessedInst,
                currencyCode: "USD"
            )
            AMLogging.always("Creating new account (no selection) with institution: \(guessedInst ?? "(nil)") and type: \(newAccountType.rawValue)", component: "ImportViewModel")
            context.insert(acct)
            account = acct
        }
        AMLogging.log("Resolved account — id: \(account.id), name: \(account.name), type: \(account.type.rawValue), existing tx count: \(account.transactions.count)", component: "ImportViewModel")  // DEBUG LOG
        AMLogging.always("Using account — id: \(account.id), name: \(account.name), type: \(account.type.rawValue), inst: \(account.institutionName ?? "(nil)")", component: "ImportViewModel")
        self.selectedAccountID = account.id

        // De-dupe by hashKey per account
        let existingHashes = try existingTransactionHashes(for: account, context: context)

        // Compute included and new transactions
        let includedTransactions = staged.transactions.filter { ($0.include) }
        let excludedCount = staged.transactions.count - includedTransactions.count

        // Determine sign convention for credit card statements (data-driven: detect payment vs purchase signs)
        let shouldFlipCreditCardAmounts: Bool = {
            guard account.type == .creditCard else { return false }

            // Identify payment-like rows using description keywords in payee/memo
            func isPaymentLike(_ payee: String?, _ memo: String?) -> Bool {
                let text = ((payee ?? "") + " " + (memo ?? "")).lowercased()
                let keywords = [
                    "payment",
                    "auto pay",
                    "autopay",
                    "online payment",
                    "thank you",
                    "pmt",
                    "cardmember serv",
                    "card member serv",
                    "ach credit",
                    "ach payment",
                    "directpay",
                    "direct pay",
                    "bill pay",
                    "billpay"
                ]
                return keywords.contains { text.contains($0) }
            }

            let paymentRows = includedTransactions.filter { isPaymentLike($0.payee, $0.memo) }
            let purchaseRows = includedTransactions.filter { !isPaymentLike($0.payee, $0.memo) }

            let paymentPos = paymentRows.filter { $0.amount > 0 }.count
            let paymentNeg = paymentRows.filter { $0.amount < 0 }.count

            // Primary signal: how payments are signed
            if paymentPos != paymentNeg && (paymentPos + paymentNeg) > 0 {
                // If payments are mostly negative, purchases are likely positive -> flip
                return paymentNeg > paymentPos
            }

            // Secondary signal: how purchases are signed
            let purchasePos = purchaseRows.filter { $0.amount > 0 }.count
            let purchaseNeg = purchaseRows.filter { $0.amount < 0 }.count
            if purchasePos != purchaseNeg && (purchasePos + purchaseNeg) > 0 {
                // If purchases are mostly positive -> flip, else don't
                return purchasePos > purchaseNeg
            }

            // Fallback: overall majority / sum
            let positives = includedTransactions.filter { $0.amount > 0 }.count
            let negatives = includedTransactions.filter { $0.amount < 0 }.count
            if positives == negatives {
                let total = includedTransactions.reduce(Decimal.zero) { $0 + $1.amount }
                return total > 0
            } else {
                return positives > negatives
            }
        }()

        AMLogging.always("Credit card sign decision (data-driven) — flip: \(shouldFlipCreditCardAmounts)", component: "ImportViewModel")

        let newTransactions = includedTransactions.filter { t in
            // For credit cards, flip the sign only if needed so purchases are negative (liability increases) and payments are positive
            let adjustedAmount = (account.type == .creditCard && shouldFlipCreditCardAmounts) ? -t.amount : t.amount
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

        AMLogging.log("Tx filter — included: \(includedTransactions.count), excluded: \(excludedCount), existingHashes: \(existingHashes.count), new: \(newTransactions.count)", component: "ImportViewModel")  // DEBUG LOG

        // Save transactions
        var insertedTxCount = 0
        var newlyInserted: [Transaction] = []
        for t in newTransactions {
            let adjustedAmount = (account.type == .creditCard && shouldFlipCreditCardAmounts) ? -t.amount : t.amount
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

        AMLogging.always("Inserted transactions this batch: \(insertedTxCount) of new: \(newTransactions.count) (included: \(includedTransactions.count), excluded: \(excludedCount))", component: "ImportViewModel")

        // Attempt to reconcile transfers across accounts for newly inserted transactions (±3 days)
        do {
            try reconcileTransfers(for: newlyInserted, context: context)
            AMLogging.log("ReconcileTransfers completed for \(newlyInserted.count) inserted transactions", component: "ImportViewModel")  // DEBUG LOG
        } catch {
            AMLogging.log("ReconcileTransfers failed: \(error)", component: "ImportViewModel")  // DEBUG LOG
        }

        // Save holdings (create Security as needed)
        var insertedHoldingsCount = 0
        for h in staged.holdings where (h.include) {
            let security = fetchOrCreateSecurity(symbol: h.symbol, context: context)
            let hs = HoldingSnapshot(
                asOfDate: h.asOfDate,
                quantity: h.quantity,
                marketValue: h.marketValue,
                account: account,
                security: security,
                importBatch: batch
            )
            context.insert(hs)
            batch.holdings.append(hs)
            insertedHoldingsCount += 1
            AMLogging.log("Inserted holding — symbol: \(h.symbol), qty: \(h.quantity), mv: \(String(describing: h.marketValue))", component: "ImportViewModel")  // DEBUG LOG
        }

        // Save balances
        var insertedBalancesCount = 0
        for b in staged.balances where (b.include) {
            let bs = BalanceSnapshot(
                asOfDate: b.asOfDate,
                balance: b.balance,
                account: account,
                importBatch: batch
            )
            context.insert(bs)
            batch.balances.append(bs)
            insertedBalancesCount += 1
            AMLogging.log("Inserted balance — asOf: \(b.asOfDate), balance: \(b.balance)", component: "ImportViewModel")  // DEBUG LOG
        }

        AMLogging.log("Insert summary — tx: \(insertedTxCount), holdings: \(insertedHoldingsCount), balances: \(insertedBalancesCount)", component: "ImportViewModel")  // DEBUG LOG

        if newTransactions.isEmpty {
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
                let accountID = account.id
                let acctPredicate = #Predicate<Transaction> { tx in
                    tx.account?.id == accountID
                }
                let acctDescriptor = FetchDescriptor<Transaction>(predicate: acctPredicate)
                let acctTx = try context.fetchCount(acctDescriptor)
                let acctName = account.name
                AMLogging.log("Post-save counts — total transactions: \(totalTx), for account \(acctName): \(acctTx)", component: "ImportViewModel")  // DEBUG LOG

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

            self.staged = nil
        } catch {
            AMLogging.log("Context save failed: \(error)", component: "ImportViewModel")  // DEBUG LOG
            self.errorMessage = error.localizedDescription
            throw error
        }
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

    // Find an existing account by type and institution name (case-insensitive)
    private func findAccount(ofType type: Account.AccountType, institutionName: String, context: ModelContext) -> Account? {
        if let accounts = try? context.fetch(FetchDescriptor<Account>()) {
            return accounts.first { acct in
                acct.type == type && ((acct.institutionName ?? "").lowercased() == institutionName.lowercased())
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

        // Fallback: take the first token and strip non-letters
        let separators = CharacterSet(charactersIn: "-_ ")
        let firstToken = base.components(separatedBy: separators).first ?? base
        let letters = firstToken.filter { $0.isLetter }
        if !letters.isEmpty {
            return String(letters).capitalized
        }
        return nil
    }

    // Best-effort account type inference from filename/headers
    private func guessAccountType(from fileName: String, headers: [String]) -> Account.AccountType? {
        let normalizedFile = fileName
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        // Credit card heuristics from filename
        if normalizedFile.contains("creditcard") || (normalizedFile.contains("credit") && normalizedFile.contains("card")) || normalizedFile.contains("cc") {
            return .creditCard
        }

        // Header-based heuristics: many credit card CSVs include Category and Type columns (e.g., Sale, Payment, Fee)
        let lowerHeaders = headers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let hasCategory = lowerHeaders.contains(where: { $0.contains("category") })
        let hasType = lowerHeaders.contains(where: { $0 == "type" || $0.contains("transaction type") || $0.contains("type") })
        let hasDebitCredit = lowerHeaders.contains("debit") || lowerHeaders.contains("credit")
        let hasBalance = lowerHeaders.contains(where: { $0.contains("balance") })

        // If we see Category+Type but not explicit Debit/Credit or Balance, strongly suggest credit card
        if hasCategory && hasType && !hasDebitCredit && !hasBalance {
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

extension Notification.Name {
    static let transactionsDidChange = Notification.Name("TransactionsDidChange")
}

