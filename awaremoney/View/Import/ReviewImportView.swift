//
//  ReviewImportView.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import SwiftUI
import SwiftData
import UIKit

struct ReviewImportView: View {
    var staged: StagedImport
    @ObservedObject var vm: ImportViewModel
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject var settings: SettingsStore
    @Query(sort: [SortDescriptor(\Account.createdAt)]) private var accounts: [Account]
    @State private var selectedAccountId: UUID? = nil
    @State private var showPDFSheet = false
    @State private var typicalPaymentInput: String = ""
    @State private var typicalPaymentParsed: Decimal? = nil
    @State private var aprInput: String = ""
    @State private var aprScale: Int? = nil
    @State private var pendingStartingBalance: Decimal? = nil
    @State private var scrollProxy: ScrollViewProxy? = nil
    @State private var highlightTarget: String? = nil
    private var isEditing: Bool { focusedField != nil }
    @FocusState private var focusedField: FocusedField?
    private enum FocusedField: Hashable { case institution, typicalPayment, apr, startingBalance, balance(Int) }
    
    private var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Group {
                    if isPad {
                        HStack(spacing: 0) {
                            mainList
                                .frame(width: 380)
                            Divider()
                            pdfPane
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        mainList
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
            .onAppear {
                let hasStaged = (vm.staged != nil)
                let balancesCount = vm.staged?.balances.count ?? 0
                let hasSentinel = vm.staged?.balances.contains(where: { ($0.sourceAccountLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "__typical_payment__" }) ?? false
                AMLogging.log("ReviewImportView: top-level onAppear — hasStaged=\(hasStaged) balances=\(balancesCount) hasSentinel=\(hasSentinel) typicalPaymentInput='\(typicalPaymentInput)' parsed=\(String(describing: typicalPaymentParsed))", component: "ReviewImportView")
                seedTypicalPaymentFromSentinelIfNeeded()
            }
            .safeAreaInset(edge: .bottom) {
                Group {
                    if vm.isImporting {
                        EmptyView().frame(height: 0)
                    } else if isEditing {
                        EditingAccessoryBar(
                            canGoPrevious: canGoPrevious,
                            canGoNext: canGoNext,
                            onPrevious: { moveFocus(-1) },
                            onNext: { moveFocus(1) },
                            onDone: { commitAndDismissKeyboard() }
                        )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        bottomBar
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: isEditing)
                .animation(.snappy, value: vm.isImporting)
            }
            .onChange(of: focusedField) { _, newValue in
                switch newValue {
                case .some(.institution), .some(.typicalPayment), .some(.apr):
                    selectAllInFirstResponder()
                case .some(.balance(_)):
                    selectAllInFirstResponder()
                case .some(.startingBalance):
                    selectAllInFirstResponder()
                default:
                    break
                }
            }
            .onDisappear {
                // Ensure institution does not carry over to the next import
                vm.userInstitutionName = ""
            }
        }
        .presentationSizing(.page)
        .presentationDetents([.large])
        .sheet(isPresented: $showPDFSheet) {
            NavigationStack {
                if let url = resolvedPDFURL() {
                    ZStack(alignment: .topTrailing) {
                        PDFKitView(url: url)
                            .ignoresSafeArea()
                        DismissOverlay()
                            .padding(.top, 12)
                            .padding(.trailing, 12)
                    }
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
            .navigationTitle("View PDF")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showPDFSheet = false }
                }
            }
            .presentationDetents([.large])
            .presentationSizing(.page)
        }
    }
    
    private var mainList: some View {
        ScrollViewReader { proxy in
            Form {
                // Prominent error callout at the very top
//            if let err = vm.errorMessage, !err.isEmpty {
//                Section {
//                    HStack(alignment: .top, spacing: 8) {
//                        Image(systemName: "exclamationmark.triangle.fill")
//                            .foregroundStyle(.red)
//                        Text(err)
//                            .font(.subheadline)
//                            .foregroundStyle(.red)
//                    }
//                    .padding(.vertical, 2)
//                }
//                .listRowBackground(Color.red.opacity(0.08))
//            }

                // Review-required banner / checklist
                if !vm.computeCompletenessIssues().isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Image(systemName: vm.hasBlockingCompletenessIssues ? "exclamationmark.triangle.fill" : "exclamationmark.circle")
                                    .foregroundStyle(vm.hasBlockingCompletenessIssues ? .orange : .yellow)
                                Text("Review required")
                                    .font(.subheadline.weight(.semibold))
                            }
                            Text("We could't parse your statement completly. Please verify and complete the fields below." + (UIDevice.type == "iPhone" ? " Tap 'view PDF' for reference." : ""))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            Text("Tap an item to jump to the field below.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(vm.computeCompletenessIssues()) { issue in
                                    Button {
                                        #if canImport(UIKit)
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        #endif
                                        performChecklistAction(for: issue.title)
                                    } label: {
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Image(systemName: issue.severity == .required ? "exclamationmark.triangle" : "exclamationmark.circle")
                                                .foregroundStyle(issue.severity == .required ? .orange : .yellow)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(issue.title)
                                                    .font(.footnote.weight(.semibold))
                                                if let detail = issue.detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.footnote.weight(.semibold))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(ChecklistRowButtonStyle())
                                    .hoverEffect(.highlight)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.yellow.opacity(0.08))
                }

                Section() {
                    VStack {
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
                                .focused($focusedField, equals: .institution)
                                .submitLabel(.next)
                                .onSubmit { moveFocus(1) }
                                .onTapGesture { selectAllInFirstResponder() }
                            Picker("Type", selection: Binding(get: { vm.newAccountType }, set: { vm.newAccountType = $0 })) {
                                ForEach(Account.AccountType.allCases, id: \.self) {
                                    Text($0.rawValue)
                                }
                            }
                            if staged.sourceFileName.lowercased().hasSuffix(".pdf") && UIDevice.type == "iPhone" {
                                Button {
                                    AMLogging.log("ReviewImportView: View PDF tapped — filename=\(staged.sourceFileName)", component: "ReviewImportView")
                                    showPDFSheet = true
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "doc.text.magnifyingglass")
                                        Text("View PDF")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }  header: {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("File: \(staged.sourceFileName)")
                            .font(.callout)
                            .padding(.top, 10)
                            .frame(maxWidth: .infinity, alignment: .center)
                        HStack {
                            Text("Transactions: \(staged.transactions.count)")
                            if !staged.holdings.isEmpty {
                                Text("Holdings: \(staged.holdings.count)")
                            }
                            if !staged.balances.isEmpty {
                                Text("Balances: \(staged.balances.count)")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.bottom,10)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .foregroundStyle(.primary)
//                .multilineTextAlignment(.center)
//                .frame(maxWidth: .infinity, alignment: .center)
                }

                // Loan Terms — single place to edit Typical Payment and APR
                if vm.newAccountType == .loan || vm.newAccountType == .creditCard {
                    Section("Loan Terms") {
                        VStack {
                            LabeledContent("Typical Payment") {
                                TextField("0.00", text: $typicalPaymentInput)
                                    .multilineTextAlignment(.trailing)
                                    .keyboardType(.decimalPad)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .onChange(of: typicalPaymentInput, initial: false) { _, newValue in
                                        typicalPaymentParsed = parseCurrencyInput(newValue)
                                    }
                                    .focused($focusedField, equals: .typicalPayment)
                                    .id("typicalPaymentField")
                                    .submitLabel(.next)
                                    .onSubmit { moveFocus(1) }
                                    .onTapGesture { selectAllInFirstResponder() }
                                    .background(highlightTarget == "typicalPaymentField" ? Color.accentColor.opacity(0.12) : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            Text("Used for payoff estimates and budget projections.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            LabeledContent("Interest Rate (APR)") {
                                TextField("0.00", text: $aprInput)
                                    .multilineTextAlignment(.trailing)
                                    .keyboardType(.decimalPad)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .focused($focusedField, equals: .apr)
                                    .id("aprField")
                                    .submitLabel(.done)
                                    .onSubmit { commitAndDismissKeyboard() }
                                    .onTapGesture { selectAllInFirstResponder() }
                                    .background(highlightTarget == "aprField" ? Color.accentColor.opacity(0.12) : .clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            Text("Enter as a percent (e.g., 19.99 for 19.99%).")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                // Starting balance prompt
                if (vm.staged?.balances.isEmpty ?? true), let earliestDate = vm.staged?.transactions.map({ $0.datePosted }).min() {
                    StartingBalanceInlineView(
                        asOfDate: earliestDate,
                        onSet: { dec, pickedDate in
                            let sb = StagedBalance(asOfDate: pickedDate, balance: dec)
                            vm.staged?.balances.append(sb)
                        },
                        focusedField: $focusedField,
                        focusedCase: .startingBalance,
                        onNext: { moveFocus(1) },
                        onAmountChange: { dec in
                            pendingStartingBalance = dec
                        }
                    )
                    .id("startingBalancePrompt")
                    .background(highlightTarget == "startingBalancePrompt" ? Color.accentColor.opacity(0.12) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                
                // Fallback: when there are no transactions and no balances, allow entering an ending balance manually
                if (vm.staged?.transactions.isEmpty ?? true) && (vm.staged?.balances.isEmpty ?? true) {
                    StartingBalanceInlineView(
                        asOfDate: Date(),
                        onSet: { dec, pickedDate in
                            let sb = StagedBalance(asOfDate: pickedDate, balance: dec)
                            vm.staged?.balances.append(sb)
                            AMLogging.log("ReviewImportView: User added ending balance fallback — value=\(dec) date=\(pickedDate)", component: "ReviewImportView")
                        },
                        focusedField: $focusedField,
                        focusedCase: .startingBalance,
                        onNext: { moveFocus(1) },
                        title: "Ending Balance",
                        messageOverride: "Enter the ending balance and choose the statement date.",
                        onAmountChange: { dec in
                            pendingStartingBalance = dec
                        }
                    )
                    .id("startingBalancePrompt")
                    .background(highlightTarget == "startingBalancePrompt" ? Color.accentColor.opacity(0.12) : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                // Transactions preview
                if !staged.transactions.isEmpty {
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
                                Text(t.amount as NSNumber, formatter: currencyFormatter)
                                    .foregroundStyle(t.amount < 0 ? .red : .primary)
                            }
                        }
                    }
                }

                // Holdings
                if !staged.holdings.isEmpty {
                    Section("Holdings") {
                        ForEach(staged.holdings.indices, id: \.self) { idx in
                            let h = staged.holdings[idx]
                            HStack {
                                Toggle("", isOn: holdingIncludeBinding(for: idx))
                                .labelsHidden()
                                Text("\(h.symbol) — \(h.quantity.description)")
                                Spacer()
                                if let mv = h.marketValue {
                                    Text(mv as NSNumber, formatter: currencyFormatter)
                                }
                            }
                        }
                    }
                }

                if let balances = vm.staged?.balances, !balances.isEmpty {
                    Section("Balances") {
                        VStack {
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
                                                .focused($focusedField, equals: .balance(idx))
                                                .id("balanceField-\(idx)")
                                                .submitLabel(.next)
                                                .onSubmit { moveFocus(1) }
                                                .onTapGesture { selectAllInFirstResponder() }
                                                .background(highlightTarget == "balanceField-\(idx)" ? Color.accentColor.opacity(0.12) : .clear)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))
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
                            .id("addBalanceButton")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                
                Section() {
//                if let err = vm.errorMessage, !err.isEmpty {
//                    HStack(alignment: .top, spacing: 8) {
//                        Image(systemName: "exclamationmark.triangle")
//                            .foregroundStyle(.red)
//                        Text(err)
//                            .font(.footnote)
//                            .foregroundStyle(.red)
//                    }
//                    .padding(.vertical, 2)
//                }
                } header: {
                    VStack {
                        Text("Notes")
                            .frame(maxWidth: .infinity,alignment: .leading)
                        if let info = vm.infoMessage, !info.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle")
                                    .foregroundStyle(.blue)
                                Text(info)
                                    .font(.footnote)
                            }
                            .padding(.vertical, 2)
                        }
                        if vm.hasBlockingCompletenessIssues || !vm.computeCompletenessIssues().isEmpty { Text("Verify and correct all fields before saving.").font(.footnote).foregroundStyle(.secondary) }
                    }
//                .foregroundStyle(.primary)
                }
            }
            .onAppear { self.scrollProxy = proxy }
            .scrollDismissesKeyboard(.interactively)
            .listRowSpacing(6)
            .listSectionSpacing(.compact)
            .environment(\.defaultMinListRowHeight, 34)
            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            .onChange(of: selectedAccountId, initial: false) { _, newValue in
                AMLogging.log("ReviewImportView: selectedAccountId changed -> \(String(describing: newValue))", component: "ReviewImportView")
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Button(role: .cancel) {
                    vm.staged = nil
                    vm.infoMessage = nil
                    typicalPaymentInput = ""
                    vm.userInstitutionName = ""
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

                    // If the only missing required field was a starting/ending balance and the user has typed it but not tapped Add, append it now
                    if let pending = pendingStartingBalance, (vm.staged?.balances.isEmpty ?? true) {
                        let asOf = (vm.staged?.transactions.map { $0.datePosted }.min()) ?? Date()
                        let sb = StagedBalance(asOfDate: asOf, balance: pending)
                        vm.staged?.balances.append(sb)
                        AMLogging.log("ReviewImportView: Auto-appended pending starting balance before save — value=\(pending) date=\(asOf)", component: "ReviewImportView")
                    }

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
                        
                        // Persist APR to the chosen account if available
                        if let (aprFraction, scale) = parsePercentInput(aprInput) {
                            let targetAccount: Account? = {
                                if let sel = selectedAccountId {
                                    return accounts.first(where: { $0.id == sel })
                                } else {
                                    let all = (try? modelContext.fetch(FetchDescriptor<Account>())) ?? []
                                    let liabilities = all.filter { $0.type == .creditCard || $0.type == .loan }
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
                                terms.apr = aprFraction
                                terms.aprScale = scale
                                acct.loanTerms = terms
                                try? modelContext.save()
                                NotificationCenter.default.post(name: .accountsDidChange, object: nil)
                                AMLogging.log("ReviewImportView: Persisted APR to account id=\(acct.id) apr=\(aprFraction) scale=\(String(describing: scale))", component: "ReviewImportView")
                            } else {
                                AMLogging.log("ReviewImportView: Unable to resolve account to persist APR", component: "ReviewImportView")
                            }
                        } else {
                            AMLogging.log("ReviewImportView: Not persisting APR — input empty or invalid", component: "ReviewImportView")
                        }
                        
                        vm.userInstitutionName = ""
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
                .disabled({
                    // Allow enabling when the only blocking issue is missing balance, but the user has typed a valid pending amount
                    let issues = vm.computeCompletenessIssues()
                    if issues.contains(where: { $0.severity == .required }) {
                        // If a pending starting balance exists, treat as satisfied
                        if pendingStartingBalance != nil {
                            // Additional guard: if there are multiple required issues in other contexts in the future, keep disabled
                            let requiredCount = issues.filter { $0.severity == .required }.count
                            return requiredCount > 1
                        }
                        return true
                    }
                    return false
                }())
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .padding(.bottom, 8)
            .background(.regularMaterial)
        }
    }
    
//    private var editingAccessoryBar: some View {
//        HStack(spacing: 16) {
//
//            Button { moveFocus(-1) } label: {
//                Image(systemName: "chevron.left")
//                    .font(.title2)
//                    .frame(width: 44, height: 44)
//                    .contentShape(Rectangle())
//            }
//            .buttonStyle(.plain)
//            .disabled(!canGoPrevious)
//            .accessibilityLabel("Previous field")
//
//            Button { moveFocus(1) } label: {
//                Image(systemName: "chevron.right")
//                    .font(.title2)
//                    .frame(width: 44, height: 44)
//                    .contentShape(Rectangle())
//            }
//            .buttonStyle(.plain)
//            .disabled(!canGoNext)
//            .accessibilityLabel("Next field")
//
//            Spacer()
//
//            Button { commitAndDismissKeyboard() } label: {
//                Image(systemName: "checkmark")
//                    .font(.title2.weight(.semibold))
//                    .frame(width: 44, height: 44)
//                    .contentShape(Rectangle())
//            }
//            .buttonStyle(.plain)
//            .accessibilityLabel("Done editing")
//        }
//        .padding(.horizontal, 12)
//        .padding(.vertical, 10)
//        .background(.bar)
//        .overlay(Divider(), alignment: .top)
//    }
//    
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
        if vm.newAccountType == .creditCard && vm.creditCardFlipOverride == nil {
            vm.creditCardFlipOverride = settings.creditCardFlipDefault
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
        
        // Seed APR input from any staged balance that carries an APR
        if aprInput.isEmpty {
            if let apr = vm.staged?.balances.compactMap({ $0.interestRateAPR }).first {
                aprInput = formatPercentForInput(apr, scale: vm.staged?.balances.compactMap({ $0.interestRateScale }).first)
                aprScale = vm.staged?.balances.compactMap({ $0.interestRateScale }).first
                AMLogging.log("ReviewImportView: Seeded APR from staged balances — apr=\(apr) scale=\(String(describing: aprScale))", component: "ReviewImportView")
            }
        }
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
    
    private func resolvedPDFURL() -> URL? {
        // Prefer a directly cached local URL from the import flow
        if let direct = vm.lastPickedLocalURL {
            AMLogging.log("ReviewImportView: PDF preview using lastPickedLocalURL=\(direct.path)", component: "ReviewImportView")
            return direct
        }
        // Fallback: look in Caches using the staged file name
        let lower = staged.sourceFileName.lowercased()
        if lower.hasSuffix(".pdf"), let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let candidate = caches.appendingPathComponent(staged.sourceFileName)
            if FileManager.default.fileExists(atPath: candidate.path) {
                AMLogging.log("ReviewImportView: PDF preview using caches candidate=\(candidate.path)", component: "ReviewImportView")
                return candidate
            } else {
                AMLogging.log("ReviewImportView: PDF preview missing for candidate=\(candidate.path)", component: "ReviewImportView")
            }
        } else {
            AMLogging.log("ReviewImportView: PDF preview unavailable — fileName='\(staged.sourceFileName)'", component: "ReviewImportView")
        }
        return nil
    }
    
    private var pdfPane: some View {
        Group {
            if let url = resolvedPDFURL() {
                PDFKitView(url: url)
                    .ignoresSafeArea()
            } else {
                ContentUnavailableView(
                    "PDF Preview",
                    systemImage: "doc.richtext",
                    description: Text("No preview available")
                )
            }
        }
    }

    private func parseCurrencyInput(_ s: String) -> Decimal? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Keep only digits, minus sign, and separators
        let allowed = CharacterSet(charactersIn: "-0123456789.,")
        let filtered = String(trimmed.unicodeScalars.filter { allowed.contains($0) })
        guard !filtered.isEmpty else { return nil }
        var normalized = filtered
        if filtered.contains(",") && filtered.contains(".") {
            // Assume commas are thousands separators
            normalized = filtered.replacingOccurrences(of: ",", with: "")
        } else if filtered.contains(",") && !filtered.contains(".") {
            // Treat comma as decimal separator
            normalized = filtered.replacingOccurrences(of: ",", with: ".")
        }
        return Decimal(string: normalized)
    }
    
    private func parsePercentInput(_ s: String) -> (Decimal, Int)? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleaned = trimmed.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")
        guard let dec = Decimal(string: cleaned) else { return nil }
        let scale: Int = {
            if let dot = cleaned.firstIndex(of: ".") { return cleaned.distance(from: cleaned.index(after: dot), to: cleaned.endIndex) }
            return 0
        }()
        var fraction = dec
        if fraction > 1 { fraction /= 100 }
        return (fraction, scale)
    }

    private func formatAmountForInput(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }
    
    private func formatPercentForInput(_ apr: Decimal, scale: Int?) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if let s = scale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s } else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
        return nf.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr * 100)%"
    }

    private var currencyFormatter: NumberFormatter {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf
    }
    
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
    
    private var focusOrder: [FocusedField] {
        var order: [FocusedField] = []
        if selectedAccountId == nil {
            order.append(.institution)
        }
        if vm.newAccountType == .loan || vm.newAccountType == .creditCard {
            order.append(.typicalPayment)
            order.append(.apr)
        }
        if (vm.staged?.balances.isEmpty ?? true) {
            order.append(.startingBalance)
        }
        if let count = vm.staged?.balances.count, count > 0 {
            for idx in 0..<count {
                order.append(.balance(idx))
            }
        }
        return order
    }

    private var canGoPrevious: Bool {
        guard let focusedField, let i = focusOrder.firstIndex(of: focusedField) else { return false }
        return i > 0
    }

    private var canGoNext: Bool {
        guard let focusedField, let i = focusOrder.firstIndex(of: focusedField) else { return false }
        return i < focusOrder.count - 1
    }
    private func moveFocus(_ delta: Int) {
        let order = focusOrder
        guard !order.isEmpty else { return }
        if let current = focusedField, let idx = order.firstIndex(of: current) {
            let nextIdx = (idx + delta + order.count) % order.count
            focusedField = order[nextIdx]
        } else {
            focusedField = order.first
        }
    }

    private func scrollAndFocus(to id: AnyHashable?, focus: FocusedField?) {
        // Scroll to the anchor and then focus the field with a slight delay to allow layout to settle
        if let id = id, let proxy = scrollProxy {
            withAnimation(.snappy) {
                proxy.scrollTo(id, anchor: .center)
            }
        }
        if let f = focus {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                focusedField = f
            }
        }
        if let id = id as? String {
            withAnimation(.easeInOut(duration: 0.2)) { highlightTarget = id }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation(.easeInOut(duration: 0.25)) { highlightTarget = nil }
            }
        }
    }

    private func performChecklistAction(for title: String) {
        switch title {
        case "Add a statement balance":
            if (vm.staged?.balances.isEmpty ?? true) {
                scrollAndFocus(to: "startingBalancePrompt", focus: .startingBalance)
            } else {
                scrollAndFocus(to: "balanceField-0", focus: .balance(0))
            }
        case "Enter APR":
            scrollAndFocus(to: "aprField", focus: .apr)
        case "Set a typical monthly payment":
            scrollAndFocus(to: "typicalPaymentField", focus: .typicalPayment)
        default:
            break
        }
    }

    private func commitAndDismissKeyboard() {
        // Reformat Typical Payment
        if let dec = parseCurrencyInput(typicalPaymentInput) {
            typicalPaymentInput = formatAmountForInput(dec)
            typicalPaymentParsed = dec
        }
        // Reformat APR
        if let (fraction, scale) = parsePercentInput(aprInput) {
            aprInput = formatPercentForInput(fraction, scale: scale)
            aprScale = scale
        }
        focusedField = nil
        #if canImport(UIKit)
        // Dismiss any active first responder to ensure the keyboard hides for fields not tracked by FocusState
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        keyWindow?.endEditing(true)
        #endif
    }
    
    private func selectAllInFirstResponder(after delay: TimeInterval = 0.05) {
        #if canImport(UIKit)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
        }
        #endif
    }
}

private struct DismissOverlay: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: Circle())
        .accessibilityLabel("Close")
    }
}

private struct ChecklistRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(configuration.isPressed ? Color.yellow.opacity(0.15) : .clear)
            .animation(.easeInOut(duration: 0.12), value: configuration.isPressed)
    }
}
