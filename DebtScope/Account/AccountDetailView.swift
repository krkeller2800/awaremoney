import SwiftUI
import SwiftData
import UIKit

enum AccountDetailInitialFocus: Hashable, Sendable {
    case apr
    case paymentAmount
}

struct AccountDetailView: View {
    let accountID: UUID
    let initialFocus: AccountDetailInitialFocus?
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }
    private var isIPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    // Query the account live by ID so we never hold a detached instance
    @Query private var fetchedAccounts: [Account]

    @State private var showStartingBalanceSheet = false
    @State private var showRecordedBalanceInfo = false
    @State private var showMergeSheet = false
    @State private var mergeTargetID: UUID?
    @State private var cachedDerivedBalance: Decimal? = nil
    @State private var cachedEarliestTransactionDate: Date? = nil
    @State private var showDeleteAlert = false
    @State private var manualAssetValueDraft: String = ""
    @State private var manualAssetValueDraftAccountID: UUID? = nil
    @State private var aprDraft: String = ""
    @State private var aprDraftAccountID: UUID? = nil
    @State private var paymentDraft: String = ""
    @State private var paymentDraftAccountID: UUID? = nil
    @State private var didApplyInitialFocus = false

    @Query(filter: #Predicate<Account> { $0.typeRaw == "loan" }, sort: [SortDescriptor(\Account.name, order: .forward)]) private var liabilityAccounts: [Account]

    @State private var linkedLiabilityID: UUID? = nil
    @State private var activeAssetLink: AssetLiabilityLink? = nil
    @State private var suppressLinkOnChange = false
    @State private var showHelpSheet = false
    @State private var showLTVInfo = false

    
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case institution
        case apr
        case paymentAmount
        case assetValue
    }

    private var isEditing: Bool { focusedField != nil }

    init(accountID: UUID, initialFocus: AccountDetailInitialFocus? = nil) {
        self.accountID = accountID
        self.initialFocus = initialFocus
        _fetchedAccounts = Query(filter: #Predicate<Account> { $0.id == accountID }, sort: [])
    }

    private var account: Account? { fetchedAccounts.first }

    var body: some View {
        Group {
            if let account {
                Group {
                    if isRegularWidth {
                        detailsList(for: account)
                            .listStyle(.plain)
                            .scrollContentBackground(.hidden)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        detailsList(for: account)
                            .listStyle(.insetGrouped)
                            .scrollContentBackground(.automatic)
                    }
                }
                .navigationTitle(account.name)
                .navigationBarBackButtonHidden(isIPad)
                .sheet(isPresented: $showStartingBalanceSheet) {
                    StartingBalanceSheet(account: account, defaultDate: defaultStartingBalanceDate(for: account))
                }
                .sheet(isPresented: $showMergeSheet) {
                    NavigationStack {
                        MergeAccountSheet(currentAccountID: account.id, selectedTargetID: $mergeTargetID)
                            .environment(\.modelContext, modelContext)
                    }
                }
                .alert("Delete this asset?", isPresented: $showDeleteAlert) {
                    Button("Delete", role: .destructive) {
                        deleteAccount(account)
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will permanently delete the asset and all associated balances and transactions.")
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if UIDevice.type == "iPhone" {
                            Button {
                                showHelpSheet = true
                            } label: {
                                Image(systemName: "questionmark.circle")
                            }
                            .accessibilityLabel("Help")
                        }

                        if account.isManualAsset {
                            Button(role: .destructive) {
                                showDeleteAlert = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Delete Asset")
                        }
                    }
                }
            } else {
                ContentUnavailableView("Account no longer exists", systemImage: "exclamationmark.triangle")
            }
        }
        .fullScreenCover(isPresented: $showHelpSheet) {
            NavigationStack { HelpVideosView() }
                .ignoresSafeArea()
        }
        // If the account disappears (e.g., after batch deletion), dismiss this screen
        .onChange(of: fetchedAccounts.count) { _, newCount in
            AMLogging.log("AccountDetailView fetchedAccounts count changed to \(newCount) for accountID=\(accountID)", component: "AccountDetailView")
            if newCount == 0 && !isIPad { // only pop on iPhone
                dismiss()
            }
        }
        .task(id: accountID) {
            await recomputeAccountDerivedData(accountID: accountID)
            loadAssetLiabilityLink(assetID: accountID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in
            Task {
                await recomputeAccountDerivedData(accountID: accountID)
            }
        }
        .onAppear {
            AMLogging.log("AccountDetailView appear accountID=\(accountID)", component: "AccountDetailView")
            if let account {
                applyInitialFocusIfNeeded(for: account)
            }
        }
        .onChange(of: focusedField) { _, newValue in
            guard let field = newValue else { return }
            if field == .assetValue, let account {
                prepareManualAssetValueDraft(for: account)
            }
            if field == .apr, let account {
                prepareAPRDraft(for: account)
            }
            if field == .institution || field == .apr || field == .paymentAmount || field == .assetValue {
                selectAllInFirstResponder()
            }
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if let account = account, isEditing {
                    EditingAccessoryBar(
                        canGoPrevious: canGoPrevious(for: account),
                        canGoNext: canGoNext(for: account),
                        onPrevious: { moveFocus(-1, for: account) },
                        onNext: { moveFocus(1, for: account) },
                        onDone: { commitAndDismissKeyboard() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    EmptyView().frame(height: 0)
                }
            }
            .animation(.snappy, value: isEditing)
        }
    }

    @ViewBuilder
    private func detailsList(for account: Account) -> some View {
        List {
            Section(header: GroupedSectionHeader("Details")) {
                LabeledContent("Name", value: account.name)
                LabeledContent(account.isManualAsset ? "Description" : "Institution") {
                    HStack(spacing: 6) {
                        TextField(account.isManualAsset ? "Description (optional)" : "Institution name", text: Binding<String>(
                            get: { account.institutionName ?? "" },
                            set: { newVal in
                                let trimmed = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                                account.institutionName = trimmed
                                // Keep account name in sync with institution when edited here (non-manual accounts only)
                                if !account.isManualAsset, account.name != trimmed {
                                    account.name = trimmed
                                }
                                do { try modelContext.save() } catch {}
                                NotificationCenter.default.post(name: .accountsDidChange, object: nil)
                            }
                        ))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .institution)

                        Button {
                            focusedField = .institution
                        } label: {
                            Image(systemName: "pencil")
                                .foregroundStyle(.secondary)
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Edit \(account.isManualAsset ? "description" : "institution")")
                    }
                }
                if !account.isManualAsset && isInvalidInstitutionName(account.institutionName) {
                    Text("Required. We couldn't derive this from your import.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                if account.isManualAsset {
                    Picker("Bucket", selection: assetCategoryBinding(for: account)) {
                        ForEach(Account.AssetCategory.allCases, id: \.self) { category in
                            Text(category.displayName).tag(category)
                        }
                    }
                } else {
                    LabeledContent("Type", value: account.type.rawValue.capitalized)
                }
                if account.type == .brokerage && account.balanceSnapshots.isEmpty && account.holdingSnapshots.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.blue)
                            Text("Brokerage activity won't affect Net Worth until you import a statement with balances/holdings or set a starting balance.")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }

            if account.supportsLinkedLiability {
                Section(header: GroupedSectionHeader("Financing")) {
                    HStack(spacing: 6) {
                        Picker("Liability Account", selection: $linkedLiabilityID) {
                            Text("None").tag(nil as UUID?)
                            ForEach(liabilityAccounts.filter { $0.id != account.id }, id: \.id) { liab in
                                let label = "\(liab.name) — \(liab.type.rawValue.capitalized)"
                                Text(label).tag(Optional(liab.id))
                            }
                        }
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                            .accessibilityHidden(true)
                    }
                    .onChange(of: linkedLiabilityID) { _, newVal in
                        if suppressLinkOnChange { return }
                        // If the selection becomes nil because the currently linked account isn't in the available options (e.g., filtered out),
                        // don't delete the existing link.
                        if newVal == nil, let activeLiabilityID = activeAssetLink?.liabilityID, !liabilityAccounts.contains(where: { $0.id == activeLiabilityID }) {
                            return
                        }
                        updateAssetLiabilityLink(for: account, to: newVal)
                    }

                    // Show net equity for linked assets; LTV only applies to property and vehicle buckets.
                    if let liabID = linkedLiabilityID,
                       let liab = liabilityAccounts.first(where: { $0.id == liabID }) {
                        let assetVal: Decimal = lastBalanceSnapshot(for: account)?.balance ?? 0
                        let debtMag: Decimal = {
                            let bal = lastBalanceSnapshot(for: liab)?.balance ?? 0
                            return bal < 0 ? -bal : bal
                        }()
                        if assetVal != 0 {
                            LabeledContent("Net Equity") {
                                Text(format(amount: assetVal - debtMag))
                            }
                            if account.showsLoanToValue {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("LTV")
                                    Spacer()
                                    Text(formatPercent(debtMag / assetVal))
                                }
                            }
                        }
                    }
                    DisclosureGroup(isExpanded: $showLTVInfo) {
                        Text("LTV = liability amount ÷ asset value. It is shown for property and vehicle assets.\nExample: $80,000 on $100,000 = 80%.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .transition(.opacity.combined(with: .move(edge: .leading)))
                        
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                            Text("LTV hint")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel(showLTVInfo ? "Hide LTV definition" : "Show LTV definition")

                    
                    Text("Link a liability to track net equity. LTV is shown for property and vehicle assets.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if account.type == .loan || account.type == .creditCard {
                Section(header: GroupedSectionHeader("Payment Plan")) {
                    LabeledContent("APR") {
                        HStack(spacing: 6) {
                            TextField("0.00%", text: Binding<String>(
                                get: {
                                    if aprDraftAccountID == account.id {
                                        return aprDraft
                                    }
                                    return account.loanTerms?.apr.map { formatAPR($0, scale: account.loanTerms?.aprScale) } ?? ""
                                },
                                set: { newVal in
                                    aprDraft = newVal
                                    aprDraftAccountID = account.id
                                    saveAPRInput(newVal, for: account)
                                }
                            ))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                            .focused($focusedField, equals: .apr)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: focusedField) { oldValue, newValue in
                                if oldValue == .apr && newValue != .apr {
                                    formatAPRDraft(for: account)
                                }
                            }
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    prepareAPRDraft(for: account)
                                    focusedField = .apr
                                    selectAllInFirstResponder()
                                }
                            )

                            Button {
                                prepareAPRDraft(for: account)
                                focusedField = .apr
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                                    .imageScale(.small)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit APR")
                        }
                    }

                    // Typical payment editor
                    LabeledContent("Typical Payment") {
                        HStack(spacing: 6) {
                            TextField("0.00", text: Binding<String>(
                                get: {
                                    if paymentDraftAccountID == account.id {
                                        return paymentDraft
                                    }
                                    return account.loanTerms?.paymentAmount.map { formatAmountForInput($0) } ?? ""
                                },
                                set: { newVal in
                                    paymentDraft = newVal
                                    paymentDraftAccountID = account.id
                                    savePaymentInput(newVal, for: account)
                                }
                            ))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .focused($focusedField, equals: .paymentAmount)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: focusedField) { oldValue, newValue in
                                if oldValue == .paymentAmount && newValue != .paymentAmount {
                                    formatPaymentDraft(for: account)
                                }
                            }
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    preparePaymentDraft(for: account)
                                    focusedField = .paymentAmount
                                    selectAllInFirstResponder()
                                }
                            )

                            Button {
                                preparePaymentDraft(for: account)
                                focusedField = .paymentAmount
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                                    .imageScale(.small)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit payment amount")
                        }
                    }

                    // Due day picker
                    HStack(spacing: 6) {
                        Picker("Due Day", selection: Binding<Int?>(
                            get: { account.loanTerms?.paymentDayOfMonth },
                            set: { newVal in
                                var terms = account.loanTerms ?? LoanTerms()
                                terms.paymentDayOfMonth = newVal
                                account.loanTerms = terms
                                try? modelContext.save()
                                NotificationCenter.default.post(name: .accountsDidChange, object: nil)
                            }
                        )) {
                            Text("None").tag(nil as Int?)
                            ForEach(1...31, id: \.self) { d in
                                Text("\(d)").tag(Optional(d))
                            }
                        }
                        Image(systemName: "pencil")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                            .accessibilityHidden(true)
                    }

                    if let amt = account.loanTerms?.paymentAmount, amt > 0 {
                        Text("Used for payoff estimates and budget projections.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Enter your usual monthly payment to enable payoff estimates.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section(header: GroupedSectionHeader("Balance Info")) {
                if account.isManualAsset {
                    LabeledContent("Asset Value") {
                        HStack(spacing: 6) {
                            TextField("0.00", text: manualAssetValueBinding(for: account))
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.decimalPad)
                                .focused($focusedField, equals: .assetValue)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()

                            Button {
                                focusedField = .assetValue
                            } label: {
                                Image(systemName: "pencil")
                                    .foregroundStyle(.secondary)
                                    .imageScale(.small)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Edit asset value")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Transactional Balance")
                        Spacer()
                        if let derived = cachedDerivedBalance {
                            Text(format(amount: derived))
                                .foregroundStyle(derived < 0 ? .red : .primary)
                        } else {
                            Text("Unavailable")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if lastBalanceSnapshot(for: account) != nil {
                        Text("Latest recorded balance plus transactions since then.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Sum of transactions.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Latest Recorded Balance")
                        Button {
                            showRecordedBalanceInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if let last = lastBalanceSnapshot(for: account) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(format(amount: last.balance))
                                    .foregroundStyle(last.balance < 0 ? .red : .primary)
                                Text(last.asOfDate, style: .date)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if let apr = last.interestRateAPR {
                                    Text("APR: \(formatAPR(apr, scale: last.interestRateScale))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text("None")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .alert("Recorded balance", isPresented: $showRecordedBalanceInfo) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text("Shows the most recent balance recorded from a statement or import. Manual starting balances are added as adjustments and appear below.")
                    }
                    Text("Latest recorded balance from a statement or import.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section(header: GroupedSectionHeader("Maintenance")) {
                Button(role: .destructive) {
                    mergeTargetID = nil
                    showMergeSheet = true
                } label: {
                    Label("Merge Into Another Account…", systemImage: "arrow.triangle.merge")
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: isRegularWidth ? 760 : 760, alignment: .center)
        .padding(.horizontal, isRegularWidth ? 24 : 16)
        .frame(maxWidth: .infinity, alignment: .center)
        .overlay(alignment: .topTrailing) {
            if !isRegularWidth && !account.isManualAsset {
                NavigationLink {
                    AccountTransactionsListView(accountID: account.id)
                } label: {
                    Label("Transactions", systemImage: "list.bullet")
                }
                .padding(.top, 0)
                .padding(.trailing, 50)
                .simultaneousGesture(TapGesture().onEnded {
                    AMLogging.log("Transactions button tapped for accountID=\(account.id)", component: "AccountDetailView")
                })
            }
        }
    }

    private func assetCategoryBinding(for account: Account) -> Binding<Account.AssetCategory> {
        Binding(
            get: { account.assetCategory },
            set: { newValue in
                account.assetCategory = newValue
                try? modelContext.save()
                NotificationCenter.default.post(name: .accountsDidChange, object: nil)
            }
        )
    }

    private func manualAssetValueBinding(for account: Account) -> Binding<String> {
        Binding(
            get: {
                if focusedField == .assetValue, manualAssetValueDraftAccountID == account.id {
                    return manualAssetValueDraft
                }
                guard let balance = lastBalanceSnapshot(for: account)?.balance else { return "" }
                return formatAmountForInput(balance)
            },
            set: { newValue in
                manualAssetValueDraft = newValue
                manualAssetValueDraftAccountID = account.id

                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let parsed = parseCurrencyInput(trimmed) else {
                    if trimmed.isEmpty, let snapshot = lastBalanceSnapshot(for: account) {
                        snapshot.balance = .zero
                        snapshot.accountID = account.id
                        snapshot.isUserModified = true
                        cachedDerivedBalance = .zero
                        try? modelContext.save()
                        NotificationCenter.default.post(name: .accountsDidChange, object: nil)
                    }
                    return
                }

                if let snapshot = lastBalanceSnapshot(for: account) {
                    snapshot.balance = parsed
                    snapshot.accountID = account.id
                    snapshot.isUserModified = true
                } else {
                    let snapshot = BalanceSnapshot(
                        asOfDate: .now,
                        balance: parsed,
                        account: account,
                        isUserCreated: true,
                        isUserModified: true
                    )
                    modelContext.insert(snapshot)
                    account.balanceSnapshots.append(snapshot)
                }

                cachedDerivedBalance = parsed
                try? modelContext.save()
                NotificationCenter.default.post(name: .accountsDidChange, object: nil)
            }
        )
    }

    private func prepareManualAssetValueDraft(for account: Account) {
        guard manualAssetValueDraftAccountID != account.id else { return }
        manualAssetValueDraft = lastBalanceSnapshot(for: account).map { editableDecimalString($0.balance) } ?? ""
        manualAssetValueDraftAccountID = account.id
    }

    private func prepareAPRDraft(for account: Account) {
        guard aprDraftAccountID != account.id else { return }
        aprDraft = account.loanTerms?.apr.map { formatAPR($0, scale: account.loanTerms?.aprScale) } ?? ""
        aprDraftAccountID = account.id
    }

    private func preparePaymentDraft(for account: Account) {
        guard paymentDraftAccountID != account.id else { return }
        paymentDraft = account.loanTerms?.paymentAmount.map { formatAmountForInput($0) } ?? ""
        paymentDraftAccountID = account.id
    }

    private func saveAPRInput(_ rawValue: String, for account: Account) {
        var terms = account.loanTerms ?? LoanTerms()
        if let (fraction, scale) = parsePercentInput(rawValue) {
            terms.apr = fraction
            terms.aprScale = scale
            if let snapshot = lastBalanceSnapshot(for: account) {
                snapshot.interestRateAPR = fraction
                snapshot.interestRateScale = scale
                snapshot.isUserModified = true
            }
        } else if rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            terms.apr = nil
            terms.aprScale = nil
            if let snapshot = lastBalanceSnapshot(for: account) {
                snapshot.interestRateAPR = nil
                snapshot.interestRateScale = nil
                snapshot.isUserModified = true
            }
        }
        account.loanTerms = terms
        try? modelContext.save()
        NotificationCenter.default.post(name: .accountsDidChange, object: nil)
    }

    private func savePaymentInput(_ rawValue: String, for account: Account) {
        var terms = account.loanTerms ?? LoanTerms()
        if let decimal = parseCurrencyInput(rawValue) {
            terms.paymentAmount = decimal
        } else if rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            terms.paymentAmount = nil
        }
        account.loanTerms = terms
        try? modelContext.save()
        NotificationCenter.default.post(name: .accountsDidChange, object: nil)
    }

    private func formatAPRDraft(for account: Account) {
        guard aprDraftAccountID == account.id else { return }
        if let (fraction, scale) = parsePercentInput(aprDraft) {
            aprDraft = formatAPR(fraction, scale: scale)
        } else if account.loanTerms?.apr == nil {
            aprDraft = ""
        }
    }

    private func formatPaymentDraft(for account: Account) {
        guard paymentDraftAccountID == account.id else { return }
        if let decimal = parseCurrencyInput(paymentDraft) {
            paymentDraft = formatAmountForInput(decimal)
        } else if account.loanTerms?.paymentAmount == nil {
            paymentDraft = ""
        }
    }

    private func applyInitialFocusIfNeeded(for account: Account) {
        guard !didApplyInitialFocus, let initialFocus else { return }
        didApplyInitialFocus = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            switch initialFocus {
            case .apr:
                prepareAPRDraft(for: account)
                focusedField = .apr
            case .paymentAmount:
                preparePaymentDraft(for: account)
                focusedField = .paymentAmount
            }
            selectAllInFirstResponder(after: 0.05)
        }
    }

    private func editableDecimalString(_ amount: Decimal) -> String {
        NSDecimalNumber(decimal: amount).stringValue
    }

    private func focusOrder(for account: Account) -> [Field] {
        var arr: [Field] = [.institution]
        if account.type == .loan || account.type == .creditCard {
            arr.append(.apr)
            arr.append(.paymentAmount)
        }
        if account.isManualAsset {
            arr.append(.assetValue)
        }
        return arr
    }

    private func canGoPrevious(for account: Account) -> Bool {
        guard let current = focusedField else { return false }
        let order = focusOrder(for: account)
        guard let idx = order.firstIndex(of: current) else { return false }
        return idx > 0
    }

    private func canGoNext(for account: Account) -> Bool {
        guard let current = focusedField else { return false }
        let order = focusOrder(for: account)
        guard let idx = order.firstIndex(of: current) else { return false }
        return idx < order.count - 1
    }

    private func moveFocus(_ delta: Int, for account: Account) {
        let order = focusOrder(for: account)
        guard !order.isEmpty else { return }
        if let current = focusedField, let idx = order.firstIndex(of: current) {
            let nextIdx = max(0, min(order.count - 1, idx + delta))
            focusedField = order[nextIdx]
        } else {
            focusedField = order.first
        }
    }

    private func commitAndDismissKeyboard() {
        // Commit any pending edits and dismiss the keyboard
        if let account {
            formatAPRDraft(for: account)
            formatPaymentDraft(for: account)
        }
        try? modelContext.save()
        focusedField = nil
        #if canImport(UIKit)
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        keyWindow?.endEditing(true)
        #endif
    }

    private func earliestTransactionDate(for account: Account) -> Date? {
        return cachedEarliestTransactionDate
    }

    private func defaultStartingBalanceDate(for account: Account) -> Date? {
        guard let earliest = cachedEarliestTransactionDate else { return nil }
        if isMissingStartingBalance(for: account) {
            return Calendar.current.date(byAdding: .day, value: -1, to: earliest)
        } else {
            return earliest
        }
    }

    private func isMissingStartingBalance(for account: Account) -> Bool {
        guard let earliest = cachedEarliestTransactionDate else { return false }
        let hasSnapshot = account.balanceSnapshots.contains { $0.asOfDate <= earliest }
        let hasAdjustment = account.transactions.contains { $0.kind == .adjustment && $0.datePosted <= earliest }
        return !(hasSnapshot || hasAdjustment)
    }

    private func sortedSnapshots(for account: Account) -> [BalanceSnapshot] {
        account.balanceSnapshots.sorted { $0.asOfDate > $1.asOfDate }
    }

    private func adjustments(for account: Account) -> [Transaction] {
        account.transactions.filter { $0.kind == .adjustment }.sorted { $0.datePosted > $1.datePosted }
    }

    private func lastBalanceSnapshot(for account: Account) -> BalanceSnapshot? {
        sortedSnapshots(for: account).first
    }

    private func recomputeAccountDerivedData(accountID id: UUID) async {
        let t0 = Date()
        let container = modelContext.container
        let bg = ModelContext(container)
        bg.autosaveEnabled = false

        AMLogging.log("recompute start id=\(id)", component: "AccountDetailView")

        do {
            let snapshotData = try fetchLatestBalanceSnapshotData(in: bg, accountID: id)
            let baseBalance = snapshotData.balance
            let sinceDate = snapshotData.asOfDate
            // Earliest transaction date using an ascending sort and fetch limit 1
            let earliest = try await fetchEarliestTransactionDate(in: bg, accountID: id)
            AMLogging.log("recompute earliest=\(String(describing: earliest)) id=\(id)", component: "AccountDetailView")
            await MainActor.run {
                self.cachedEarliestTransactionDate = earliest
            }

            // Derived balance: if we have a base snapshot, sum deltas since; otherwise sum all
            let delta = try await sumTransactions(in: bg, accountID: id, since: sinceDate)
            AMLogging.log("recompute delta=\(delta) base=\(String(describing: baseBalance)) id=\(id)", component: "AccountDetailView")
            await MainActor.run {
                if let base = baseBalance {
                    self.cachedDerivedBalance = base + delta
                } else {
                    self.cachedDerivedBalance = (delta == 0 ? nil : delta)
                }
            }

            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            AMLogging.log("recompute done id=\(id) in \(ms)ms", component: "AccountDetailView")
        } catch {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            AMLogging.error("recompute failed id=\(id) after \(ms)ms: \(error.localizedDescription)", component: "AccountDetailView")
            await MainActor.run {
                self.cachedDerivedBalance = nil
            }
            // Leave earliest as-is to avoid UI flicker
        }
    }

    private func fetchEarliestTransactionDate(in context: ModelContext, accountID: UUID) async throws -> Date? {
        let predicate = #Predicate<Transaction> { tx in tx.accountID == accountID }
        var descriptor = FetchDescriptor<Transaction>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\Transaction.datePosted, order: .forward)]
        descriptor.fetchLimit = 1
        let results = try context.fetch(descriptor)
        return results.first?.datePosted
    }

    private func fetchLatestBalanceSnapshotData(in context: ModelContext, accountID: UUID) throws -> (balance: Decimal?, asOfDate: Date?) {
        let predicate = #Predicate<BalanceSnapshot> { snapshot in snapshot.accountID == accountID }
        var descriptor = FetchDescriptor<BalanceSnapshot>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        descriptor.fetchLimit = 1
        guard let snapshot = try context.fetch(descriptor).first else {
            return (nil, nil)
        }
        return (snapshot.balance, snapshot.asOfDate)
    }

    private func sumTransactions(in context: ModelContext, accountID: UUID, since: Date?) async throws -> Decimal {
        let predicate: Predicate<Transaction>
        let snapshotDateForLog = since
        if let sinceDate = since {
            let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: sinceDate)) ?? sinceDate
            predicate = #Predicate<Transaction> { tx in tx.accountID == accountID && tx.datePosted >= nextDay }
        } else {
            predicate = #Predicate<Transaction> { tx in tx.accountID == accountID }
        }
        let descriptor = FetchDescriptor<Transaction>(predicate: predicate)
        let results = try context.fetch(descriptor)
        if let sinceDate = snapshotDateForLog, !results.isEmpty {
            let preview = results
                .sorted { $0.datePosted < $1.datePosted }
                .prefix(8)
                .map { "\($0.datePosted) \($0.amount) \($0.payee)" }
                .joined(separator: " | ")
            AMLogging.log("AccountDetailView: derived balance counted transactions after snapshot — accountID=\(accountID) snapshotDate=\(sinceDate) count=\(results.count) preview=\(preview)", component: "AccountDetailView")
        }
        return results.reduce(Decimal.zero) { $0 + $1.amount }
    }

    private func format(amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func loadAssetLiabilityLink(assetID: UUID) {
        suppressLinkOnChange = true
        defer { suppressLinkOnChange = false }
        do {
            let pred = #Predicate<AssetLiabilityLink> { link in
                link.assetID == assetID && link.endDate == nil
            }
            let desc = FetchDescriptor<AssetLiabilityLink>(predicate: pred)
            if let link = try modelContext.fetch(desc).first {
                self.activeAssetLink = link
                self.linkedLiabilityID = link.liabilityID
            } else {
                self.activeAssetLink = nil
                self.linkedLiabilityID = nil
            }
        } catch {
            self.activeAssetLink = nil
            self.linkedLiabilityID = nil
        }
    }

    private func updateAssetLiabilityLink(for asset: Account, to newLiabilityID: UUID?) {
        // Fetch any existing active links for this asset

        // No-op if selection hasn't changed
        if (self.activeAssetLink == nil && newLiabilityID == nil) || (self.activeAssetLink?.liabilityID == newLiabilityID) {
            return
        }

        do {
            let assetID = asset.id
            let pred = #Predicate<AssetLiabilityLink> { link in
                link.assetID == assetID && link.endDate == nil
            }
            let desc = FetchDescriptor<AssetLiabilityLink>(predicate: pred)
            let existing = try modelContext.fetch(desc)
            // Remove existing active links if changing or unlinking
            for link in existing {
                modelContext.delete(link)
            }
            if let newID = newLiabilityID, let liab = liabilityAccounts.first(where: { $0.id == newID }) {
                // Create a new link with a reasonable start date (use latest asset snapshot date if available)
                let start = lastBalanceSnapshot(for: asset)?.asOfDate ?? Date()
                let link = AssetLiabilityLink(asset: asset, liability: liab, startDate: start)
                modelContext.insert(link)
                self.activeAssetLink = link
            } else {
                self.activeAssetLink = nil
            }
            try modelContext.save()
            NotificationCenter.default.post(name: .accountsDidChange, object: nil)
        } catch {
            // Ignore errors for now
        }
    }

    private func formatPercent(_ value: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        nf.minimumFractionDigits = 2
        nf.maximumFractionDigits = 2
        return nf.string(from: NSDecimalNumber(decimal: value)) ?? "\(value * 100)%"
    }

    private func isInvalidInstitutionName(_ name: String?) -> Bool {
        guard let raw = name?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return true }
        let lower = raw.lowercased()
        let banned: Set<String> = [
            "statement", "statements", "stmt", "report", "reports", "summary", "summaries",
            "transaction", "transactions", "activity", "history", "export", "exports", "download", "downloads"
        ]
        return banned.contains(lower)
    }

    private func formatAPR(_ apr: Decimal, scale: Int? = nil) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if let s = scale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s } else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
        return nf.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr)"
    }

    private func parseCurrencyInput(_ s: String) -> Decimal? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Keep only digits, minus sign, and common separators
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
        guard let decimal = Decimal(string: cleaned) else { return nil }
        let scale: Int = {
            if let dot = cleaned.firstIndex(of: ".") {
                return cleaned.distance(from: cleaned.index(after: dot), to: cleaned.endIndex)
            }
            return 0
        }()
        var fraction = decimal
        if fraction > 1 {
            fraction /= 100
        }
        return (fraction, scale)
    }

    private func formatAmountForInput(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func selectAllInFirstResponder(after delay: TimeInterval = 0.05) {
        #if os(iOS)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
        }
        #endif
    }

    private func deleteAccount(_ account: Account) {
        AMLogging.log("Deleting account id=\(account.id) name=\(account.name)", component: "AccountDetailView")
        removeImportMappings(for: account.id)
        modelContext.delete(account)
        do {
            try modelContext.save()
        } catch {
            AMLogging.error("Failed to delete account: \(error.localizedDescription)", component: "AccountDetailView")
        }
        NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
        NotificationCenter.default.post(name: .accountsDidChange, object: nil)
//        dismiss()
    }

    private func removeImportMappings(for accountID: UUID) {
        let descriptor = FetchDescriptor<AccountImportMapping>(predicate: #Predicate { $0.accountID == accountID })
        guard let mappings = try? modelContext.fetch(descriptor), !mappings.isEmpty else { return }
        for mapping in mappings {
            modelContext.delete(mapping)
        }
        AMLogging.log("Removed \(mappings.count) import mapping(s) for deleted account id=\(accountID)", component: "AccountDetailView")
    }
}

#Preview {
    Text("Preview requires model data")
}

struct MergeAccountSheet: View {
    let currentAccountID: UUID
    @Binding var selectedTargetID: UUID?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    // Live query of accounts to avoid stashing detached instances
    @Query private var accounts: [Account]

    init(currentAccountID: UUID, selectedTargetID: Binding<UUID?>) {
        self.currentAccountID = currentAccountID
        self._selectedTargetID = selectedTargetID
        _accounts = Query(sort: [SortDescriptor(\Account.name, order: .forward)])
    }

    var body: some View {
        Form {
            Section("Merge into") {
                Picker("Target Account", selection: $selectedTargetID) {
                    ForEach(accounts.filter { $0.id != currentAccountID }, id: \.id) { acct in
                        Text("\(acct.name) — \(acct.type.rawValue.capitalized)").tag(Optional(acct.id))
                    }
                }
            }
            Section {
                Button("Merge", role: .destructive) {
                    guard let targetID = selectedTargetID,
                          let source = accounts.first(where: { $0.id == currentAccountID }),
                          let target = accounts.first(where: { $0.id == targetID }) else { return }
                    do {
                        try mergeAccounts(source: source, target: target)
                        dismiss()
                    } catch {
                        // For MVP, ignore errors
                        dismiss()
                    }
                }
                .disabled(mergeDisabled)
            }
        }
        .navigationTitle("Merge Accounts")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        }
    }

    private var mergeDisabled: Bool {
        guard let id = selectedTargetID else { return true }
        return id == currentAccountID
    }

    private func mergeAccounts(source: Account, target: Account) throws {
        // Move transactions
        for tx in source.transactions {
            tx.account = target
        }
        // Move holdings
        for hs in source.holdingSnapshots {
            hs.account = target
        }
        // Move balances
        for bs in source.balanceSnapshots {
            bs.account = target
        }
        // If source has a more specific institution name, prefer it
        if let srcInst = source.institutionName, !(srcInst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            target.institutionName = srcInst
        }
        // Delete the now-empty source account
        modelContext.delete(source)
        try modelContext.save()
        NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
    }
}
