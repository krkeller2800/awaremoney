//
//  DebtDashboardView.swift
//  awaremoney
//
//  Created by Assistant on 2/1/26
//

import SwiftUI
import SwiftData

#if canImport(UIKit)
import UIKit

private extension UIResponder {
    private static weak var am_current: UIResponder?

    static func am_currentFirstResponder() -> UIResponder? {
        am_current = nil
        UIApplication.shared.sendAction(#selector(am_captureFirstResponder), to: nil, from: nil, for: nil)
        return am_current
    }

    @objc func am_captureFirstResponder() {
        UIResponder.am_current = self
    }
}

private extension UIWindowScene {
    var keyWindow: UIWindow? {
        if let key = self.windows.first(where: { $0.isKeyWindow }) { return key }
        return self.windows.first
    }
}
#endif

struct DebtDashboardView: View {
    @State private var showDebtSummary = false

    private enum DebtMode: String, CaseIterable { case debt, planning }
    @Environment(\.modelContext) private var modelContext
    @State private var liabilities: [Account] = []
    @State private var selection: Account.ID? = nil
    @State private var mode: DebtMode = .debt
    
    @State private var showPlanSheet = false
    private enum PlanSheetMode: String, CaseIterable { case incomeBills, summary }
    @State private var planSheetMode: PlanSheetMode = .incomeBills
    
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Group {
            if isPad {
                iPadBody
            } else {
                iPhoneBody
            }
        }
    }

    private var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    @ViewBuilder
    private var iPadBody: some View {
        NavigationSplitView {
            iPadSidebar
        } detail: {
            iPadDetail
        }
        //.safeAreaInset(edge: .top) { TrialBanner() }
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 340)
        .task { await load() }
        .sheet(isPresented: $showPlanSheet) {
            planSheetView
                .presentationSizing(.page)
        }
        .sheet(isPresented: $showDebtSummary) {
            DebtSummaryView()
                .presentationSizing(.page)
        }
    }

    @ViewBuilder
    private var iPadDetail: some View {
        if let sel = selection, let acct = liabilities.first(where: { $0.id == sel }) {
            HStack {
                Spacer(minLength: 0)
                Group {
                    if mode == .planning {
                        DebtPayoffView(viewModel: DebtPayoffViewModel(account: acct, context: modelContext))
                            .id(acct.id)
                    } else {
                        DebtDetailView(account: acct)
                    }
                }
                .frame(maxWidth: 700)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .safeAreaPadding()
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(acct.name)
                        .font(.headline).bold()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        } else if liabilities.isEmpty {
            ContentUnavailableView("No debts yet", systemImage: "creditcard")
        } else {
            ContentUnavailableView("Select a destination", systemImage: "square.grid.2x2")
        }
    }

    @ViewBuilder
    private var iPadSidebar: some View {
        List(selection: $selection) {
            // Institutions list (selecting an account clears any static detail)
            Section(mode == .debt ? "Institutions" : "Accounts") {
                if liabilities.isEmpty {
                    ContentUnavailableView("No debts yet", systemImage: "creditcard")
                } else {
                    ForEach(liabilities, id: \.id) { acct in
                        HStack(alignment: .firstTextBaseline) {
                            debtRowContent(for: acct)
                        }
                        .tag(acct.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selection = acct.id
                        }
                    }
                }
            }
        }
        .refreshable { await load() }
        .navigationTitle(mode == .debt ? "Debt" : "Planning")
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                Picker("Mode", selection: $mode) {
                    Text("Debt").tag(DebtMode.debt)
                    Text("Planning").tag(DebtMode.planning)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            }
            .padding(.vertical, 8)
            .background(.bar)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                PlanToolbarButton("Summary",fixedWidth: 100) {
                    showDebtSummary = true
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                PlanToolbarButton("Bills") { planSheetMode = .incomeBills; showPlanSheet = true }
            }
        }
    }

    @ViewBuilder
    private func debtRowContent(for acct: Account) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(acct.name)
                    .font(.headline)
                Text(acct.type == .loan ? "Loan" : "Credit Card")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(currentBalance(for: acct))
                    .font(.headline)
                    .foregroundStyle(.red)
                if let payoff = payoffDate(for: acct) {
                    if mode == .debt {
                        if let tp = typicalPayment(for: acct) {
                            Text("Typical Payment: \(tp)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Payoff: \(payoff, style: .date)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var iPhoneBody: some View {
        NavigationStack {
            List {
                // Institutions list
                Section(mode == .debt ? "Institutions" : "Accounts") {
                    if liabilities.isEmpty {
                        ContentUnavailableView("No debts yet", systemImage: "creditcard")
                    } else {
                        ForEach(liabilities, id: \.id) { acct in
                            NavigationLink {
                                if mode == .planning {
                                    DebtPayoffView(viewModel: DebtPayoffViewModel(account: acct, context: modelContext))
                                } else {
                                    DebtDetailView(account: acct)
                                }
                            } label: {
                                debtRowContent(for: acct)
                            }
                        }
                    }
                }
            }
            .refreshable { await load() }
            .navigationTitle(mode == .debt ? "Debt" : "Planning")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                VStack(spacing: 8) {
                    Picker("Mode", selection: $mode) {
                        Text("Debt").tag(DebtMode.debt)
                        Text("Planning").tag(DebtMode.planning)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }
                .padding(.vertical, 8)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PlanToolbarButton("Summary",fixedWidth: 100) { showDebtSummary = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PlanToolbarButton("Income/Bills",fixedWidth: 120) { planSheetMode = .incomeBills; showPlanSheet = true }
                }
            }
        }
        .task { await load() }
        .sheet(isPresented: $showPlanSheet) {
            planSheetView
                .presentationSizing(.page)
        }
        .fullScreenCover(isPresented: $showDebtSummary, onDismiss: { resetPhoneOrientationToDefault() }) {
            DebtSummaryLandscapeHost()
                .environment(\.modelContext, modelContext)
                .environmentObject(settings)
        }
    }
    
    @MainActor
    private func resetPhoneOrientationToDefault() {
        #if canImport(UIKit)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }
        if #available(iOS 16.0, *) {
            if let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .allButUpsideDown))
            }

            // Trigger an update of supported interface orientations on the active controller
            if let windowScene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first,
               let window = windowScene.keyWindow,
               let rootVC = window.rootViewController {
                rootVC.setNeedsUpdateOfSupportedInterfaceOrientations()
            } else if let rootVC = UIApplication.shared.connectedScenes
                        .compactMap({ $0 as? UIWindowScene })
                        .flatMap({ $0.windows })
                        .first(where: { $0.isKeyWindow })?
                        .rootViewController {
                rootVC.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
        #endif
    }

    @ViewBuilder
    private var planSheetView: some View {
        NavigationStack {
            Group {
                switch planSheetMode {
                case .incomeBills:
                    IncomeAndBillsView(showsLocalModePicker: false)
                        .environment(\.modelContext, modelContext)
                case .summary:
                    IncomeBillsSummarySheetContent()
                        .environment(\.modelContext, modelContext)
                        .environmentObject(settings)
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Income & Bills")
                        .font(isPad ? .largeTitle : .headline)  
                        .lineLimit(1)
                }
                ToolbarItem(placement: .topBarLeading) {
                    PlanToolbarButton("Done", fixedWidth: 65) { showPlanSheet = false }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top) {
                VStack(spacing: 8) {
                    Picker("Plan Mode", selection: $planSheetMode) {
                        Text("Income & Bills").tag(PlanSheetMode.incomeBills)
                        Text("Summary").tag(PlanSheetMode.summary)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
    }

    private struct IncomeBillsSummarySheetContent: View {
        @Environment(\.modelContext) private var modelContext
        @Query(sort: \CashFlowItem.createdAt, order: .reverse) private var items: [CashFlowItem]
        @EnvironmentObject private var settings: SettingsStore

        var body: some View {
            List {
                IncomeBillsSummarySections(items: items)
            }
            .listStyle(.insetGrouped)
        }
    }

    @Sendable private func load() async {
        do {
            let all = try modelContext.fetch(FetchDescriptor<Account>())
            await MainActor.run {
                self.liabilities = all.filter { $0.type == .loan || $0.type == .creditCard }
                if self.selection == nil { self.selection = self.liabilities.first?.id }
            }
        } catch {
            await MainActor.run { self.liabilities = [] }
        }
    }

    private func latestBalance(_ account: Account) -> Decimal {
        let id = account.id
        let pred = #Predicate<BalanceSnapshot> { $0.account?.id == id }
        var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
        desc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        desc.fetchLimit = 1
        let snap = try? modelContext.fetch(desc).first
        return snap?.balance ?? 0
    }

    private func absDecimal(_ d: Decimal) -> Decimal { d < 0 ? -d : d }

    private func latestSnapshotDate(_ account: Account) -> Date? {
        let id = account.id
        let pred = #Predicate<BalanceSnapshot> { $0.account?.id == id }
        var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
        desc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        desc.fetchLimit = 1
        return try? modelContext.fetch(desc).first?.asOfDate
    }

    private func currentBalance(for account: Account) -> String {
        let bal = latestBalance(account)
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf.string(from: NSDecimalNumber(decimal: bal)) ?? "\(bal)"
    }

    private func typicalPayment(for account: Account) -> String? {
        guard let amount = account.loanTerms?.paymentAmount else { return nil }
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf.string(from: NSDecimalNumber(decimal: amount))
    }

    private func payoffDate(for account: Account) -> Date? {
        return PayoffCalculator.payoffDate(for: account)
    }
}

struct DebtDetailView: View {
    let account: Account
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore

    @State private var aprInput: String = ""
    @State private var aprScale: Int? = nil
    @State private var paymentInput: String = ""
    @State private var paymentDay: Int? = nil
    @State private var ccMode: CreditCardPaymentMode = .minimum
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case apr, payment }
    @State private var showProjection: Bool = false

    var body: some View {
        Form {
            Section("Overview") {
                LabeledContent("Institution", value: account.institutionName ?? "")
                LabeledContent("Type", value: account.type.rawValue.capitalized)
            }
            Section("Payment Plan") {
                if account.type == .creditCard {
                    Picker("Mode", selection: $ccMode) {
                        ForEach(CreditCardPaymentMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue.capitalized).tag(mode)
                        }
                    }
                }

                // Payment amount (shown for loans and credit cards)
                if account.type == .loan || account.type == .creditCard {
                    LabeledContent("Typical Payment") {
                        TextField("0.00", text: $paymentInput)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($focusedField, equals: .payment)
                    }
                }

                // Due day of month (optional)
                Picker("Due Day", selection: Binding<Int?>(
                    get: { paymentDay },
                    set: { paymentDay = $0 }
                )) {
                    Text("None").tag(nil as Int?)
                    ForEach(1...31, id: \.self) { d in
                        Text("\(d)").tag(Optional(d))
                    }
                }
            }
            Section("Interest Rate") {
                LabeledContent("APR") {
                    TextField("0.00", text: $aprInput)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focusedField, equals: .apr)
                }
                Text("Enter as a percent (e.g., 19.99 for 19.99%).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Projection") {
                Button("Project Payoff") { showProjection = true }
                    .disabled(absDecimal(latestBalance(account)) <= 0)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button(action: { moveFocus(-1) }) {
                    Image(systemName: "chevron.left")
                }
                .disabled(focusedField == nil || focusedField == focusOrder.first)

                Button(action: { moveFocus(1) }) {
                    Image(systemName: "chevron.right")
                }
                .disabled(focusedField == nil || focusedField == focusOrder.last)

                Spacer()

                Button(action: { commitAndDismissKeyboard() }) {
                    Image(systemName: "checkmark")
                }
            }
        }
        .navigationTitle(account.name)
        .task(id: account.id) {
            initializeState()
            // Reset transient UI state when switching accounts
            focusedField = nil
            showProjection = false
        }
        .onAppear { initializeState() }
        .onChange(of: aprInput) { saveTerms() }
        .onChange(of: paymentInput) { saveTerms() }
        .onChange(of: paymentDay) { saveTerms() }
        .onChange(of: ccMode) { saveTerms() }
        .onChange(of: focusedField) { _, newField in
            selectAllOnFocus(newField)
        }
        .sheet(isPresented: $showProjection) {
            NavigationStack {
                DebtPayoffView(viewModel: DebtPayoffViewModel(account: account, context: modelContext))
                    .id(account.id)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showProjection = false }
                        }
                    }
            }
        }
    }

    private var focusOrder: [Field] { [.payment, .apr] }

    private func moveFocus(_ delta: Int) {
        let order = focusOrder
        guard !order.isEmpty else { return }
        guard let current = focusedField, let idx = order.firstIndex(of: current) else {
            focusedField = order.first
            return
        }
        let nextIdx = max(0, min(order.count - 1, idx + delta))
        focusedField = order[nextIdx]
    }

    private func commitAndDismissKeyboard() {
        saveTerms()
        // Reformat displayed inputs to match currency/percent styles based on saved values
        if let apr = account.loanTerms?.apr {
            self.aprInput = formatPercentForInput(apr, scale: account.loanTerms?.aprScale)
        }
        if let pay = account.loanTerms?.paymentAmount {
            self.paymentInput = formatAmountForInput(pay)
        }
        focusedField = nil
    }

    @MainActor private func selectAllOnFocus(_ field: Field?) {
        guard field == .payment || field == .apr else { return }
        #if canImport(UIKit)
        // Delay to ensure the text field has become first responder before selecting
        DispatchQueue.main.async {
            if let tf = UIResponder.am_currentFirstResponder() as? UITextField {
                tf.selectAll(nil)
            }
        }
        #endif
    }

    private func latestBalance(_ account: Account) -> Decimal {
        let id = account.id
        let pred = #Predicate<BalanceSnapshot> { $0.account?.id == id }
        var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
        desc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        desc.fetchLimit = 1
        let snap = try? modelContext.fetch(desc).first
        return snap?.balance ?? 0
    }

    private func latestSnapshotDate(_ account: Account) -> Date? {
        let id = account.id
        let pred = #Predicate<BalanceSnapshot> { $0.account?.id == id }
        var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
        desc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        desc.fetchLimit = 1
        return try? modelContext.fetch(desc).first?.asOfDate
    }

    private func formatAmount(_ amount: Decimal?) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        guard let amount else { return "—" }
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func formatAPR(_ apr: Decimal, scale: Int? = nil) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if let s = scale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s }
        else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
        return nf.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr)"
    }

    private func initializeState() {
        // Seed UI from current model values
        if let terms = account.loanTerms {
            if let apr = terms.apr {
                self.aprInput = formatPercentForInput(apr, scale: terms.aprScale)
                self.aprScale = terms.aprScale
            } else {
                self.aprInput = ""
                self.aprScale = nil
            }
            if let p = terms.paymentAmount { self.paymentInput = formatAmountForInput(p) } else { self.paymentInput = "" }
            self.paymentDay = terms.paymentDayOfMonth
        } else {
            self.aprInput = ""
            self.aprScale = nil
            self.paymentInput = ""
            self.paymentDay = nil
        }
        if account.type == .creditCard { self.ccMode = account.creditCardPaymentMode ?? .minimum }
    }

    private func saveTerms() {
        var terms = account.loanTerms ?? LoanTerms()

        // APR parsing: interpret input as percent (e.g., 19.99 -> 0.1999)
        if let (fraction, scale) = parsePercentInput(aprInput) {
            terms.apr = fraction
            terms.aprScale = scale
        } else {
            terms.apr = nil
            terms.aprScale = nil
        }

        // Payment amount parsing (currency/decimal)
        if let pay = parseCurrencyInput(paymentInput) {
            terms.paymentAmount = pay
        } else {
            terms.paymentAmount = nil
        }
        terms.paymentDayOfMonth = paymentDay

        // Persist terms and mode
        account.loanTerms = terms
        if account.type == .creditCard { account.creditCardPaymentMode = ccMode }

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .accountsDidChange, object: nil)
        } catch {
            // Silently ignore for now; UI can surface errors later
        }
    }

    private func absDecimal(_ d: Decimal) -> Decimal { d < 0 ? -d : d }

    private func parseCurrencyInput(_ s: String) -> Decimal? {
        let cleaned = s.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: cleaned)
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
        // APR is stored as a fraction (e.g., 0.1999). Use percent style so it renders like 19.99%.
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if let s = scale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s } else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
        return nf.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr * 100)%"
    }
}

#Preview {
    Text("Preview requires model data")
}

