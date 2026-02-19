//
//  DebtSummaryView.swift
//  awaremoney
//
//  Created by Assistant on 2/1/26
//

import SwiftUI
import SwiftData
import Foundation
// Uses DebtPayoffEngine

// Lightweight model used for planning
fileprivate struct Debt: Identifiable, Hashable {
    let id: UUID
    let name: String
    let balance: Decimal
    let apr: Decimal?
    let minPayment: Decimal
}

struct DebtSummaryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [Account] = []
    @State private var showPlanSheet = false
    @State private var tempPlanDate: Date = {
        Calendar.current.date(byAdding: .month, value: 12, to: Date()) ?? Date()
    }()
    @State private var appliedPlanDate: Date? = nil
    private enum PlanMode: String, CaseIterable {
        case currentInputs = "Current inputs"
        case projectedAtDate = "Projected at date"
    }
    @State private var tempPlanMode: PlanMode = .currentInputs
    @State private var appliedPlanMode: PlanMode = .currentInputs
    
    @State private var tempStrategy: PayoffStrategy = .minimumsOnly
    @State private var tempMonthlyBudget: String = ""
    @State private var appliedStrategy: PayoffStrategy = .minimumsOnly
    @State private var appliedBudget: Decimal? = nil
    @State private var currentPlan: DebtPlanResult? = nil
    @State private var budgetValidationError: String? = nil
    @State private var showPlanErrorAlert = false
    @State private var planErrorMessage: String? = nil
//    @State private var showIncomeBillsHost = false

//    @FocusState private var focusedField: FocusField?
//    private enum FocusField: Hashable {
//        case monthlyBudget
//    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let compact = isCompactLayout(proxy.size)
                let isPortrait = proxy.size.height > proxy.size.width
//                let toolbarCompact = !((hSizeClass == .regular) && proxy.size.width >= 844)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        if isPortrait && proxy.size.width < 844 {
                            ScrollView(.horizontal, showsIndicators: false) {
                                summaryStack(compact: compact)
                                    .padding(.horizontal, compact ? 6 : 12)
                                    .frame(width: 844, alignment: .topLeading)
                            }
                        } else {
                            summaryStack(compact: compact)
                                .padding(.horizontal, compact ? 6 : 12)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.vertical, 8)
                }
                .navigationTitle("Debt Summary")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text("Debt Summary")
                                .font(.headline)
                            Text(planSubtitleText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .layoutPriority(1)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        PlanToolbarButton("Model") {
                            AMLogging.log("Model tapped; presenting plan sheet", component: "DebtSummaryView")
                            showPlanSheet = true
                        }
//                        label: {
//                            Text("Project")
//                            Image(systemName: "calendar.badge.clock")
//                        }
                        .accessibilityIdentifier("planByDateButton")
                    }
//                    ToolbarItem(placement: .topBarTrailing) {
//                        Button {
//                            showIncomeBillsHost = true
//                        } label: {
//                            Text("Income & Bills")
//                        }
//                        .accessibilityIdentifier("incomeBillsButton")
//                    }
                }
                .task { await load() }
                .sheet(isPresented: $showPlanSheet) {
                    planSheetView()
                }
//                .fullScreenCover(isPresented: $showIncomeBillsHost) {
//                    IncomeBillsSplitHostView()
//                        .environment(\.modelContext, modelContext)
//                }
                .onChange(of: showPlanSheet) { _, newValue in
                    AMLogging.log("showPlanSheet changed: \(newValue)", component: "DebtSummaryView")
                }
            }
        }
    }

    // MARK: - View Builders

    private func payoffOrderString() -> String? {
        guard let plan = currentPlan, !plan.payoffOrder.isEmpty else { return nil }
        let names = plan.payoffOrder.compactMap { id in accounts.first(where: { $0.id == id })?.name }
        let order = names.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "  •  ")
        return "Payoff order: " + order
    }

    private func summaryStack(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            // Removed planHeader(compact: compact) as per instructions
            if let s = payoffOrderString() {
                Text(s)
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
            }
            headerRow(compact: compact)
            Divider()
            ForEach(accounts, id: \.id) { acct in
                row(for: acct, compact: compact)
                Divider()
            }
            totalRow(compact: compact)
        }
    }

    private func planSheetView() -> some View {
        NavigationStack {
            List {
                Section {
                    DatePicker("Target date", selection: $tempPlanDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                        .onChange(of: tempPlanDate) { _, newValue in
                            let isToday = Calendar.current.isDate(newValue, inSameDayAs: Date())
                            tempPlanMode = isToday ? .currentInputs : .projectedAtDate
                        }
                } footer: {
                    Text("Choose a target date to plan against. The selected date will appear above the summary headers.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Mode") {
                    Picker("Summary mode", selection: $tempPlanMode) {
                        Text("Current inputs").tag(PlanMode.currentInputs)
                        Text("Projected at date").tag(PlanMode.projectedAtDate)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: tempPlanMode) { _, newValue in
                        if newValue == .currentInputs {
                            tempPlanDate = Date()
                        }
                    }
                }
                Section {
                    LabeledContent("Monthly budget") {
                        TextField("", text: $tempMonthlyBudget)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
//                            .focused($focusedField, equals: .monthlyBudget)
//                            .submitLabel(.done)
//                            .onSubmit {
//                                commitAndDismissKeyboard()
//                            }
                    }
                } header: {
                    Text("Payoff Plan")
                } footer: {
                    Group {
                        Text("Enter your total monthly budget for debt payments. Leave empty if Minimums Only strategy.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if let error = budgetValidationError {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                }
                
                Section("Income & Bills") {
                    NavigationLink("Manage Income & Bills") {
                        IncomeAndBillsView()
                    }
                    LabeledContent("Monthly Income") {
                        Text(formatAmount(computedMonthlyIncome))
                    }
                    LabeledContent("Monthly Bills") {
                        Text(formatAmount(computedMonthlyBills))
                    }
                    LabeledContent("Net for Debt") {
                        Text(formatAmount(computedMonthlyNet))
                    }
                    Button("Use Net as Budget") {
                        if computedMonthlyNet > 0 {
                            tempMonthlyBudget = formatAmount(computedMonthlyNet)
                        }
                    }
                    .disabled(computedMonthlyNet <= 0)
                }
                
                Section("Strategy") {
                    Picker("Strategy", selection: $tempStrategy) {
                        Text("Minimums Only").tag(PayoffStrategy.minimumsOnly)
                        Text("Snowball").tag(PayoffStrategy.snowball)
                        Text("Avalanche").tag(PayoffStrategy.avalanche)
                    }
                    .pickerStyle(.segmented)
                }
                Section("Current Plan") {
                    if tempPlanMode == .projectedAtDate {
                        HStack(spacing: 4) {
                            Text("Plan as of \(tempPlanDate.formatted(date: .abbreviated, time: .omitted))")
                            Text("• \(tempStrategyDisplay)\(tempBudgetText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Text("Current inputs")
                            Text("• \(tempStrategyDisplay)\(tempBudgetText)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
//            .toolbar {
//                if focusedField == .monthlyBudget {
//                    ToolbarItemGroup(placement: .keyboard) {
//                        Spacer()
//                        Button {
//                            commitAndDismissKeyboard()
//                        } label: {
//                            Image(systemName: "checkmark")
//                        }
//                    }
//                }
//            }
            .navigationTitle("Adjust Date")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    PlanToolbarButton("Set Plan") {
                        AMLogging.log("Set Plan tapped with mode=\(tempPlanMode.rawValue), date=\(String(describing: tempPlanDate)), strategy=\(tempStrategyDisplay), budgetField='\(tempMonthlyBudget)'", component: "DebtSummaryView")
                        budgetValidationError = nil
                        let parsedBudget: Decimal? = {
                            if tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                return nil
                            } else {
                                return parseCurrencyInput(tempMonthlyBudget)
                            }
                        }()
                        AMLogging.log("Parsed budget: \(String(describing: parsedBudget)) for strategy=\(tempStrategyDisplay)", component: "DebtSummaryView")
                        if tempStrategy != .minimumsOnly && parsedBudget == nil {
                            AMLogging.error("Validation failed: Non-minimums strategy with invalid budget", component: "DebtSummaryView")
                            budgetValidationError = "Please enter a valid budget amount or select the Minimums Only strategy."
                            planErrorMessage = "Please enter a valid budget amount or select the Minimums Only strategy."
                            showPlanErrorAlert = true
                            return
                        }
                        appliedPlanMode = tempPlanMode
                        appliedPlanDate = (tempPlanMode == .projectedAtDate) ? tempPlanDate : nil
                        appliedStrategy = tempStrategy
                        appliedBudget = parsedBudget
                        AMLogging.log("Applied plan selections: mode=\(appliedPlanMode.rawValue), date=\(String(describing: appliedPlanDate)), strategy=\(appliedStrategyDisplay), budget=\(String(describing: appliedBudget))", component: "DebtSummaryView")
                        
                        let filteredAccounts = accounts.filter { acct in
                            let baseBal = absDecimal(latestBalance(acct))
                            let bal: Decimal = {
                                if let plan = appliedPlanDate, appliedPlanMode == .projectedAtDate {
                                    return absProjectedOrBase(for: acct, planDate: plan, base: baseBal)
                                } else {
                                    return baseBal
                                }
                            }()
                            return bal > 0
                        }
                        AMLogging.log("Filtered accounts count: \(filteredAccounts.count)", component: "DebtSummaryView")
                        
                        let debts: [Debt] = filteredAccounts.map { acct in
                            let baseBal = absDecimal(latestBalance(acct))
                            let bal: Decimal = {
                                if let plan = appliedPlanDate, appliedPlanMode == .projectedAtDate {
                                    return absProjectedOrBase(for: acct, planDate: plan, base: baseBal)
                                } else {
                                    return baseBal
                                }
                            }()
                            let minPayment = monthlyPayment(for: acct, balance: bal)
                            return Debt(
                                id: acct.id,
                                name: acct.name,
                                balance: bal,
                                apr: acct.loanTerms?.apr,
                                minPayment: minPayment
                            )
                        }
                        AMLogging.log("Prepared debts count: \(debts.count)", component: "DebtSummaryView")

                        let budgetToUse: Decimal
                        if appliedStrategy == .minimumsOnly {
                            budgetToUse = debts.reduce(0) { $0 + $1.minPayment }
                        } else {
                            budgetToUse = appliedBudget ?? 0
                        }
                        AMLogging.log("Planning with budget: \(budgetToUse) and strategy=\(appliedStrategyDisplay)", component: "DebtSummaryView")

                        AMLogging.log("Invoking DebtPayoffEngine.plan ...", component: "DebtSummaryView")
                        let debtInputs: [DebtInput] = debts.map { d in
                            DebtInput(
                                id: d.id,
                                name: d.name,
                                apr: d.apr,
                                balance: d.balance,
                                minPayment: d.minPayment
                            )
                        }
                        let startDateForPlan = normalizeToMonth(
                            appliedPlanMode == .projectedAtDate ? (appliedPlanDate ?? Date()) : Date()
                        )
                        do {
                            let planResult = try DebtPayoffEngine.plan(
                                debts: debtInputs,
                                monthlyBudget: budgetToUse,
                                strategy: appliedStrategy,
                                startDate: startDateForPlan
                            )
                            currentPlan = planResult
                            AMLogging.log("Plan computed successfully; closing plan sheet", component: "DebtSummaryView")
                            showPlanSheet = false
                        } catch DebtPlanError.infeasibleBudget {
                            AMLogging.error("Infeasible budget error from planner", component: "DebtSummaryView")
                            budgetValidationError = "The budget is too low to cover minimum payments. Please increase your budget or choose Minimums Only strategy."
                            planErrorMessage = "The budget is too low to cover minimum payments. Please increase your budget or choose Minimums Only strategy."
                            showPlanErrorAlert = true
                        } catch {
                            AMLogging.error("Unexpected error during planning: \(error.localizedDescription)", component: "DebtSummaryView")
                            budgetValidationError = "An unexpected error occurred."
                            planErrorMessage = "An unexpected error occurred."
                            showPlanErrorAlert = true
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    PlanToolbarButton("Cancel",fixedWidth: 70) {
                        AMLogging.log("Cancel tapped; resetting selections and dismissing sheet", component: "DebtSummaryView")
                        appliedPlanDate = nil
                        appliedPlanMode = .currentInputs
                        appliedStrategy = .minimumsOnly
                        appliedBudget = nil
                        tempPlanDate = Date()
                        tempPlanMode = .currentInputs
                        tempStrategy = .minimumsOnly
                        tempMonthlyBudget = ""
                        budgetValidationError = nil
                        currentPlan = nil
                        showPlanSheet = false
                        showPlanErrorAlert = false
                        planErrorMessage = nil
                    }
                }
            }
            .alert("Can't set plan", isPresented: $showPlanErrorAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(planErrorMessage ?? "")
            }
        }
    }

    // MARK: - Keyboard handling

//    private var focusOrder: [FocusField] { [.monthlyBudget] }
//
//    private func focusPrevious() {
//        guard !focusOrder.isEmpty else { return }
//        if let current = focusedField, let idx = focusOrder.firstIndex(of: current) {
//            let newIdx = (idx - 1 + focusOrder.count) % focusOrder.count
//            focusedField = focusOrder[newIdx]
//        } else {
//            focusedField = focusOrder.last
//        }
//    }
//
//    private func focusNext() {
//        guard !focusOrder.isEmpty else { return }
//        if let current = focusedField, let idx = focusOrder.firstIndex(of: current) {
//            let newIdx = (idx + 1) % focusOrder.count
//            focusedField = focusOrder[newIdx]
//        } else {
//            focusedField = focusOrder.first
//        }
//    }
//
//    private func commitAndDismissKeyboard() {
//        switch focusedField {
//        case .monthlyBudget:
//            let trimmed = tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines)
//            if let d = parseCurrencyInput(trimmed) {
//                tempMonthlyBudget = formatAmount(d)
//            }
//        case .none:
//            break
//        }
//        focusedField = nil
//    }

    // MARK: - Rows

    private func planHeader(compact: Bool) -> some View {
        HStack {
            Spacer()
            if appliedPlanMode == .projectedAtDate, let date = appliedPlanDate {
                HStack(spacing: 4) {
                    Text("Plan as of \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                    Text("• \(appliedStrategyDisplay)\(appliedBudgetText)")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    Text("Current inputs")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                    Text("• \(appliedStrategyDisplay)\(appliedBudgetText)")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    private var appliedStrategyDisplay: String {
        switch appliedStrategy {
        case .minimumsOnly: return "Minimums"
        case .snowball: return "Snowball"
        case .avalanche: return "Avalanche"
        }
    }
    private var appliedBudgetText: String {
        guard let b = appliedBudget, appliedStrategy != .minimumsOnly else { return "" }
        return " • Budget: \(formatAmount(b))"
    }
    
    private var planSubtitleText: String {
        if appliedPlanMode == .projectedAtDate, let date = appliedPlanDate {
            return "Plan as of \(date.formatted(date: .abbreviated, time: .omitted)) • \(appliedStrategyDisplay)\(appliedBudgetText)"
        } else {
            return "Current inputs • \(appliedStrategyDisplay)\(appliedBudgetText)"
        }
    }

    private var tempStrategyDisplay: String {
        switch tempStrategy {
        case .minimumsOnly: return "Minimums"
        case .snowball: return "Snowball"
        case .avalanche: return "Avalanche"
        }
    }

    private var tempBudgetText: String {
        guard tempStrategy != .minimumsOnly else { return "" }
        let trimmed = tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let d = parseCurrencyInput(trimmed) {
            return " • Budget: \(formatAmount(d))"
        } else {
            return " • Budget: —"
        }
    }

    private func headerRow(compact: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 2 : 12) {
            Text("Account")
                .frame(width: compact ? 100 : 150, alignment: .leading)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("APR")
                .frame(width: compact ? 60 : 80, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("Balance")
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("Payment/mo")
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("Interest/mo")
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("After Payment")
                .frame(width: compact ? 110 : 130, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("Payoff")
                .frame(width: compact ? 110 : 120, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private func row(for account: Account, compact: Bool) -> some View {
        let baseBal = absDecimal(latestBalance(account))
        let usedBal: Decimal = {
            if let plan = appliedPlanDate, appliedPlanMode == .projectedAtDate {
                return absProjectedOrBase(for: account, planDate: plan, base: baseBal)
            } else {
                return baseBal
            }
        }()
        let apr = account.loanTerms?.apr
        let planMonth = currentPlan?.months.first
        let payment = planMonth?.payments[account.id] ?? monthlyPayment(for: account, balance: usedBal)
        let step: (interest: Decimal, afterPaymentBalance: Decimal) = {
            if let m = planMonth, let i = m.interest[account.id], let after = m.balances[account.id] {
                return (i, after)
            } else {
                return monthStep(for: account, balance: usedBal, payment: payment)
            }
        }()
        let payoff: Date? = {
            if let plan = currentPlan, let monthDate = plan.payoffDates[account.id] {
                // Adjust plan month date to the account's actual due day within that month
                let dueDay = account.loanTerms?.paymentDayOfMonth
                    ?? Calendar.current.component(.day, from: latestSnapshotDate(account) ?? monthDate)
                return dateInSameMonth(monthDate, withDay: dueDay)
            }
            if let plan = appliedPlanDate, appliedPlanMode == .projectedAtDate {
                return payoffDate(startingBalance: usedBal, startFrom: plan, for: account)
            } else {
                return payoffDate(for: account)
            }
        }()

        return HStack(alignment: .firstTextBaseline, spacing: compact ? 2 : 12) {
            VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                Text(account.name)
                    .font(compact ? .subheadline : .headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .truncationMode(.tail)
                Text(account.type == .loan ? "Loan" : "Credit Card")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: compact ? 100 : 150, alignment: .leading)

            Text(formatAPR(apr, scale: account.loanTerms?.aprScale, compact: compact))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 60 : 80, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(formatAmount(usedBal))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .foregroundStyle(.red)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(formatAmount(payment))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(formatAmount(step.interest))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(formatAmount(step.afterPaymentBalance))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 110 : 130, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Group {
                if let payoff = payoff {
                    Text(payoff.formatted(date: .abbreviated, time: .omitted))
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }
            .font(compact ? .footnote : .body)
            .frame(width: compact ? 110 : 120, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
    }

    private func totalRow(compact: Bool) -> some View {
        let totals = totalsForAccounts(accounts)
        return HStack(alignment: .firstTextBaseline, spacing: compact ? 2 : 12) {
            Text("Total")
                .font(compact ? .subheadline : .headline)
                .frame(width: compact ? 100 : 150, alignment: .leading)
            Text("")
                .frame(width: compact ? 60 : 80)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(formatAmount(totals.balance))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .foregroundStyle(.red)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(formatAmount(totals.payment))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(formatAmount(totals.interest))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 100 : 110, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(formatAmount(totals.afterPayment))
                .font(compact ? .footnote : .body)
                .frame(width: compact ? 110 : 130, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("")
                .frame(width: compact ? 110 : 120)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    // MARK: - Data loading

    @Sendable private func load() async {
        do {
            let all = try modelContext.fetch(FetchDescriptor<Account>())
            await MainActor.run {
                self.accounts = all.filter { $0.type == .loan || $0.type == .creditCard }
            }
        } catch {
            await MainActor.run { self.accounts = [] }
        }
    }

    // MARK: - Calculations

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

    private func payoffDate(for account: Account) -> Date? {
        let startingBalance = absDecimal(latestBalance(account))
        guard startingBalance > 0 else { return nil }
        let apr = account.loanTerms?.apr
        let payment = account.loanTerms?.paymentAmount ?? monthlyPayment(for: account, balance: startingBalance)

        if let apr = apr, apr > 0 {
            // Statement-anchored monthly simulation
            let sDay = Calendar.current.component(.day, from: latestSnapshotDate(account) ?? Date())
            var bal = startingBalance
            var stmt = nextStatementDate(after: statementDate(onOrBefore: latestSnapshotDate(account) ?? Date(), day: sDay), day: sDay)
            for _ in 0..<600 {
                bal -= payment
                if bal <= 0 { return stmt }
                bal += bal * (apr / 12)
                stmt = nextStatementDate(after: stmt, day: sDay)
            }
            return nil
        } else {
            // Fallback to engine projection
            do {
                let kind: DebtKind = (account.type == .loan) ? .loan : .creditCard(account.creditCardPaymentMode ?? .minimum)
                let points = try DebtProjectionEngine.project(kind: kind, startingBalance: startingBalance, apr: apr, payment: payment)
                if let idx = points.firstIndex(where: { $0.balance == 0 }) {
                    let zeroDate = points[idx].date
                    if let anchor = latestSnapshotDate(account) {
                        let sDay = Calendar.current.component(.day, from: anchor)
                        return statementDate(onOrBefore: zeroDate, day: sDay)
                    } else {
                        return zeroDate
                    }
                }
                return nil
            } catch { return nil }
        }
    }

    private func monthlyPayment(for account: Account, balance: Decimal) -> Decimal {
        // Use user's typical payment if provided; otherwise estimate at 2% of balance
        if let configured = account.loanTerms?.paymentAmount, configured > 0 {
            return configured
        }
        let twoPercent = Decimal(string: "0.02") ?? 0.02
        return (balance * twoPercent).rounded(2)
    }

    private func monthStep(for account: Account, balance: Decimal) -> (interest: Decimal, afterPaymentBalance: Decimal) {
        let apr = account.loanTerms?.apr ?? 0
        let payment = monthlyPayment(for: account, balance: balance)
        let effectivePayment = min(payment, balance)
        let interestBase = balance - effectivePayment
        let interest = (apr * interestBase / 12).rounded(2)
        let after = (interestBase + interest).rounded(2)
        return (interest, after)
    }
    
    private func monthStep(for account: Account, balance: Decimal, payment: Decimal) -> (interest: Decimal, afterPaymentBalance: Decimal) {
        let apr = account.loanTerms?.apr ?? 0
        let effectivePayment = min(payment, balance)
        let interestBase = balance - effectivePayment
        let interest = (apr * interestBase / 12).rounded(2)
        let after = (interestBase + interest).rounded(2)
        return (interest, after)
    }

    private func isCompactLayout(_ size: CGSize) -> Bool {
        return size.width < 1000
    }

    // MARK: - Formatting and helpers

    private func formatAmount(_ amount: Decimal?) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        guard let amount = amount else { return "—" }
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func formatAPR(_ apr: Decimal?, scale: Int? = nil, compact: Bool = false) -> String {
        guard let apr else { return "—" }
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if compact {
            nf.minimumFractionDigits = 0
            nf.maximumFractionDigits = 2
        } else if let s = scale {
            nf.minimumFractionDigits = s
            nf.maximumFractionDigits = s
        } else {
            nf.minimumFractionDigits = 3
            nf.maximumFractionDigits = 4
        }
        return nf.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr)"
    }

    private func statementDate(onOrBefore date: Date, day: Int) -> Date {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: date))!
        let range = cal.range(of: .day, in: .month, for: monthStart)!
        let clampedDay = min(max(1, day), range.count)
        var comps = cal.dateComponents([.year, .month], from: monthStart)
        comps.day = clampedDay
        let candidate = cal.date(from: comps)!
        if candidate <= date { return candidate }
        let prevMonth = cal.date(byAdding: DateComponents(month: -1), to: monthStart)!
        let prevRange = cal.range(of: .day, in: .month, for: prevMonth)!
        let prevClamped = min(max(1, day), prevRange.count)
        var prevComps = cal.dateComponents([.year, .month], from: prevMonth)
        prevComps.day = prevClamped
        return cal.date(from: prevComps)!
    }

    private func nextStatementDate(after date: Date, day: Int) -> Date {
        let cal = Calendar.current
        let nextMonth = cal.date(byAdding: DateComponents(month: 1), to: date)!
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: nextMonth))!
        let range = cal.range(of: .day, in: .month, for: monthStart)!
        let clampedDay = min(max(1, day), range.count)
        var comps = cal.dateComponents([.year, .month], from: monthStart)
        comps.day = clampedDay
        return cal.date(from: comps)!
    }
    
    private func dateInSameMonth(_ date: Date, withDay targetDay: Int) -> Date {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: date))!
        let range = cal.range(of: .day, in: .month, for: monthStart)!
        let clampedDay = min(max(1, targetDay), range.count)
        var comps = cal.dateComponents([.year, .month], from: monthStart)
        comps.day = clampedDay
        return cal.date(from: comps) ?? date
    }

    private func normalizeToMonth(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? date
    }

    private func projectionPoint(_ points: [DebtProjectionPoint], closestTo date: Date) -> DebtProjectionPoint? {
        let cal = Calendar.current
        let sorted = points.sorted { $0.date < $1.date }
        if let exact = sorted.first(where: { cal.isDate($0.date, equalTo: date, toGranularity: .month) }) {
            return exact
        }
        return sorted.last(where: { $0.date <= date }) ?? sorted.first
    }

    private func projectedBalance(for account: Account, on targetDate: Date) throws -> Decimal? {
        let startingBalance = absDecimal(latestBalance(account))
        guard startingBalance > 0 else { return 0 }
        let apr = account.loanTerms?.apr
        let payment = account.loanTerms?.paymentAmount ?? monthlyPayment(for: account, balance: startingBalance)
        let kind: DebtKind = (account.type == .loan) ? .loan : .creditCard(account.creditCardPaymentMode ?? .minimum)
        let startDate = normalizeToMonth(latestSnapshotDate(account) ?? Date())
        let points = try DebtProjectionEngine.project(
            kind: kind,
            startingBalance: startingBalance,
            apr: apr,
            payment: payment,
            startDate: startDate,
            maxMonths: 600
        )
        let targetMonth = normalizeToMonth(targetDate)
        return projectionPoint(points, closestTo: targetMonth)?.balance
    }

    private func payoffDate(startingBalance: Decimal, startFrom: Date, for account: Account) -> Date? {
        let apr = account.loanTerms?.apr
        let payment = account.loanTerms?.paymentAmount ?? monthlyPayment(for: account, balance: startingBalance)
        do {
            let kind: DebtKind = (account.type == .loan) ? .loan : .creditCard(account.creditCardPaymentMode ?? .minimum)
            let points = try DebtProjectionEngine.project(
                kind: kind,
                startingBalance: startingBalance,
                apr: apr,
                payment: payment,
                startDate: normalizeToMonth(startFrom),
                maxMonths: 600
            )
            if let idx = points.firstIndex(where: { $0.balance == 0 }) {
                let zeroDate = points[idx].date
                if let anchor = latestSnapshotDate(account) {
                    let sDay = Calendar.current.component(.day, from: anchor)
                    return statementDate(onOrBefore: zeroDate, day: sDay)
                } else {
                    return zeroDate
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    private func absDecimal(_ d: Decimal) -> Decimal { d < 0 ? -d : d }

    private func absProjectedOrBase(for account: Account, planDate: Date, base: Decimal) -> Decimal {
        do {
            if let projected = try projectedBalance(for: account, on: planDate) {
                return absDecimal(projected)
            }
        } catch {
            // If projection fails, fall back to base
        }
        return base
    }

    private func totalsForAccounts(_ accts: [Account]) -> (balance: Decimal, payment: Decimal, interest: Decimal, afterPayment: Decimal) {
        var totalBalance: Decimal = 0
        var totalPayment: Decimal = 0
        var totalInterest: Decimal = 0
        var totalAfter: Decimal = 0
        
        let planMonth = currentPlan?.months.first

        for acct in accts {
            let base = absDecimal(latestBalance(acct))
            let bal: Decimal = {
                if let plan = appliedPlanDate, appliedPlanMode == .projectedAtDate {
                    return absProjectedOrBase(for: acct, planDate: plan, base: base)
                } else {
                    return base
                }
            }()
            totalBalance += bal
            
            let pay: Decimal = planMonth?.payments[acct.id] ?? monthlyPayment(for: acct, balance: bal)
            totalPayment += pay
            
            if let m = planMonth, let i = m.interest[acct.id], let after = m.balances[acct.id] {
                totalInterest += i
                totalAfter += after
            } else {
                let step = monthStep(for: acct, balance: bal, payment: pay)
                totalInterest += step.interest
                totalAfter += step.afterPaymentBalance
            }
        }
        return (totalBalance, totalPayment, totalInterest, totalAfter)
    }
    
    private func parseCurrencyInput(_ input: String) -> Decimal? {
        let filtered = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        return Decimal(string: filtered)
    }
    
    // MARK: - Income & Bills helpers
    
    private func allCashFlowItems() -> [CashFlowItem] {
        do {
            return try modelContext.fetch(FetchDescriptor<CashFlowItem>())
        } catch {
            return []
        }
    }
    
    private func monthlyEquivalent(amount: Decimal, frequency: PaymentFrequency) -> Decimal {
        return amount * frequency.monthlyEquivalentFactor
    }
    
    private var computedMonthlyIncome: Decimal {
        let items = allCashFlowItems().filter { $0.isIncome }
        return items.reduce(0) { acc, item in
            acc + monthlyEquivalent(amount: item.amount, frequency: item.frequency)
        }
    }
    
    private var computedMonthlyBills: Decimal {
        let items = allCashFlowItems().filter { !$0.isIncome }
        return items.reduce(0) { acc, item in
            acc + monthlyEquivalent(amount: item.amount, frequency: item.frequency)
        }
    }
    
    private var computedMonthlyNet: Decimal {
        computedMonthlyIncome - computedMonthlyBills
    }
}

private extension Decimal {
    func rounded(_ scale: Int) -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, scale, .bankers)
        return result
    }
}

