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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var liabilities: [Account] = []
    @State private var selection: Account.ID? = nil
    @State private var mode: DebtMode = .debt
    @State private var showDebtChart: Bool = false

    @State private var showPlanSheet = false
    @State private var showStrategySheet = false
    private enum PlanSheetMode: String, CaseIterable { case incomeBills, summary }
    @State private var planSheetMode: PlanSheetMode = .incomeBills
    
    @EnvironmentObject private var settings: SettingsStore
    
    // Plan scaffolding state
    @State private var appliedPlan: DebtPlanResult? = nil
    @State private var planSubtitle: String = ""
    @State private var planError: String? = nil

    @AppStorage("debtPlanStartModeRaw") private var debtPlanStartModeRaw: String = "currentInputs"
    @AppStorage("debtPlanStartDate") private var debtPlanStartDateEpoch: Double = 0
    @AppStorage("useFixedDebtBudget") private var useFixedDebtBudget: Bool = false
    @AppStorage("debtBudgetOverrideAmount") private var debtBudgetOverrideAmount: Double = 0
    
    @AppStorage("baselineBudgetSourceRaw") private var baselineBudgetSourceRaw: String = "recurringNet"
    @AppStorage("includeNonMonthlyIncomeSpreads") private var includeNonMonthlyIncomeSpreads: Bool = true
    @AppStorage("oneTimeIncomeDefaultSpreadMonths") private var oneTimeIncomeDefaultSpreadMonths: Int = 12

    private func planPayment(for id: UUID) -> Decimal? {
        appliedPlan?.months.first?.payments[id]
    }
    private func planPayoffDate(for id: UUID) -> Date? {
        appliedPlan?.payoffDates[id]
    }

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

    @MainActor
    private func runReserveUpdate() {
        let service = ReserveUpdateService(context: modelContext, settings: settings)
        service.updateReserves()
    }

    @MainActor
    private func recomputeAppliedPlan() {
        let provider = PayoffPlanProvider(context: modelContext, settings: settings)
        let startDate: Date = {
            if debtPlanStartModeRaw == "projectedAtDate", debtPlanStartDateEpoch > 0 {
                return Date(timeIntervalSince1970: debtPlanStartDateEpoch)
            } else {
                return Date()
            }
        }()
        let normalizedStart = normalizeToMonth(startDate)

        do {
            let plan = try provider.computePlan(startDate: normalizedStart)
            self.appliedPlan = plan
            self.planError = nil
        } catch DebtPlanError.infeasibleBudget {
            self.appliedPlan = nil
            self.planError = "Budget is too low to cover minimum payments."
        } catch {
            self.appliedPlan = nil
            self.planError = nil
        }

        // Build a consistent subtitle reflecting persisted start and settings
        let strategyDisplay: String = {
            switch settings.defaultPayoffStrategyRaw {
            case "snowball": return "Snowball"
            case "avalanche": return "Avalanche"
            default: return "Minimums"
            }
        }()
        let budgetText: String = {
            let startMonth = normalizedStart
            if let avail = PlanBudgetDisplay.availableBudget(
                for: startMonth,
                modelContext: modelContext,
                baselineBudgetSourceRaw: baselineBudgetSourceRaw,
                useFixedDebtBudget: useFixedDebtBudget,
                debtBudgetOverrideAmount: debtBudgetOverrideAmount,
                includeNonMonthlyIncomeSpreads: includeNonMonthlyIncomeSpreads,
                oneTimeIncomeDefaultSpreadMonths: oneTimeIncomeDefaultSpreadMonths
            ), avail > 0 {
                return " • Adj Budget: \(formatAmount(avail))"
            }
            return ""
        }()
        if debtPlanStartModeRaw == "projectedAtDate", debtPlanStartDateEpoch > 0 {
            let d = Date(timeIntervalSince1970: debtPlanStartDateEpoch)
            self.planSubtitle = "Start on \(d.formatted(date: .abbreviated, time: .omitted)) • \(strategyDisplay)\(budgetText)"
        } else {
            self.planSubtitle = "Start now • \(strategyDisplay)\(budgetText)"
        }
    }

    private func normalizeToMonth(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? date
    }

    private func formatAmount(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
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
        .task {
            // Trigger reserve update when dashboard becomes visible; guarded internally per month
            await MainActor.run { runReserveUpdate() }
            await MainActor.run { recomputeAppliedPlan() }
        }
        .sheet(isPresented: $showPlanSheet) {
            planSheetView
                .applySheetSizing()
        }
        .sheet(isPresented: $showDebtSummary) {
            DebtSummaryView()
                .applySheetSizing()
        }
        .sheet(isPresented: $showStrategySheet) {
            DebtPlanSheetView()
                .environment(\.modelContext, modelContext)
                .environmentObject(settings)
                .applySheetSizing()
        }
        .onChange(of: showPlanSheet) { _, newValue in
            if newValue == false { Task { await MainActor.run { recomputeAppliedPlan() } } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { _ in
            Task { await MainActor.run { recomputeAppliedPlan() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .planSettingsDidChange)) { _ in
            Task { await MainActor.run { recomputeAppliedPlan() } }
        }
    }

    @ViewBuilder
    private var iPadDetail: some View {
        if let sel = selection, let acct = liabilities.first(where: { $0.id == sel }) {
            VStack(spacing: 12) {
                if !planSubtitle.isEmpty || planError != nil {
                    PlanBanner(subtitle: planSubtitle, errorText: planError, onEdit: { showStrategySheet = true })
                        .padding(.horizontal, 16)
                }
                HStack {
                    Spacer(minLength: 0)
                    DebtDetailView(account: acct)
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
            }
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
            Section("Accounts") {
                if liabilities.isEmpty {
                    ContentUnavailableView("No debts yet", systemImage: "creditcard")
                } else {
                    ForEach(liabilities, id: \.id) { acct in
                        HStack(alignment: .firstTextBaseline) {
                            debtRowContent(for: acct, modeOverride: .planning)
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
        .navigationTitle("Planning")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button {
                        showDebtSummary = true
                    } label: {
                        Label("Debt Summary", systemImage: "list.bullet.rectangle" )
                    }
                    Button {
                        showDebtChart = true
                    } label: {
                        Label("View Debt Chart", systemImage: "chart.line.uptrend.xyaxis")
                    }
                    .accessibilityIdentifier("showDebtChartButton")
                } label: {
                    PlanMenuLabel(title: "Overview")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                PlanToolbarButton("Bills") { planSheetMode = .incomeBills; showPlanSheet = true }
            }
        }
        .sheet(isPresented: $showDebtChart) {
            DebtProjectionChartView(items: allCashFlowItems())
                .environmentObject(settings)
                .applySheetSizing()
        }
    }

    @ViewBuilder
    private func debtRowContent(for acct: Account, modeOverride: DebtMode? = nil) -> some View {
        let effectiveMode = modeOverride ?? mode
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
                    if effectiveMode == .debt {
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
                    if verticalSizeClass == .compact {
                        Picker("Mode", selection: $mode) {
                            Text("Debt").tag(DebtMode.debt)
                            Text("Planning").tag(DebtMode.planning)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical, 8)
                .background(.bar)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            showDebtSummary = true
                        } label: {
                            Label("Debt Summary", systemImage: "list.bullet.rectangle" )
                        }
                        Button {
                            showDebtChart = true
                        } label: {
                            Label("View Debt Chart", systemImage: "chart.line.uptrend.xyaxis")
                        }
                        .accessibilityIdentifier("showDebtChartButton")
                    } label: {
                        PlanMenuLabel(title: "Overview")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PlanToolbarButton("Income/Bills",fixedWidth: 120) { planSheetMode = .incomeBills; showPlanSheet = true }
                }
            }
        }
        .task { await load() }
        .task {
            await MainActor.run { runReserveUpdate() }
            await MainActor.run { recomputeAppliedPlan() }
        }
        .sheet(isPresented: $showPlanSheet) {
            planSheetView
                .applySheetSizing()
        }
        .fullScreenCover(isPresented: $showDebtSummary, onDismiss: { resetPhoneOrientationToDefault() }) {
            DebtSummaryView()
                .environment(\.modelContext, modelContext)
                .environmentObject(settings)
        }
        .fullScreenCover(isPresented: $showDebtChart, onDismiss: { resetPhoneOrientationToDefault() }) {
//            LandscapeOnly {
                DebtProjectionChartView(items: allCashFlowItems())
                    .environment(\.modelContext, modelContext)
                    .environmentObject(settings)
                    .ignoresSafeArea()
//            }
        }
        .sheet(isPresented: $showStrategySheet) {
            DebtPlanSheetView()
                .environment(\.modelContext, modelContext)
                .environmentObject(settings)
                .applySheetSizing()
        }
        .onChange(of: showPlanSheet) { _, newValue in
            if newValue == false { Task { await MainActor.run { recomputeAppliedPlan() } } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { _ in
            Task { await MainActor.run { recomputeAppliedPlan() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .planSettingsDidChange)) { _ in
            Task { await MainActor.run { recomputeAppliedPlan() } }
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
                if isPad {
                    switch planSheetMode {
                    case .incomeBills:
                        IncomeAndBillsView()
                            .environment(\.modelContext, modelContext)
                    case .summary:
                        IncomeBillsSummarySheetContent()
                            .environment(\.modelContext, modelContext)
                            .environmentObject(settings)
                    }
                } else {
                    // iPhone: Always use the local three-segment picker inside IncomeAndBillsView
                    IncomeAndBillsView()
                        .environment(\.modelContext, modelContext)
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
                if isPad {
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
                } else {
                    EmptyView()
                }
            }
        }
    }
    private func allCashFlowItems() -> [CashFlowItem] {
        do {
            return try modelContext.fetch(FetchDescriptor<CashFlowItem>())
        } catch {
            return []
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var aprInput: String = ""
    @State private var aprScale: Int? = nil
    @State private var paymentInput: String = ""
    @State private var paymentDay: Int? = nil
    @State private var ccMode: CreditCardPaymentMode = .minimum
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case apr, payment }
    @State private var showProjection: Bool = false
    @State private var showDueDayPickerSheet = false
    @State private var showCCModePickerSheet = false

    // Plan-aware state for this account detail
    @State private var plannedPayment: Decimal? = nil
    @State private var plannedPayoffDate: Date? = nil
    @State private var planComputeError: String? = nil
    @State private var planSubtitle: String = ""
    @State private var showStrategySheet: Bool = false

    @AppStorage("debtPlanStartModeRaw") private var debtPlanStartModeRaw: String = "currentInputs"
    @AppStorage("debtPlanStartDate") private var debtPlanStartDateEpoch: Double = 0
    @AppStorage("useFixedDebtBudget") private var useFixedDebtBudget: Bool = false
    @AppStorage("debtBudgetOverrideAmount") private var debtBudgetOverrideAmount: Double = 0
    
    @AppStorage("baselineBudgetSourceRaw") private var baselineBudgetSourceRaw: String = "recurringNet"
    @AppStorage("includeNonMonthlyIncomeSpreads") private var includeNonMonthlyIncomeSpreads: Bool = true
    @AppStorage("oneTimeIncomeDefaultSpreadMonths") private var oneTimeIncomeDefaultSpreadMonths: Int = 12

    private var isEditing: Bool { focusedField != nil }
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    private var focusOrder: [Field] { [.payment, .apr] }

    private var canGoPrevious: Bool {
        guard let focusedField, let idx = focusOrder.firstIndex(of: focusedField) else { return false }
        return idx > 0
    }

    private var canGoNext: Bool {
        guard let focusedField, let idx = focusOrder.firstIndex(of: focusedField) else { return false }
        return idx < focusOrder.count - 1
    }

    var body: some View {
        Group {
            if isRegularWidth {
                VStack(spacing: 12) {
                    glanceableHeader(for: account)
                        .padding(.horizontal, 24)

                    HStack(spacing: 0) {
                        formContent
                            .containerRelativeFrame(.horizontal, count: 2, spacing: 0)
                            .frame(maxHeight: .infinity)

                        NavigationStack {
                            DebtPayoffView(viewModel: DebtPayoffViewModel(account: account, context: modelContext))
                                .id(account.id)
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
                formContent
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle(account.name)
        .task(id: account.id) {
            initializeState()
            focusedField = nil
            showProjection = false
            recomputePlanForDetail()
        }
        .onAppear { initializeState(); recomputePlanForDetail() }
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
        .sheet(isPresented: $showStrategySheet) {
            DebtPlanSheetView()
                .environment(\.modelContext, modelContext)
                .environmentObject(settings)
        }
        .sheet(isPresented: $showCCModePickerSheet) {
            NavigationStack {
                Form {
                    Picker("Mode", selection: $ccMode) {
                        ForEach(CreditCardPaymentMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue.capitalized).tag(mode)
                        }
                    }
                }
                .navigationTitle("Payment Mode")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showCCModePickerSheet = false }
                    }
                }
            }
        }
        .sheet(isPresented: $showDueDayPickerSheet) {
            NavigationStack {
                Form {
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
                .navigationTitle("Due Day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showDueDayPickerSheet = false }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if isEditing {
                    EditingAccessoryBar(
                        canGoPrevious: canGoPrevious,
                        canGoNext: canGoNext,
                        onPrevious: { moveFocus(-1) },
                        onNext: { moveFocus(1) },
                        onDone: { commitAndDismissKeyboard() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    EmptyView().frame(height: 0)
                }
            }
            .animation(.snappy, value: isEditing)
        }
        .onReceive(NotificationCenter.default.publisher(for: .planSettingsDidChange)) { _ in
            Task { @MainActor in recomputePlanForDetail() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { _ in
            Task { @MainActor in recomputePlanForDetail() }
        }
    }

    @MainActor
    private func recomputePlanForDetail() {
        // Determine start date
        let startDate: Date = {
            if debtPlanStartModeRaw == "projectedAtDate", debtPlanStartDateEpoch > 0 {
                return Date(timeIntervalSince1970: debtPlanStartDateEpoch)
            } else {
                return Date()
            }
        }()
        let normalizedStart = normalizeToMonth(startDate)

        // Build debts from all liabilities (loans + credit cards) using base or projected balances for the start month
        let allAccounts = (try? modelContext.fetch(FetchDescriptor<Account>())) ?? []
        let liabilities = allAccounts.filter { $0.type == .loan || $0.type == .creditCard }

        let debts: [DebtInput] = liabilities.compactMap { acct in
            let base = latestBalance(acct)
            let magBase = base < 0 ? -base : base
            let bal: Decimal = (debtPlanStartModeRaw == "projectedAtDate")
                ? absProjectedOrBase(for: acct, planDate: normalizedStart, base: magBase)
                : magBase
            guard bal > 0 else { return nil }
            let minPay = monthlyPayment(for: acct, balance: bal)
            return DebtInput(id: acct.id, name: acct.name, apr: acct.loanTerms?.apr, balance: bal, minPayment: minPay)
        }

        guard !debts.isEmpty else {
            self.plannedPayment = nil
            self.plannedPayoffDate = nil
            self.planComputeError = nil
            return
        }

        do {
            let strategy = currentStrategy()
            let plan: DebtPlanResult

            // Match Summary/Chart: if recurring net or spreads are enabled, use a per‑month schedule; otherwise use fixed monthly
            if includeNonMonthlyIncomeSpreads || baselineBudgetSourceRaw == "recurringNet" {
                let items = (try? modelContext.fetch(FetchDescriptor<CashFlowItem>())) ?? []
                let schedule = IncomeScheduler.budgetByMonth(
                    items: items,
                    start: normalizedStart,
                    months: 60,
                    includeSpreads: includeNonMonthlyIncomeSpreads,
                    oneTimeDefaultSpreadMonths: sanitizedDefaultSpread(oneTimeIncomeDefaultSpreadMonths),
                    baselineSource: baselineSource
                )
                plan = try DebtPayoffEngine.plan(
                    debts: debts,
                    budgetByMonth: schedule,
                    strategy: strategy,
                    startDate: normalizedStart
                )
            } else {
                let fixedBudget: Decimal = {
                    if useFixedDebtBudget, debtBudgetOverrideAmount > 0 {
                        return Decimal(debtBudgetOverrideAmount)
                    } else {
                        // Ensure at least minimums when not using Recurring Net
                        return debts.reduce(0) { $0 + $1.minPayment }
                    }
                }()
                plan = try DebtPayoffEngine.plan(
                    debts: debts,
                    monthlyBudget: fixedBudget,
                    strategy: strategy,
                    startDate: normalizedStart
                )
            }

            // Apply this account’s values to the UI
            self.plannedPayment = plan.months.first?.payments[account.id]
            self.plannedPayoffDate = plan.payoffDates[account.id]
            self.planComputeError = nil
        } catch DebtPlanError.infeasibleBudget(let requiredMin) {
            self.plannedPayment = nil
            self.plannedPayoffDate = nil
            self.planComputeError = "Budget too low to cover minimums (\(formatAmount(requiredMin)))."
        } catch {
            self.plannedPayment = nil
            self.plannedPayoffDate = nil
            self.planComputeError = nil
        }


        // Build plan subtitle for the banner
        let strategyDisplay: String = {
            switch settings.defaultPayoffStrategyRaw {
            case "snowball": return "Snowball"
            case "avalanche": return "Avalanche"
            default: return "Minimums"
            }
        }()
        let budgetText: String = {
            let startMonth = normalizedStart
            if let avail = PlanBudgetDisplay.availableBudget(
                for: startMonth,
                modelContext: modelContext,
                baselineBudgetSourceRaw: baselineBudgetSourceRaw,
                useFixedDebtBudget: useFixedDebtBudget,
                debtBudgetOverrideAmount: debtBudgetOverrideAmount,
                includeNonMonthlyIncomeSpreads: includeNonMonthlyIncomeSpreads,
                oneTimeIncomeDefaultSpreadMonths: oneTimeIncomeDefaultSpreadMonths
            ), avail > 0 {
                return " • Adj Budget: \(formatAmount(avail))"
            }
            return ""
        }()
        if debtPlanStartModeRaw == "projectedAtDate", debtPlanStartDateEpoch > 0 {
            let d = Date(timeIntervalSince1970: debtPlanStartDateEpoch)
            self.planSubtitle = "Start on \(d.formatted(date: .abbreviated, time: .omitted)) • \(strategyDisplay)\(budgetText)"
        } else {
            self.planSubtitle = "Start now • \(strategyDisplay)\(budgetText)"
        }
    }

    private func normalizeToMonth(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? date
    }

    // Strategy mapping from settings
    private func currentStrategy() -> PayoffStrategy {
        switch settings.defaultPayoffStrategyRaw {
        case "snowball":  return .snowball
        case "avalanche": return .avalanche
        default:          return .minimumsOnly
        }
    }

    // Baseline selection for IncomeScheduler
    private var baselineSource: IncomeScheduler.BaselineSource {
        if baselineBudgetSourceRaw == "fixed", useFixedDebtBudget, debtBudgetOverrideAmount > 0 {
            return .fixedAmount(Decimal(debtBudgetOverrideAmount))
        } else {
            return .recurringNet
        }
    }

    // Guardrail for spread picker
    private func sanitizedDefaultSpread(_ v: Int) -> Int { [3, 6, 12].contains(v) ? v : 12 }

    // Fallback monthly payment when a typical payment isn't set (2% of balance)
    private func monthlyPayment(for account: Account, balance: Decimal) -> Decimal {
        if let configured = account.loanTerms?.paymentAmount, configured > 0 { return configured }
        let twoPercent = Decimal(string: "0.02") ?? 0.02
        return (balance * twoPercent).rounded(scale: 2)
    }

    // Projected balance helpers to honor "Start on date"
    private func projectedBalance(for account: Account, on targetDate: Date) throws -> Decimal? {
        let targetMonth = normalizeToMonth(targetDate)
        let result = try PayoffCalculator.project(for: account, asOf: targetMonth)
        let cal = Calendar.current
        let sorted = result.points.sorted { $0.date < $1.date }
        if let exact = sorted.first(where: { cal.isDate($0.date, equalTo: targetMonth, toGranularity: .month) }) {
            return exact.balance
        }
        return sorted.last(where: { $0.date <= targetMonth })?.balance ?? sorted.first?.balance
    }

    private func absProjectedOrBase(for account: Account, planDate: Date, base: Decimal) -> Decimal {
        let magBase = base < 0 ? -base : base
        do {
            if let p = try projectedBalance(for: account, on: planDate) {
                return p < 0 ? -p : p
            }
        } catch { }
        return magBase
    }
    
    private func formatAmount(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private var formContent: some View {
        Form {
            if !isRegularWidth, (!planSubtitle.isEmpty || planComputeError != nil) {
                Section {
                    PlanBanner(subtitle: planSubtitle, errorText: planComputeError, onEdit: { showStrategySheet = true })
                }
            }
            Section("Overview") {
                LabeledContent("Institution", value: account.institutionName ?? "")
                LabeledContent("Type", value: account.type.rawValue.capitalized)
            }
            Section("Payment Plan") {
                if account.type == .creditCard {
                    HStack {
                        Picker("Mode", selection: $ccMode) {
                            ForEach(CreditCardPaymentMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue.capitalized).tag(mode)
                            }
                        }
                        Button(action: { showCCModePickerSheet = true }) {
                            Image(systemName: "pencil")
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 6)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }

                // Payment amount (shown for loans and credit cards)
                if account.type == .loan || account.type == .creditCard {
                    LabeledContent("Typical Payment") {
                        HStack(spacing: 8) {
                            TextField("0.00", text: $paymentInput)
                                .multilineTextAlignment(.trailing)
                                .keyboardType(.decimalPad)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.done)
                                .focused($focusedField, equals: .payment)
                            Button(action: { focusedField = .payment }) {
                                Image(systemName: "pencil")
                                    .imageScale(.small)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                        }
                    }
                }

                // Due day of month (optional)
                HStack {
                    Picker("Due Day", selection: Binding<Int?>(
                        get: { paymentDay },
                        set: { paymentDay = $0 }
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
            }
            Section("Interest Rate") {
                LabeledContent("APR") {
                    HStack(spacing: 8) {
                        TextField("0.00", text: $aprInput)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .focused($focusedField, equals: .apr)
                        Button(action: { focusedField = .apr }) {
                            Image(systemName: "pencil")
                                .imageScale(.small)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }
                Text("Enter as a percent (e.g., 19.99 for 19.99%).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !isRegularWidth, (plannedPayment != nil || plannedPayoffDate != nil) {
                Section("Plan") {
                    if let pp = plannedPayment {
                        LabeledContent("Payment (plan)") {
                            Text(formatAmount(pp))
                        }
                    }
                    if let pd = plannedPayoffDate {
                        LabeledContent("Payoff (plan)") {
                            Text(pd.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                }
            }
            if UIDevice.type == "iPhone" {
                Section("Projection") {
                    Button("Project Payoff") { showProjection = true }
                        .disabled(absDecimal(latestBalance(account)) <= 0)
                }
            }
        }
    }

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
        #if canImport(UIKit)
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
        keyWindow?.endEditing(true)
        #endif
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

    private func glanceableHeader(for account: Account) -> some View {
        // Helper cell
        func cell(title: String, value: String, sub: String? = nil, valueColor: Color? = nil) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(value)
                    .font(.title3).bold().monospacedDigit()
                    .foregroundStyle(valueColor ?? .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(sub ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }

        // Latest recorded balance and date
        let lastDate = latestSnapshotDate(account)
        let recorded = latestBalance(account)
        let recordedText = formatAmount(recorded)
        let recordedDateText: String? = {
            guard let d = lastDate else { return nil }
            let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
            return df.string(from: d)
        }()

        // Transactional balance (recorded + transactions since), or sum of all tx if no snapshot
        let transactionalText: String = {
            if let d = lastDate {
                let delta = account.transactions.filter { $0.datePosted > d }.reduce(Decimal.zero) { $0 + $1.amount }
                return formatAmount(recorded + delta)
            } else {
                let sum = account.transactions.reduce(Decimal.zero) { $0 + $1.amount }
                return sum == 0 ? "Unavailable" : formatAmount(sum)
            }
        }()

        // Change since recorded (when both exist)
        let changeSinceRecorded: (text: String, color: Color)? = {
            guard let d = lastDate else { return nil }
            let delta = account.transactions.filter { $0.datePosted > d }.reduce(Decimal.zero) { $0 + $1.amount }
            let change = delta
            let prefix = change >= 0 ? "+" : ""
            return (prefix + formatAmount(change), change >= 0 ? .green : .red)
        }()

        // APR and Typical Payment
        let aprText: String? = {
            if let apr = account.loanTerms?.apr { return formatAPR(apr, scale: account.loanTerms?.aprScale) }
            return nil
        }()
        let paymentText: String? = {
            if let p = account.loanTerms?.paymentAmount { return formatAmount(p) }
            return nil
        }()

        // Next Due date based on day-of-month
        func nextDueDate(day: Int) -> Date? {
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            var comps = cal.dateComponents([.year, .month], from: today)
            guard let monthStart = cal.date(from: comps) else { return nil }
            let range = cal.range(of: .day, in: .month, for: monthStart) ?? 1..<29
            comps.day = min(max(1, day), range.count)
            guard let dueThisMonth = cal.date(from: comps) else { return nil }
            if today <= dueThisMonth { return dueThisMonth }
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
            let day = account.loanTerms?.paymentDayOfMonth ?? paymentDay
            guard let d = day, let next = nextDueDate(day: d) else { return nil }
            let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
            let days = daysUntil(next)
            let rel: String = days > 0 ? "in \(days)d" : (days < 0 ? "\(abs(days))d ago" : "today")
            return (df.string(from: next), rel)
        }()
        
        let planPayoffText: String? = {
            guard let pod = plannedPayoffDate else { return nil }
            let df = DateFormatter()
            df.dateStyle = .medium
            df.timeStyle = .none
            return df.string(from: pod)
        }()

        return VStack(alignment: .center, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    cell(title: "Transaction Balance", value: transactionalText)
                    cell(title: "Recorded Balance", value: recordedText, sub: recordedDateText)
                    if let change = changeSinceRecorded { cell(title: "Δ Since Rec.", value: change.text, sub: nil, valueColor: change.color) }
                    if let apr = aprText { cell(title: "APR", value: apr) }
                    if let pay = paymentText { cell(title: "Payment", value: pay) }
                    if let pp = plannedPayment { cell(title: "Payment (plan)", value: formatAmount(pp)) }
                    if let due = nextDueParts { cell(title: "Next Due", value: due.date, sub: due.rel) }
                    if let s = planPayoffText { cell(title: "Payoff (plan)", value: s) }
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
}

private struct PlanBanner: View {
    let subtitle: String
    let errorText: String?
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let error = errorText {
                    Text(error)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                }
            }
            Spacer(minLength: 2)
            Button(action: onEdit) {
                Label("Strategy", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        )
    }
}

#Preview {
    Text("Preview requires model data")
}

