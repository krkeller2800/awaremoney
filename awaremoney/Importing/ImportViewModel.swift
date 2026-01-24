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
    @Published var isImporterPresented = false
    @Published var staged: StagedImport?
    @Published var errorMessage: String?
    @Published var selectedAccount: Account?
    @Published var newAccountName: String = ""
    @Published var newAccountType: Account.AccountType = .checking

    private let parsers: [StatementParser]

    init(parsers: [StatementParser]) {
        self.parsers = parsers
    }

    func presentImporter() {
        errorMessage = nil
        isImporterPresented = true
    }

    func handlePickedURL(_ url: URL) {
        AMLogging.log("Picked URL: \(url.absoluteString)", component: "ImportViewModel")  // DEBUG LOG
        do {
            let data = try Data(contentsOf: url)
            let (rows, headers) = try CSV.read(data: data)
            AMLogging.log("CSV read: headers=\(headers), rowCount=\(rows.count)", component: "ImportViewModel")  // DEBUG LOG
            guard !headers.isEmpty else { throw ImportError.invalidCSV }

            if let parser = parsers.first(where: { $0.canParse(headers: headers) }) {
                AMLogging.log("Using parser: \(String(describing: type(of: parser)))", component: "ImportViewModel")  // DEBUG LOG
                var stagedImport = try parser.parse(rows: rows, headers: headers)
                stagedImport.sourceFileName = url.lastPathComponent
                self.staged = stagedImport
            } else {
                throw ImportError.unknownFormat
            }
        } catch {
            AMLogging.log("Importer error: \(error)", component: "ImportViewModel")  // DEBUG LOG
            self.errorMessage = error.localizedDescription
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

        // Ensure account exists
        let account: Account
        if let selectedAccount {
            account = selectedAccount
        } else {
            let name = newAccountName.trimmingCharacters(in: .whitespacesAndNewlines)
            let acct = Account(
                name: name.isEmpty ? "Imported \(Date.now.formatted(date: .abbreviated, time: .omitted))" : name,
                type: newAccountType,
                currencyCode: "USD"
            )
            context.insert(acct)
            account = acct
        }
        AMLogging.log("Resolved account — id: \(account.id), name: \(account.name), type: \(account.type.rawValue), existing tx count: \(account.transactions.count)", component: "ImportViewModel")  // DEBUG LOG
        self.selectedAccount = account

        // De-dupe by hashKey per account
        let existingHashes = try existingTransactionHashes(for: account, context: context)

        // Compute included and new transactions
        let includedTransactions = staged.transactions.filter { ($0.include) }
        let excludedCount = staged.transactions.count - includedTransactions.count
        let newTransactions = includedTransactions.filter { !existingHashes.contains($0.hashKey) }

        AMLogging.log("Tx filter — included: \(includedTransactions.count), excluded: \(excludedCount), existingHashes: \(existingHashes.count), new: \(newTransactions.count)", component: "ImportViewModel")  // DEBUG LOG

        // Save transactions
        var insertedTxCount = 0
        for t in newTransactions {
            let tx = Transaction(
                datePosted: t.datePosted,
                amount: t.amount,
                payee: t.payee,
                memo: t.memo,
                kind: t.kind,
                externalId: t.externalId,
                hashKey: t.hashKey,
                symbol: t.symbol,
                quantity: t.quantity,
                price: t.price,
                fees: t.fees,
                account: account
            )
            // Optionally tag the transaction with the batch if the model supports it in the future
            // tx.importBatch = batch
            context.insert(tx)
            insertedTxCount += 1
            AMLogging.log("Inserted tx — date: \(t.datePosted), amount: \(t.amount), payee: \(t.payee), hash: \(t.hashKey))", component: "ImportViewModel")  // DEBUG LOG
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
        let hashes = account.transactions.map { $0.hashKey }
        return Set(hashes)
    }

    private func fetchOrCreateSecurity(symbol: String, context: ModelContext) -> Security {
        if let s = try? context.fetch(FetchDescriptor<Security>()).first(where: { $0.symbol == symbol }) {
            return s
        }
        let sec = Security(symbol: symbol)
        context.insert(sec)
        return sec
    }
}

extension Notification.Name {
    static let transactionsDidChange = Notification.Name("TransactionsDidChange")
}

