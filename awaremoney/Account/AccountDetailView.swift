import SwiftUI
import SwiftData
import UIKit

struct AccountDetailView: View {
    let accountID: UUID
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

    @Query(filter: #Predicate<Account> { $0.typeRaw == "loan" }, sort: [SortDescriptor(\Account.name, order: .forward)]) private var liabilityAccounts: [Account]

    @State private var linkedLiabilityID: UUID? = nil
    @State private var activeAssetLink: AssetLiabilityLink? = nil
    @State private var suppressLinkOnChange = false

    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case institution
        case paymentAmount
    }

    private var isEditing: Bool { focusedField != nil }

    init(accountID: UUID) {
        self.accountID = accountID
        _fetchedAccounts = Query(filter: #Predicate<Account> { $0.id == accountID }, sort: [])
    }

    private var account: Account? { fetchedAccounts.first }

    var body: some View {
        Group {
            if let account {
                Group {
                    if isRegularWidth {
                        VStack(spacing: 12) {
                            glanceableHeader(for: account)
                                .padding(.horizontal, 24)

                            HStack(spacing: 0) {
                                detailsList(for: account)
                                    .containerRelativeFrame(.horizontal, count: 2, spacing: 0)
                                    .frame(maxHeight: .infinity)

                                ZStack {
                                    NavigationStack {
                                        AccountTransactionsListView(accountID: account.id)
                                            .id(account.id)
                                    }
                                    .environment(\.modelContext, modelContext)
                                }
                                .containerRelativeFrame(.horizontal, count: 2, spacing: 0)
                                .frame(maxHeight: .infinity)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .overlay(alignment: .center) {
                                Rectangle()
                                    .fill(.separator)
                                    .frame(width: 1)
                                    .frame(maxHeight: .infinity)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        detailsList(for: account)
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
                .alert("Delete this property?", isPresented: $showDeleteAlert) {
                    Button("Delete", role: .destructive) {
                        deleteAccount(account)
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("This will permanently delete the property and all associated balances and transactions.")
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if isRegularWidth {
                            EmptyView()
                        } else {
                            NavigationLink {
                                AccountTransactionsListView(accountID: account.id)
                            } label: {
                                Label("Transactions", systemImage: "list.bullet")
                            }
                            .simultaneousGesture(TapGesture().onEnded {
                                AMLogging.log("Transactions button tapped for accountID=\(account.id)", component: "AccountDetailView")
                            })
                        }
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        if account.type == .property {
                            Button(role: .destructive) {
                                showDeleteAlert = true
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel("Delete Property")
                        }
                    }
                }
            } else {
                ContentUnavailableView("Account no longer exists", systemImage: "exclamationmark.triangle")
                    .task { dismiss() }
            }
        }
        // If the account disappears (e.g., after batch deletion), dismiss this screen
        .onChange(of: fetchedAccounts.count) { _, newCount in
            AMLogging.log("AccountDetailView fetchedAccounts count changed to \(newCount) for accountID=\(accountID)", component: "AccountDetailView")
            if newCount == 0 { dismiss() }
        }
        .task(id: account?.id) {
            AMLogging.log("AccountDetailView task(id:) fired for accountID=\(accountID)", component: "AccountDetailView")
            if let account = account {
                await recomputeAccountDerivedData(for: account)
                await MainActor.run { loadAssetLiabilityLink(for: account) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in
            AMLogging.log("AccountDetailView received transactionsDidChange for accountID=\(accountID)", component: "AccountDetailView")
            Task { if let account = account { await recomputeAccountDerivedData(for: account) } }
        }
        .onAppear {
            AMLogging.log("AccountDetailView appear accountID=\(accountID)", component: "AccountDetailView")
        }
        .onChange(of: focusedField) { _, newValue in
            guard let field = newValue else { return }
            if field == .institution || field == .paymentAmount {
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
                LabeledContent(account.type == .property ? "Description" : "Institution") {
                    HStack(spacing: 6) {
                        TextField(account.type == .property ? "Description (optional)" : "Institution name", text: Binding<String>(
                            get: { account.institutionName ?? "" },
                            set: { newVal in
                                let trimmed = newVal.trimmingCharacters(in: .whitespacesAndNewlines)
                                account.institutionName = trimmed
                                // Keep account name in sync with institution when edited here (non-property accounts only)
                                if account.type != .property, account.name != trimmed {
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
                        .accessibilityLabel("Edit \(account.type == .property ? "description" : "institution")")
                    }
                }
                if account.type != .property && isInvalidInstitutionName(account.institutionName) {
                    Text("Required. We couldn't derive this from your import.")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                LabeledContent("Type", value: account.type.rawValue.capitalized)
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

            if account.type == .property {
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
                        if newVal == nil, let active = activeAssetLink, !liabilityAccounts.contains(where: { $0.id == active.liability.id }) {
                            return
                        }
                        updateAssetLiabilityLink(for: account, to: newVal)
                    }

                    // Show Equity and LTV when a liability is linked and we have balances
                    if let liabID = linkedLiabilityID,
                       let liab = liabilityAccounts.first(where: { $0.id == liabID }) {
                        let assetVal: Decimal = lastBalanceSnapshot(for: account)?.balance ?? 0
                        let debtMag: Decimal = {
                            let bal = lastBalanceSnapshot(for: liab)?.balance ?? 0
                            return bal < 0 ? -bal : bal
                        }()
                        if assetVal != 0 {
                            LabeledContent("Equity") {
                                Text(format(amount: assetVal - debtMag))
                            }
                            LabeledContent("LTV") {
                                Text(formatPercent(debtMag / assetVal))
                            }
                        }
                    }

                    Text("Link a loan to track equity and LTV.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if account.type == .loan || account.type == .creditCard {
                Section(header: GroupedSectionHeader("Payment Plan")) {
                    // Typical payment editor
                    LabeledContent("Typical Payment") {
                        HStack(spacing: 6) {
                            TextField("0.00", text: Binding<String>(
                                get: {
                                    if let amt = account.loanTerms?.paymentAmount {
                                        return formatAmountForInput(amt)
                                    } else { return "" }
                                },
                                set: { newVal in
                                    var terms = account.loanTerms ?? LoanTerms()
                                    if let dec = parseCurrencyInput(newVal) {
                                        terms.paymentAmount = dec
                                    } else {
                                        terms.paymentAmount = nil
                                    }
                                    account.loanTerms = terms
                                    try? modelContext.save()
                                    NotificationCenter.default.post(name: .accountsDidChange, object: nil)
                                }
                            ))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .focused($focusedField, equals: .paymentAmount)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                            Button {
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
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Transactional Balance")
                        Spacer()
                        if let derived = cachedDerivedBalance {
                            Text(format(amount: derived))
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
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .frame(maxWidth: isRegularWidth ? .infinity : 760, alignment: .center)
        .padding(.horizontal, isRegularWidth ? 0 : 16)
        .frame(maxWidth: .infinity, alignment: .center)
        .overlay(alignment: .topTrailing) {
            if !isRegularWidth {
                NavigationLink {
                    AccountTransactionsListView(accountID: account.id)
                } label: {
                    Label("Transactions", systemImage: "list.bullet")
                }
                .padding(.top, 0)
                .padding(.trailing, 50)
            }
        }
    }

    
    private func glanceableHeader(for account: Account) -> some View {
        // Only show on iPad/regular width
        let transactionalBalance: String = {
            if let derived = cachedDerivedBalance {
                return format(amount: derived)
            } else {
                return "Unavailable"
            }
        }()

        let last = lastBalanceSnapshot(for: account)
        let recordedBalance: String = {
            if let last = last { return format(amount: last.balance) } else { return "None" }
        }()
        let recordedDate: String? = {
            if let last = last {
                let df = DateFormatter()
                df.dateStyle = .medium
                df.timeStyle = .none
                return df.string(from: last.asOfDate)
            }
            return nil
        }()

        // Change since recorded balance (if both values exist)
        let changeSinceRecorded: (text: String, color: Color)? = {
            guard let derived = cachedDerivedBalance, let lastBal = last?.balance else { return nil }
            let delta = derived - lastBal
            let prefix = delta >= 0 ? "+" : ""
            return (prefix + format(amount: delta), delta >= 0 ? .green : .red)
        }()

        // Linked liability (for properties)
        let linkedLiability: Account? = {
            guard account.type == .property, let liabID = linkedLiabilityID else { return nil }
            return liabilityAccounts.first(where: { $0.id == liabID })
        }()

        // Compute Equity and LTV when applicable (properties with a linked loan)
        func computeEquityAndLTV() -> (String?, String?) {
            let assetVal: Decimal = lastBalanceSnapshot(for: account)?.balance ?? 0
            guard account.type == .property, let liab = linkedLiability else {
                return (nil, nil)
            }
            let liabilityBalance = lastBalanceSnapshot(for: liab)?.balance ?? 0
            let debtMag: Decimal = liabilityBalance < 0 ? -liabilityBalance : liabilityBalance
            guard assetVal != 0 else { return (nil, nil) }
            let equityText = format(amount: assetVal - debtMag)
            let ltvText = formatPercent(debtMag / assetVal)
            return (equityText, ltvText)
        }

        let (equityText, ltvText) = computeEquityAndLTV()

        // Loan/Credit Card helpers
        let isLoanLike = account.type == .loan || account.type == .creditCard
        let aprText: String? = {
            guard let apr = last?.interestRateAPR else { return nil }
            return formatAPR(apr, scale: last?.interestRateScale)
        }()
        let typicalPaymentText: String? = {
            guard isLoanLike, let amt = account.loanTerms?.paymentAmount else { return nil }
            return format(amount: amt)
        }()
        func nextDueDate(day: Int) -> Date? {
            let cal = Calendar.current
            let now = Date()
            let today = cal.startOfDay(for: now)
            var comps = cal.dateComponents([.year, .month], from: today)
            guard let monthStart = cal.date(from: comps) else { return nil }
            let range = cal.range(of: .day, in: .month, for: monthStart) ?? 1..<29
            let clampedDay = min(max(1, day), range.count)
            comps.day = clampedDay
            guard let dueThisMonth = cal.date(from: comps) else { return nil }
            if today <= dueThisMonth { return dueThisMonth }
            // Next month
            var nextComps = cal.dateComponents([.year, .month], from: cal.date(byAdding: .month, value: 1, to: monthStart)!)
            let nextMonthStart = cal.date(from: nextComps)!
            let nextRange = cal.range(of: .day, in: .month, for: nextMonthStart) ?? 1..<29
            nextComps.day = min(max(1, day), nextRange.count)
            return cal.date(from: nextComps)
        }
        func daysUntil(_ date: Date) -> Int {
            let cal = Calendar.current
            let start = cal.startOfDay(for: Date())
            let end = cal.startOfDay(for: date)
            return cal.dateComponents([.day], from: start, to: end).day ?? 0
        }
        let nextDueParts: (date: String, rel: String)? = {
            guard isLoanLike, let day = account.loanTerms?.paymentDayOfMonth, let next = nextDueDate(day: day) else { return nil }
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            let days = daysUntil(next)
            let rel: String
            if days > 0 { rel = "in \(days)d" }
            else if days < 0 { rel = "\(abs(days))d ago" }
            else { rel = "today" }
            return (df.string(from: next), rel)
        }()

        // Brokerage: valuation age
        let valuationAgeText: String? = {
            guard account.type == .brokerage, let asOf = last?.asOfDate else { return nil }
            let cal = Calendar.current
            let days = cal.dateComponents([.day], from: cal.startOfDay(for: asOf), to: cal.startOfDay(for: Date())).day ?? 0
            return "\(days)d"
        }()

        // Property: linked loan details
        let linkedLoanName: String? = linkedLiability?.name
        let linkedLoanBalance: String? = {
            guard let liab = linkedLiability, let bal = lastBalanceSnapshot(for: liab)?.balance else { return nil }
            let mag = bal < 0 ? -bal : bal
            return format(amount: mag)
        }()

        // A helper to render a single-line caption, single-line value, and a single-line sublabel (or a space placeholder)
        func cell(title: String, value: String, sub: String?) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(value)
                    .font(.title3).bold().monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(sub ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }

        return VStack(alignment: .center, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    // Tx Balance
                    cell(title: "Transaction Balance", value: transactionalBalance, sub: nil)

                    // Recorded (with date below or space)
                    cell(title: "Recorded Balance", value: recordedBalance, sub: recordedDate)

                    // Δ Since Rec.
                    if let change = changeSinceRecorded {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Δ Since Rec.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(change.text)
                                .font(.title3).bold().monospacedDigit()
                                .foregroundStyle(change.color)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Text(" ")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }

                    // Equity & LTV
                    if let eq = equityText { cell(title: "Equity", value: eq, sub: nil) }
                    if let ltv = ltvText { cell(title: "LTV", value: ltv, sub: nil) }

                    // Property-specific linked loan info
                    if account.type == .property {
                        if let name = linkedLoanName { cell(title: "Loan", value: name, sub: nil) }
                        if let bal = linkedLoanBalance { cell(title: "Loan Bal", value: bal, sub: nil) }
                    }

                    // Loan/Credit Card items
                    if isLoanLike {
                        if let apr = aprText { cell(title: "APR", value: apr, sub: nil) }
                        if let pay = typicalPaymentText { cell(title: "Payment", value: pay, sub: nil) }
                        if let parts = nextDueParts { cell(title: "Next Due", value: parts.date, sub: parts.rel) }
                    }

                    // Brokerage items
                    if let age = valuationAgeText { cell(title: "Val Age", value: age, sub: nil) }
                }
            }
            .frame(maxWidth: 700, alignment: .center)
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.separator, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var isIPadLandscape: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad && UIScreen.main.bounds.width > UIScreen.main.bounds.height
        #else
        return false
        #endif
    }

    private func focusOrder(for account: Account) -> [Field] {
        var arr: [Field] = [.institution]
        if account.type == .loan || account.type == .creditCard {
            arr.append(.paymentAmount)
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

    private func recomputeAccountDerivedData(for account: Account) async {
        let t0 = Date()
        let container = modelContext.container
        let bg = ModelContext(container)
        bg.autosaveEnabled = false

        // Capture ID and last snapshot data on the main actor
        let id = await MainActor.run { account.id }
        AMLogging.log("recompute start id=\(id)", component: "AccountDetailView")
        let snapshotData: (Decimal?, Date?) = await MainActor.run { () -> (Decimal?, Date?) in
            let last = self.lastBalanceSnapshot(for: account)
            return (last?.balance, last?.asOfDate)
        }
        let baseBalance = snapshotData.0
        let sinceDate = snapshotData.1

        do {
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
        let predicate = #Predicate<Transaction> { tx in tx.account?.id == accountID }
        var descriptor = FetchDescriptor<Transaction>(predicate: predicate)
        descriptor.sortBy = [SortDescriptor(\Transaction.datePosted, order: .forward)]
        descriptor.fetchLimit = 1
        let results = try context.fetch(descriptor)
        return results.first?.datePosted
    }

    private func sumTransactions(in context: ModelContext, accountID: UUID, since: Date?) async throws -> Decimal {
        let predicate: Predicate<Transaction>
        if let sinceDate = since {
            predicate = #Predicate<Transaction> { tx in tx.account?.id == accountID && tx.datePosted > sinceDate }
        } else {
            predicate = #Predicate<Transaction> { tx in tx.account?.id == accountID }
        }
        let descriptor = FetchDescriptor<Transaction>(predicate: predicate)
        let results = try context.fetch(descriptor)
        return results.reduce(Decimal.zero) { $0 + $1.amount }
    }

    private func format(amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func loadAssetLiabilityLink(for account: Account) {
        suppressLinkOnChange = true
        defer { suppressLinkOnChange = false }
        do {
            let assetID = account.id
            let pred = #Predicate<AssetLiabilityLink> { link in
                link.asset.id == assetID && link.endDate == nil
            }
            let desc = FetchDescriptor<AssetLiabilityLink>(predicate: pred)
            if let link = try modelContext.fetch(desc).first {
                self.activeAssetLink = link
                self.linkedLiabilityID = link.liability.id
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
        if (self.activeAssetLink == nil && newLiabilityID == nil) || (self.activeAssetLink?.liability.id == newLiabilityID) {
            return
        }

        do {
            let assetID = asset.id
            let pred = #Predicate<AssetLiabilityLink> { link in
                link.asset.id == assetID && link.endDate == nil
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
        modelContext.delete(account)
        do {
            try modelContext.save()
        } catch {
            AMLogging.error("Failed to delete account: \(error.localizedDescription)", component: "AccountDetailView")
        }
        NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
        NotificationCenter.default.post(name: .accountsDidChange, object: nil)
        dismiss()
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

