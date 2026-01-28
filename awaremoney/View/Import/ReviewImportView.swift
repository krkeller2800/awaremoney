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
        List {
            if let info = vm.infoMessage, !info.isEmpty {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                        Text(info)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Details") {
                Text("File: \(staged.sourceFileName)")
                    .font(.subheadline)
            }

            // Account selection / creation
            Section("Account") {
                Picker("Account", selection: Binding<UUID?>(
                    get: { selectedAccountId },
                    set: { newValue in
                        selectedAccountId = newValue
                        vm.selectedAccountID = newValue
                        if newValue != nil {
                            vm.newAccountName = ""
                        }
                    }
                )) {
                    Text("Create New…").tag(nil as UUID?)
                    ForEach(accounts, id: \.id) { acct in
                        Text("\(acct.name) (\(acct.type.rawValue))").tag(Optional(acct.id))
                    }
                }
                .onAppear {
                    // Default to creating a new account for each staged import unless user explicitly picks an existing one
                    selectedAccountId = nil
                    vm.selectedAccountID = nil

                    // Pre-fill type from suggested type if available
                    if let suggested = staged.suggestedAccountType {
                        vm.newAccountType = suggested
                    }

                    // If we can guess an institution, seed it; otherwise require user input
                    if let inst = vm.guessInstitutionName(from: staged.sourceFileName) {
                        vm.userInstitutionName = inst
                    } else {
                        vm.userInstitutionName = ""
                    }
                }

                if selectedAccountId == nil {
                    TextField("Institution (required)", text: $vm.userInstitutionName)
                        .textInputAutocapitalization(.words)
                    Picker("Type", selection: $vm.newAccountType) {
                        ForEach(Account.AccountType.allCases, id: \.self) {
                            Text($0.rawValue)
                        }
                    }
                }
            }

            // Starting balance prompt
            if (vm.staged?.balances.isEmpty ?? true), let earliestDate = vm.staged?.transactions.map({ $0.datePosted }).min() {
                StartingBalanceInlineView(asOfDate: earliestDate) { dec in
                    let sb = StagedBalance(asOfDate: earliestDate, balance: dec)
                    vm.staged?.balances.append(sb)
                }
            }

            // Summary
            Section("Summary") {
                HStack {
                    Text("Transactions: \(staged.transactions.count)")
                    if !staged.holdings.isEmpty {
                        Text("Holdings: \(staged.holdings.count)")
                    }
                    if !staged.balances.isEmpty {
                        Text("Balances: \(staged.balances.count)")
                    }
                }
                .font(.subheadline)
            }

            // Transactions preview
            Section("Transactions") {
                ForEach(staged.transactions.indices, id: \.self) { idx in
                    let t = staged.transactions[idx]
                    HStack(alignment: .firstTextBaseline) {
                        Toggle("", isOn: Binding(
                            get: { vm.staged?.transactions[idx].include ?? true },
                            set: { vm.staged?.transactions[idx].include = $0 }
                        ))
                        .labelsHidden()

                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.payee)
                            HStack(spacing: 6) {
                                if let acct = t.sourceAccountLabel, !acct.isEmpty {
                                    Text(acct.capitalized)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                Text(t.datePosted, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(t.amount as NSNumber, formatter: ReviewImportView.currencyFormatter)
                            .foregroundStyle(t.amount < 0 ? .red : .primary)
                    }
                }
            }

            // Holdings
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

            // Balance snapshots
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
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Button(role: .cancel) {
                        vm.staged = nil
                        vm.infoMessage = nil
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "xmark.circle")
                            Text("Cancel")
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .truncationMode(.tail)
                                .allowsTightening(true)
                        }
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                    Button {
                        do { try vm.approveAndSave(context: modelContext) }
                        catch { vm.errorMessage = error.localizedDescription }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Approve & Save")
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .truncationMode(.tail)
                                .allowsTightening(true)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(false)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal)
                .padding(.vertical, 12)
                .padding(.bottom, 8)
                .background(.regularMaterial)
            }
        }
    }

    private static let currencyFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        return nf
    }()
}

