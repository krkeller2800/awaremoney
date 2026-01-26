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

                    // Pre-fill new account name from file name when creating a new account
                    let base = (staged.sourceFileName as NSString).deletingPathExtension
                    if let inst = vm.guessInstitutionName(from: staged.sourceFileName), !inst.isEmpty {
                        vm.newAccountName = "\(inst) \(vm.newAccountType.rawValue.capitalized)"
                    } else {
                        vm.newAccountName = base
                    }
                }

                if selectedAccountId == nil {
                    TextField("New Account Name", text: $vm.newAccountName)
                    Picker("Type", selection: $vm.newAccountType) {
                        ForEach(Account.AccountType.allCases, id: \.self) {
                            Text($0.rawValue)
                        }
                    }
                    .onChange(of: vm.newAccountType) { _, newValue in
                        // If user hasn't customized the name, keep it in sync with type
                        let base = (staged.sourceFileName as NSString).deletingPathExtension
                        if let inst = vm.guessInstitutionName(from: staged.sourceFileName), !inst.isEmpty {
                            let suggested = "\(inst) \(newValue.rawValue.capitalized)"
                            if vm.newAccountName.isEmpty || vm.newAccountName.hasPrefix(inst) {
                                vm.newAccountName = suggested
                            }
                        } else if vm.newAccountName.isEmpty {
                            vm.newAccountName = base
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

