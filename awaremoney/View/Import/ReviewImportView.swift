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
    @Query(sort: [SortDescriptor(\Account.createdAt)]) private var accounts: [Account]
    @State private var selectedAccountId: UUID? = nil
    @State private var showPDFSheet = false
    @State private var typicalPaymentInput: String = ""
    @State private var typicalPaymentParsed: Decimal? = nil

    var body: some View {
        ZStack {
            mainList
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
        .onAppear {
            let hasStaged = (vm.staged != nil)
            let balancesCount = vm.staged?.balances.count ?? 0
            let hasSentinel = vm.staged?.balances.contains(where: { ($0.sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "__typical_payment__" }) ?? false
            AMLogging.log("ReviewImportView: top-level onAppear — hasStaged=\(hasStaged) balances=\(balancesCount) hasSentinel=\(hasSentinel) typicalPaymentInput='\(typicalPaymentInput)' parsed=\(String(describing: typicalPaymentParsed))", component: "ReviewImportView")
            seedTypicalPaymentFromSentinelIfNeeded()
        }
    }
    
    private var mainList: some View {
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
                Picker("Account", selection: accountSelectionBinding) {
                    Text("Create New…").tag(nil as UUID?)
                    ForEach(accounts, id: \.id) { acct in
                        Text("\(acct.name) (\(acct.type.rawValue))").tag(Optional(acct.id))
                    }
                }
                .onAppear(perform: onAccountSectionAppear)

                if selectedAccountId == nil {
                    TextField("Institution (required)", text: Binding(get: { vm.userInstitutionName }, set: { vm.userInstitutionName = $0 }))
                        .textInputAutocapitalization(.words)
                    Picker("Type", selection: Binding(get: { vm.newAccountType }, set: { vm.newAccountType = $0 })) {
                        ForEach(Account.AccountType.allCases, id: \.self) {
                            Text($0.rawValue)
                        }
                    }
                }
                
                // Flip-sign override for credit card imports
                if vm.newAccountType == .creditCard {
                    Toggle(isOn: creditCardFlipBinding) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Treat purchases as negative and payments as positive")
                            Text("If amounts look inverted, toggle this.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Typical payment entry for liabilities
                if vm.newAccountType == .loan || vm.newAccountType == .creditCard {
                    LabeledContent("Typical Payment") {
                        TextField("0.00", text: $typicalPaymentInput)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: typicalPaymentInput, initial: false) { _, newValue in
                                typicalPaymentParsed = parseCurrencyInput(newValue)
                            }
                    }
                    Text("Used for payoff estimates and budget projections.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // Starting balance prompt
            if (vm.staged?.balances.isEmpty ?? true), let earliestDate = vm.staged?.transactions.map({ $0.datePosted }).min() {
                StartingBalanceInlineView(asOfDate: earliestDate) { dec in
                    let sb = StagedBalance(asOfDate: earliestDate, balance: dec)
                    vm.staged?.balances.append(sb)
                }
            }
            
            // Fallback: when there are no transactions and no balances, allow entering an ending balance manually
            if (vm.staged?.transactions.isEmpty ?? true) && (vm.staged?.balances.isEmpty ?? true) {
                Section("Ending Balance") {
                    Text("This statement doesn't include transactions or detected balances. Enter the ending balance to anchor this account.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    StartingBalanceInlineView(asOfDate: Date()) { dec in
                        // Use 'as of today' as a neutral default; users can adjust later
                        let sb = StagedBalance(asOfDate: Date(), balance: dec)
                        vm.staged?.balances.append(sb)
                        AMLogging.log("ReviewImportView: User added ending balance fallback — value=\(dec)", component: "ReviewImportView")
                    }
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
                        Toggle("", isOn: transactionIncludeBinding(for: idx))
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
                            Toggle("", isOn: holdingIncludeBinding(for: idx))
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

            if let balances = vm.staged?.balances, !balances.isEmpty {
                Section("Balance Snapshots") {
                    ForEach(balances.indices, id: \.self) { idx in
                        let b = balances[idx]
                        HStack(alignment: .top) {
                            Toggle("", isOn: balanceIncludeBinding(for: idx))
                                .labelsHidden()

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 12) {
                                    DatePicker("As of", selection: balanceDateBinding(for: idx), displayedComponents: .date)
                                        .labelsHidden()
                                    Spacer()
                                    TextField("0.00", text: balanceAmountTextBinding(for: idx))
                                        .multilineTextAlignment(.trailing)
                                        .keyboardType(.decimalPad)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
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
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                if var staged = vm.staged, idx < staged.balances.count {
                                    staged.balances.remove(at: idx)
                                    vm.staged = staged
                                }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    Button {
                        var staged = vm.staged ?? StagedImport(parserId: "manual.user", sourceFileName: "Manual Entry", suggestedAccountType: vm.newAccountType, transactions: [], holdings: [], balances: [])
                        let newBalance = StagedBalance(asOfDate: Date(), balance: 0, interestRateAPR: nil, interestRateScale: nil, include: true, sourceAccountLabel: nil)
                        staged.balances.append(newBalance)
                        vm.staged = staged
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle")
                            Text("Add Balance")
                        }
                    }
                }
            }
        }
        .onChange(of: selectedAccountId, initial: false) { _, newValue in
            AMLogging.log("ReviewImportView: selectedAccountId changed -> \(String(describing: newValue))", component: "ReviewImportView")
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button(role: .cancel) {
                    vm.staged = nil
                    vm.infoMessage = nil
                    typicalPaymentInput = ""
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
                    AMLogging.log("ReviewImportView: Approve tapped — typicalPaymentInput='\(typicalPaymentInput)' parsedField=\(String(describing: parseCurrencyInput(typicalPaymentInput))) typicalPaymentParsed=\(String(describing: typicalPaymentParsed))", component: "ReviewImportView")
                    // Diagnostics: log institution state at approve time
                    let guess = vm.guessInstitutionName(from: staged.sourceFileName)
                    let selected = selectedAccountId.flatMap { id in accounts.first(where: { $0.id == id }) }
                    AMLogging.log("ReviewImportView: Approve tapped — selectedAccount=\(selected?.name ?? "nil"), selectedInst=\(selected?.institutionName ?? "nil"), vm.userInstitutionName='\(vm.userInstitutionName)', filenameGuess=\(guess ?? "nil")", component: "ReviewImportView")
                    // NOTE: Typical payment entered here is currently not persisted; expose a VM API to pass it if needed.
                    vm.applyLiabilityLabelSafetyNetIfNeeded()
                    AMLogging.log("ReviewImportView: Safety net applied (if needed) before save", component: "ReviewImportView")
                    do {
                        try vm.approveAndSave(context: modelContext)
                        AMLogging.log("ReviewImportView: post-save, attempting to persist Typical Payment — candidate=\(String(describing: (typicalPaymentParsed ?? parseCurrencyInput(typicalPaymentInput))))", component: "ReviewImportView")
                        // Persist Typical Payment to the chosen account if available
                        if let pay = typicalPaymentParsed ?? parseCurrencyInput(typicalPaymentInput), pay > 0 {
                            // Resolve target account: selected existing or best-effort newly created
                            let targetAccount: Account? = {
                                if let sel = selectedAccountId {
                                    return accounts.first(where: { $0.id == sel })
                                } else {
                                    // Best effort: find the most recently created liability account matching selection
                                    let all = (try? modelContext.fetch(FetchDescriptor<Account>())) ?? []
                                    let liabilities = all.filter { $0.type == .creditCard || $0.type == .loan }
                                    // Prefer matching institution name when available
                                    let inst = vm.userInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let candidates: [Account] = liabilities.sorted { $0.createdAt > $1.createdAt }
                                    if let byInst = candidates.first(where: { ($0.institutionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(inst) == .orderedSame && $0.type == vm.newAccountType }) {
                                        return byInst
                                    }
                                    return candidates.first
                                }
                            }()
                            if let acct = targetAccount {
                                var terms = acct.loanTerms ?? LoanTerms()
                                terms.paymentAmount = pay
                                acct.loanTerms = terms
                                try? modelContext.save()
                                NotificationCenter.default.post(name: .accountsDidChange, object: nil)
                                AMLogging.log("ReviewImportView: Persisted Typical Payment to account id=\(acct.id) amount=\(pay)", component: "ReviewImportView")
                            } else {
                                AMLogging.log("ReviewImportView: Unable to resolve account to persist Typical Payment", component: "ReviewImportView")
                            }
                        } else {
                            AMLogging.log("ReviewImportView: Not persisting Typical Payment — value is nil or non-positive", component: "ReviewImportView")
                        }
                    } catch {
                        vm.errorMessage = error.localizedDescription
                    }
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
    
    private var accountSelectionBinding: Binding<UUID?> {
        Binding(
            get: { selectedAccountId },
            set: { newValue in
                handleAccountSelectionChange(newValue)
            }
        )
    }

    private func handleAccountSelectionChange(_ newValue: UUID?) {
        selectedAccountId = newValue
        vm.selectedAccountID = newValue
        AMLogging.log("ReviewImportView: Account selection changed -> \(String(describing: newValue))", component: "ReviewImportView")
        if let id = newValue {
            vm.newAccountName = ""
            if let acct = accounts.first(where: { $0.id == id }) {
                let current = vm.userInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines)
                if current.isEmpty, let inst = acct.institutionName, !inst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    vm.userInstitutionName = inst
                    AMLogging.log("ReviewImportView: Prefilled institution from selected account — category=selectedAccount value=\(inst)", component: "ReviewImportView")
                } else {
                    let reason = current.isEmpty ? "noAccountInstitution" : "alreadySet"
                    AMLogging.log("ReviewImportView: Did not prefill from selected account — category=none reason=\(reason)", component: "ReviewImportView")
                }
            }
        } else {
            let current = vm.userInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines)
            let parsed = staged.inferredInstitutionName?.trimmingCharacters(in: .whitespacesAndNewlines)
            if current.isEmpty, let inst = parsed, !inst.isEmpty {
                vm.userInstitutionName = inst
                AMLogging.log("ReviewImportView: Prefilled institution from parser on Create New — category=parser value=\(inst)", component: "ReviewImportView")
            }
        }
    }
    
    private var creditCardFlipBinding: Binding<Bool> {
        Binding(
            get: { vm.creditCardFlipOverride ?? false },
            set: { vm.creditCardFlipOverride = $0 }
        )
    }

    private func transactionIncludeBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard let txs = vm.staged?.transactions, index < txs.count else { return true }
                return txs[index].include
            },
            set: { newValue in
                guard var staged = vm.staged, index < staged.transactions.count else { return }
                staged.transactions[index].include = newValue
                vm.staged = staged
            }
        )
    }

    private func holdingIncludeBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard let holds = vm.staged?.holdings, index < holds.count else { return true }
                return holds[index].include
            },
            set: { newValue in
                guard var staged = vm.staged, index < staged.holdings.count else { return }
                staged.holdings[index].include = newValue
                vm.staged = staged
            }
        )
    }

    private func balanceIncludeBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard let balances = vm.staged?.balances, index < balances.count else { return true }
                return balances[index].include
            },
            set: { newValue in
                guard var staged = vm.staged, index < staged.balances.count else { return }
                staged.balances[index].include = newValue
                vm.staged = staged
            }
        )
    }

    private func onAccountSectionAppear() {
        AMLogging.log("ReviewImportView.onAppear — file=\(staged.sourceFileName), initial userInstitutionName='\(vm.userInstitutionName)'", component: "ReviewImportView")
        selectedAccountId = nil
        vm.selectedAccountID = nil
        if let suggested = staged.suggestedAccountType {
            vm.newAccountType = suggested
        }
        let current = vm.userInstitutionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = staged.inferredInstitutionName?.trimmingCharacters(in: .whitespacesAndNewlines)
        AMLogging.log("ReviewImportView.onAppear — parsedInstitution=\(parsed ?? "nil") currentEmpty=\(current.isEmpty)", component: "ReviewImportView")
        if current.isEmpty, let inst = parsed, !inst.isEmpty {
            vm.userInstitutionName = inst
            AMLogging.log("ReviewImportView: Prefilled institution from parser — category=parser value=\(inst)", component: "ReviewImportView")
        } else if current.isEmpty {
            AMLogging.log("ReviewImportView: No prefill — category=none reason=noParsedInstitution", component: "ReviewImportView")
        } else {
            AMLogging.log("ReviewImportView: No prefill — category=none reason=alreadySet", component: "ReviewImportView")
        }
        if typicalPaymentInput.isEmpty {
            if vm.newAccountType == .loan, let hint = vm.typicalPaymentHint(for: .loan) {
                typicalPaymentInput = formatAmountForInput(hint)
                typicalPaymentParsed = hint
            } else if vm.newAccountType == .creditCard, let hint = vm.typicalPaymentHint(for: .creditCard) {
                typicalPaymentInput = formatAmountForInput(hint)
                typicalPaymentParsed = hint
            }
        }

        // Seed Typical Payment from a sentinel balance embedded by PDFSummaryParser (top-level init and fallback here)
        seedTypicalPaymentFromSentinelIfNeeded()
    }
    
    private func seedTypicalPaymentFromSentinelIfNeeded() {
        AMLogging.log("ReviewImportView: seedTypicalPaymentFromSentinelIfNeeded start — input='\(typicalPaymentInput)' parsed=\(String(describing: typicalPaymentParsed)) hasStaged=\(vm.staged != nil)", component: "ReviewImportView")
        guard typicalPaymentInput.isEmpty || typicalPaymentParsed == nil else {
            AMLogging.log("ReviewImportView: skipping seeding — input already present or parsed value exists", component: "ReviewImportView")
            return
        }
        guard var staged = vm.staged else {
            AMLogging.log("ReviewImportView: no staged import available; cannot seed typical payment", component: "ReviewImportView")
            return
        }
        let sentinelLabel = "__typical_payment__"
        if let idx = staged.balances.firstIndex(where: { ($0.sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == sentinelLabel }) {
            let amt = staged.balances[idx].balance
            AMLogging.log("ReviewImportView: sentinel found at index=\(idx) amount=\(amt)", component: "ReviewImportView")
            // Remove the sentinel so it doesn't show as a balance
            staged.balances.remove(at: idx)
            vm.staged = staged
            // Apply to UI fields
            typicalPaymentInput = formatAmountForInput(amt)
            typicalPaymentParsed = amt
            AMLogging.log("ReviewImportView: Seeded Typical Payment from sentinel — amount=\(amt)", component: "ReviewImportView")
        } else {
            AMLogging.log("ReviewImportView: sentinel not found in staged balances; attempting fallback from snapshot fields", component: "ReviewImportView")
            // Fallback: seed from any snapshot that carries a typicalPaymentAmount
            if let pay = staged.balances.compactMap({ $0.typicalPaymentAmount }).first(where: { $0 > 0 }) {
                typicalPaymentInput = formatAmountForInput(pay)
                typicalPaymentParsed = pay
                AMLogging.log("ReviewImportView: Seeded Typical Payment from snapshot field — amount=\(pay)", component: "ReviewImportView")
            } else {
                AMLogging.log("ReviewImportView: no typicalPaymentAmount found on snapshots; no seeding performed", component: "ReviewImportView")
            }
        }
    }

    private func parseCurrencyInput(_ s: String) -> Decimal? {
        let cleaned = s.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: cleaned)
    }

    private func formatAmountForInput(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 0
        nf.maximumFractionDigits = 2
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
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

    private func balanceDateBinding(for index: Int) -> Binding<Date> {
        Binding(
            get: {
                if let balances = vm.staged?.balances, index < balances.count {
                    return balances[index].asOfDate
                }
                return Date()
            },
            set: { newVal in
                if var staged = vm.staged, index < staged.balances.count {
                    staged.balances[index].asOfDate = newVal
                    vm.staged = staged
                }
            }
        )
    }
    private func balanceAmountTextBinding(for index: Int) -> Binding<String> {
        Binding(
            get: {
                guard let balances = vm.staged?.balances, index < balances.count else { return "" }
                let amount = balances[index].balance
                let nf = NumberFormatter()
                nf.numberStyle = .decimal
                nf.minimumFractionDigits = 0
                nf.maximumFractionDigits = 2
                return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
            },
            set: { newText in
                let cleaned = newText.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
                if let dec = Decimal(string: cleaned) {
                    if var staged = vm.staged, index < staged.balances.count {
                        staged.balances[index].balance = dec
                        vm.staged = staged
                    }
                }
            }
        )
    }
}

