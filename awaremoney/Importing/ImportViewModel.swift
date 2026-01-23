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
        do {
            let data = try Data(contentsOf: url)
            let (rows, headers) = try CSV.read(data: data)
            guard !headers.isEmpty else { throw ImportError.invalidCSV }

            if let parser = parsers.first(where: { $0.canParse(headers: headers) }) {
                var stagedImport = try parser.parse(rows: rows, headers: headers)
                stagedImport.sourceFileName = url.lastPathComponent
                self.staged = stagedImport
            } else {
                throw ImportError.unknownFormat
            }
        } catch {
            self.errorMessage = error.localizedDescription
            self.staged = nil
        }
    }

    func approveAndSave(context: ModelContext) throws {
        guard let staged else { return }

        let batch = ImportBatch(
            sourceFileName: staged.sourceFileName,
            parserId: staged.parserId,
            status: .draft
        )
        context.insert(batch)

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

        // De-dupe by hashKey per account
        let existingHashes = try existingTransactionHashes(for: account, context: context)

        // Save transactions
        for t in staged.transactions where t.include && !existingHashes.contains(t.hashKey) {
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
            context.insert(tx)
            batch.transactions.append(tx)
        }

        // Save holdings (create Security as needed)
        for h in staged.holdings where h.include {
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
            batch.holdingSnapshots.append(hs)
        }

        // Save balances
        for b in staged.balances where b.include {
            let bs = BalanceSnapshot(
                asOfDate: b.asOfDate,
                balance: b.balance,
                account: account,
                importBatch: batch
            )
            context.insert(bs)
            batch.balanceSnapshots.append(bs)
        }

        batch.status = .committed
        try context.save()
        self.staged = nil
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

