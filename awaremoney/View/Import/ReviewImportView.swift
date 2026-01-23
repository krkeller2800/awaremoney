//
//  ReviewImportView.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import SwiftUI
import SwiftData

struct ReviewImportView: View {
    var staged: StagedImport
    @ObservedObject var vm: ImportViewModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @State private var selectedAccountId: UUID? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Import")
                .font(.headline)

            Text("File: \(staged.sourceFileName)")
                .font(.subheadline)

            // Account selection / creation
            Group {
                Picker("Account", selection: Binding<UUID?>(
                    get: { selectedAccountId },
                    set: { newValue in
                        selectedAccountId = newValue
                        if let id = newValue {
                            vm.selectedAccount = accounts.first(where: { $0.id == id })
                            vm.newAccountName = ""
                        } else {
                            vm.selectedAccount = nil
                        }
                    }
                )) {
                    Text("Create New…").tag(nil as UUID?)
                    ForEach(accounts, id: \.id) { acct in
                        Text("\(acct.name) (\(acct.type.rawValue))").tag(Optional(acct.id))
                    }
                }
                .onAppear {
                    selectedAccountId = vm.selectedAccount?.id
                }

                if selectedAccountId == nil {
                    TextField("New Account Name", text: $vm.newAccountName)
                    Picker("Type", selection: $vm.newAccountType) {
                        ForEach(Account.AccountType.allCases, id: \.self) {
                            Text($0.rawValue)
                        }
                    }
                }
            }

            // Summary
            HStack {
                Text("Transactions: \(staged.transactions.count)")
                if !staged.holdings.isEmpty {
                    Text("Holdings: \(staged.holdings.count)")
                }
                if !staged.balances.isEmpty {
                    Text("Balances: \(staged.balances.count)")
                }
            }.font(.subheadline)

            // Preview list
            List {
                Section("Transactions") {
                    ForEach(staged.transactions.indices, id: \.self) { idx in
                        let t = staged.transactions[idx]
                        HStack(alignment: .firstTextBaseline) {
                            Toggle("", isOn: Binding(
                                get: { vm.staged?.transactions[idx].include ?? true },
                                set: { vm.staged?.transactions[idx].include = $0 }
                            ))
                            .labelsHidden()

                            VStack(alignment: .leading) {
                                Text(t.payee)
                                Text(t.datePosted, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(t.amount as NSNumber, formatter: ReviewImportView.currencyFormatter)
                                .foregroundStyle(t.amount < 0 ? .red : .primary)
                        }
                    }
                }

                if !staged.holdings.isEmpty {
                    Section("Holdings Snapshots") {
                        ForEach(staged.holdings.indices, id: \.self) { idx in
                            let h = staged.holdings[idx]
                            HStack {
                                Toggle("", isOn: Binding(
                                    get: { vm.staged?.holdings[idx].include ?? true },
                                    set: { vm.staged?.holdings[idx].include = $0 }
                                ))
                                .labelsHidden()
                                Text("\(h.symbol) — \(h.quantity.description)")
                                Spacer()
                                if let mv = h.marketValue {
                                    Text(mv as NSNumber, formatter: ReviewImportView.currencyFormatter)
                                }
                            }
                        }
                    }
                }

                if !staged.balances.isEmpty {
                    Section("Balance Snapshots") {
                        ForEach(staged.balances.indices, id: \.self) { idx in
                            let b = staged.balances[idx]
                            HStack {
                                Toggle("", isOn: Binding(
                                    get: { vm.staged?.balances[idx].include ?? true },
                                    set: { vm.staged?.balances[idx].include = $0 }
                                ))
                                .labelsHidden()
                                Text(b.asOfDate, style: .date)
                                Spacer()
                                Text(b.balance as NSNumber, formatter: ReviewImportView.currencyFormatter)
                            }
                        }
                    }
                }
            }
            .frame(minHeight: 300)

            Button {
                do { try vm.approveAndSave(context: modelContext) }
                catch { vm.errorMessage = error.localizedDescription }
            } label: {
                Label("Approve & Save", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private static let currencyFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        return nf
    }()
}
