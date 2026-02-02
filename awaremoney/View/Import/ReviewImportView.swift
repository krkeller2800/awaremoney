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
    @State private var showPDFSheet = false

    var body: some View {
        ZStack {
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
                    if staged.sourceFileName.lowercased().hasSuffix(".pdf") {
                        Button {
                            showPDFSheet = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text.magnifyingglass")
                                Text("View PDF")
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                // Account selection / creation
                Section("Account") {
                    Picker("Account", selection: Binding<UUID?>(
                        get: { selectedAccountId },
                        set: { newValue in
                            selectedAccountId = newValue
                            vm.selectedAccountID = newValue
                            AMLogging.always("ReviewImportView: Account selection changed -> \(String(describing: newValue))", component: "ReviewImportView")
                            if newValue != nil {
                                vm.newAccountName = ""
                                // Prefill institution from selected account if user hasn't entered one
                                if let id = newValue, let acct = accounts.first(where: { $0.id == id }) {
                                    let current = vm.userInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    if current.isEmpty, let inst = acct.institutionName, !inst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                        vm.userInstitutionName = inst
                                        AMLogging.always("ReviewImportView: Prefilled institution from selected account — category=selectedAccount value=\(inst)", component: "ReviewImportView")
                                    } else {
                                        let reason = current.isEmpty ? "noAccountInstitution" : "alreadySet"
                                        AMLogging.always("ReviewImportView: Did not prefill from selected account — category=none reason=\(reason)", component: "ReviewImportView")
                                    }
                                }
                            } else {
                                // Switched back to Create New… — prefill from parser if available and empty
                                let current = vm.userInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines)
                                let parsed = staged.inferredInstitutionName?.trimmingCharacters(in: .whitespacesAndNewlines)
                                if current.isEmpty, let inst = parsed, !inst.isEmpty {
                                    vm.userInstitutionName = inst
                                    AMLogging.always("ReviewImportView: Prefilled institution from parser on Create New — category=parser value=\(inst)", component: "ReviewImportView")
                                }
                            }
                        }
                    )) {
                        Text("Create New…").tag(nil as UUID?)
                        ForEach(accounts, id: \.id) { acct in
                            Text("\(acct.name) (\(acct.type.rawValue))").tag(Optional(acct.id))
                        }
                    }
                    .onAppear {
                        AMLogging.always("ReviewImportView.onAppear — file=\(staged.sourceFileName), initial userInstitutionName='\(vm.userInstitutionName)'", component: "ReviewImportView")
                        // Default to creating a new account for each staged import unless user explicitly picks an existing one
                        selectedAccountId = nil
                        vm.selectedAccountID = nil

                        // Pre-fill type from suggested type if available
                        if let suggested = staged.suggestedAccountType {
                            vm.newAccountType = suggested
                        }

                        // Prefill institution from parser (staged) if available and field is empty
                        let current = vm.userInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines)
                        let parsed = staged.inferredInstitutionName?.trimmingCharacters(in: .whitespacesAndNewlines)
                        AMLogging.always("ReviewImportView.onAppear — parsedInstitution=\(parsed ?? "nil") currentEmpty=\(current.isEmpty)", component: "ReviewImportView")
                        if current.isEmpty, let inst = parsed, !inst.isEmpty {
                            vm.userInstitutionName = inst
                            AMLogging.always("ReviewImportView: Prefilled institution from parser — category=parser value=\(inst)", component: "ReviewImportView")
                        } else if current.isEmpty {
                            AMLogging.always("ReviewImportView: No prefill — category=none reason=noParsedInstitution", component: "ReviewImportView")
                        } else {
                            AMLogging.always("ReviewImportView: No prefill — category=none reason=alreadySet", component: "ReviewImportView")
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
                    
                    // Flip-sign override for credit card imports
                    if vm.newAccountType == .creditCard {
                        Toggle(isOn: Binding(
                            get: { vm.creditCardFlipOverride ?? false },
                            set: { vm.creditCardFlipOverride = $0 }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Treat purchases as negative and payments as positive")
                                Text("If amounts look inverted, toggle this.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                            HStack(alignment: .top) {
                                Toggle("", isOn: Binding(
                                    get: { vm.staged?.balances[idx].include ?? true },
                                    set: { vm.staged?.balances[idx].include = $0 }
                                ))
                                .labelsHidden()

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(b.asOfDate, style: .date)
                                            .font(.subheadline)
                                        Spacer()
                                        Text(b.balance as NSNumber, formatter: ReviewImportView.currencyFormatter)
                                    }
                                    if let label = b.sourceAccountLabel, !label.isEmpty {
                                        Text(label.capitalized)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.secondary.opacity(0.12))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    if let apr = b.interestRateAPR {
                                        Text("APR: \(formatAPR(apr, scale: b.interestRateScale))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .onChange(of: vm.userInstitutionName) {
                AMLogging.always("ReviewImportView: userInstitutionName changed -> '\(vm.userInstitutionName)'", component: "ReviewImportView")
            }
            .onChange(of: selectedAccountId) { 
                AMLogging.always("ReviewImportView: selectedAccountId changed -> \(String(describing: selectedAccountId))", component: "ReviewImportView")
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
                            // Diagnostics: log institution state at approve time
                            let guess = vm.guessInstitutionName(from: staged.sourceFileName)
                            let selected = selectedAccountId.flatMap { id in accounts.first(where: { $0.id == id }) }
                            AMLogging.always("ReviewImportView: Approve tapped — selectedAccount=\(selected?.name ?? "nil"), selectedInst=\(selected?.institutionName ?? "nil"), vm.userInstitutionName='\(vm.userInstitutionName)', filenameGuess=\(guess ?? "nil")", component: "ReviewImportView")
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
            if vm.isImporting {
                Color.black.opacity(0.2)
                    .ignoresSafeArea()
                ProgressView("Importing…")
                    .progressViewStyle(.circular)
                    .padding(16)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .sheet(isPresented: $showPDFSheet) {
            NavigationStack {
                Group {
                    if let url = vm.lastPickedLocalURL {
                        PDFKitView(url: url)
                            .ignoresSafeArea()
                    } else {
                        VStack {
                            Text("File: \(staged.sourceFileName)")
                                .font(.subheadline)
                            ContentUnavailableView(
                                "PDF Viewer",
                                systemImage: "doc.richtext",
                                description: Text("Original PDF preview isn't available yet.")
                            )
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("View PDF")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showPDFSheet = false }
                }
            }
        }
    }

    private static let currencyFormatter: NumberFormatter = {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        return nf
    }()
    
    private func formatAPR(_ apr: Decimal, scale: Int? = nil) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if let s = scale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s } else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
        return nf.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr)"
    }
}

