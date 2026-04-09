//
//  DebtSummaryView.swift
//  awaremoney
//
//  Created by Assistant on 2/1/26
//

import SwiftUI
import SwiftData
import Foundation
#if canImport(UIKit)
import UIKit
#endif
import Charts

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
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [Account] = []
    @State private var showPlanSheet = false
    @AppStorage("useFixedDebtBudget") private var useFixedDebtBudget: Bool = false
    @AppStorage("debtBudgetOverrideAmount") private var debtBudgetOverrideAmount: Double = 0
    @AppStorage("debtPlanStartModeRaw") private var debtPlanStartModeRaw: String = "currentInputs"
    @AppStorage("debtPlanStartDate") private var debtPlanStartDateEpoch: Double = 0
    @AppStorage("includeNonMonthlyIncomeSpreads") private var includeNonMonthlyIncomeSpreads: Bool = true
    @AppStorage("oneTimeIncomeDefaultSpreadMonths") private var oneTimeIncomeDefaultSpreadMonths: Int = 12
    @AppStorage("baselineBudgetSourceRaw") private var baselineBudgetSourceRaw: String = "recurringNet" // or "fixed"
    
    @State private var tempPlanDate: Date = {
        Calendar.current.date(byAdding: .month, value: 12, to: Date()) ?? Date()
    }()
    @State private var appliedPlanDate: Date? = nil
    private enum PlanMode: String, CaseIterable {
        case currentInputs = "Start now"
        case projectedAtDate = "Start on date"
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

    @FocusState private var focusedField: FocusField?
    private enum FocusField: Hashable {
        case monthlyBudget
    }
    private var isPhone: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }
    private var isEditing: Bool { focusedField != nil }
    
    // Added @AppStorage properties for IncomeScheduler settings
    // (already declared above)

    private func recomputeAppliedState() {
        switch settings.defaultPayoffStrategyRaw {
        case "snowball": appliedStrategy = .snowball
        case "avalanche": appliedStrategy = .avalanche
        default: appliedStrategy = .minimumsOnly
        }
        if baselineBudgetSourceRaw == "fixed", useFixedDebtBudget, debtBudgetOverrideAmount > 0 {
            appliedBudget = NSDecimalNumber(value: debtBudgetOverrideAmount).decimalValue
        } else {
            appliedBudget = nil
        }
        switch debtPlanStartModeRaw {
        case "projectedAtDate":
            appliedPlanMode = .projectedAtDate
            appliedPlanDate = (debtPlanStartDateEpoch > 0) ? Date(timeIntervalSince1970: debtPlanStartDateEpoch) : nil
        default:
            appliedPlanMode = .currentInputs
            appliedPlanDate = nil
        }
        rebuildPlan()
    }
    
    private var baselineSource: IncomeScheduler.BaselineSource {
        if baselineBudgetSourceRaw == "fixed", useFixedDebtBudget, debtBudgetOverrideAmount > 0 {
            return .fixedAmount(Decimal(debtBudgetOverrideAmount))
        } else {
            return .recurringNet
        }
    }
    
    private func sanitizedDefaultSpread(_ v: Int) -> Int { [3,6,12].contains(v) ? v : 12 }
    
    private func tempBaselineSource() -> IncomeScheduler.BaselineSource {
        if baselineBudgetSourceRaw == "fixed" {
            let trimmed = tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = parseCurrencyInput(trimmed), d > 0 {
                return .fixedAmount(d)
            }
        }
        return .recurringNet
    }
    
    private func budgetSchedule(start: Date, months: Int, baselineOverride: IncomeScheduler.BaselineSource? = nil) -> [Date: Decimal] {
        let items = allCashFlowItems()
        let schedule = IncomeScheduler.budgetByMonth(
            items: items,
            start: start,
            months: months,
            includeSpreads: includeNonMonthlyIncomeSpreads,
            oneTimeDefaultSpreadMonths: sanitizedDefaultSpread(oneTimeIncomeDefaultSpreadMonths),
            baselineSource: baselineOverride ?? baselineSource
        )
        return schedule
    }
    
    // MARK: - Feasibility pre-check for the current temp plan
    private func feasibilityForTempPlan() -> (available: Decimal, minimums: Decimal, shortfall: Decimal) {
        // Determine the start month based on current temp plan mode/date
        let startMonth = normalizeToMonth(tempPlanMode == .projectedAtDate ? tempPlanDate : Date())
        // Build a 12-month schedule and use the first month for feasibility
        let schedule = budgetSchedule(start: startMonth, months: 12, baselineOverride: tempBaselineSource())
        let availableThisMonth = schedule[startMonth] ?? 0

        // Compute balances (projected when needed) and minimums for debts that have a positive balance
        let filteredAccounts = accounts.filter { acct in
            let baseBal = absDecimal(latestBalance(acct))
            let bal: Decimal = {
                if tempPlanMode == .projectedAtDate {
                    return absProjectedOrBase(for: acct, planDate: startMonth, base: baseBal)
                } else {
                    return baseBal
                }
            }()
            return bal > 0
        }

        let minimumsTotal: Decimal = filteredAccounts.reduce(0) { acc, acct in
            let baseBal = absDecimal(latestBalance(acct))
            let bal: Decimal = (tempPlanMode == .projectedAtDate)
                ? absProjectedOrBase(for: acct, planDate: startMonth, base: baseBal)
                : baseBal
            return acc + monthlyPayment(for: acct, balance: bal)
        }

        let shortfall = max(0, (minimumsTotal - availableThisMonth))
        return (availableThisMonth, minimumsTotal, shortfall)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let compact = isCompactLayout(proxy.size)
                let isPortrait = proxy.size.height > proxy.size.width
//                let toolbarCompact = !((hSizeClass == .regular) && proxy.size.width >= 844)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Portrait hint for iPhone
                        if isPhone && isPortrait {
                            HStack(spacing: 6) {
                                Image(systemName: "rotate.left")
                                Text("Best viewed in landscape")
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(.thinMaterial, in: Capsule())
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.bottom, compact ? 6 : 8)
                        }
                        
                        if isPortrait && proxy.size.width < 844 {
                            let paddingH: CGFloat = compact ? 6 : 12
                            let contentWidth: CGFloat = 844 - 2 * paddingH
                            ScrollView(.horizontal, showsIndicators: false) {
                                summaryStack(compact: compact, availableWidth: contentWidth)
                                    .padding(.horizontal, paddingH)
                                    .frame(width: 844, alignment: .topLeading)
                            }
                        } else {
                            let paddingH: CGFloat = compact ? 6 : 12
                            let contentWidth: CGFloat = proxy.size.width - 2 * paddingH
                            summaryStack(compact: compact, availableWidth: contentWidth)
                                .padding(.horizontal, paddingH)
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
                        PlanToolbarButton("Strategy", fixedWidth: 90) {
                            showPlanSheet = true
                        } 
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        PlanToolbarButton("Done", fixedWidth: 60) {
                            dismiss()
                        }
                        .accessibilityIdentifier("debtSummaryDoneButton")
                    }
                }
                .task { recomputeAppliedState() }
                    .onReceive(NotificationCenter.default.publisher(for: .planSettingsDidChange)) { _ in
                        recomputeAppliedState()
                    }
                    .onChange(of: baselineBudgetSourceRaw) { _, _ in recomputeAppliedState() }
                    .onChange(of: useFixedDebtBudget) { _, _ in recomputeAppliedState() }
                    .onChange(of: debtBudgetOverrideAmount) { _, _ in recomputeAppliedState() }
                    .onChange(of: debtPlanStartModeRaw) { _, _ in recomputeAppliedState() }
                    .onChange(of: debtPlanStartDateEpoch) { _, _ in recomputeAppliedState() }
                
                .task { await load() }
                
                .sheet(isPresented: $showPlanSheet) {
                    DebtPlanSheetView()
                        .environment(\.modelContext, modelContext)
                        .environmentObject(settings)
                }
                .onReceive(NotificationCenter.default.publisher(for: .planSettingsDidChange)) { _ in
                    recomputeAppliedState()
                }
                .onChange(of: baselineBudgetSourceRaw) { _, _ in recomputeAppliedState() }
                .onChange(of: useFixedDebtBudget) { _, _ in recomputeAppliedState() }
                .onChange(of: debtBudgetOverrideAmount) { _, _ in recomputeAppliedState() }
                .onChange(of: debtPlanStartModeRaw) { _, _ in recomputeAppliedState() }
                .onChange(of: debtPlanStartDateEpoch) { _, _ in recomputeAppliedState() }
//                .onChange(of: showPlanSheet) { _, newValue in
//                    AMLogging.log("showPlanSheet changed: \(newValue)", component: "DebtSummaryView")
//                }
            }
        }
    }

    // Dynamic column widths that scale to fill available width
    private struct ColumnWidths {
        let account: CGFloat
        let apr: CGFloat
        let balance: CGFloat
        let payment: CGFloat
        let interest: CGFloat
        let afterPayment: CGFloat
        let payoff: CGFloat
    }

    private func columnWidths(for totalWidth: CGFloat, compact: Bool) -> ColumnWidths {
        let gap: CGFloat = compact ? 2 : 12
        let gaps = 6 // number of gaps between 7 columns
        let totalSpacing = gap * CGFloat(gaps)
        let usable = max(0, totalWidth - totalSpacing)
        // Baseline widths taken from existing fixed widths to preserve proportions
        let base: [CGFloat] = compact
            ? [100, 60, 100, 100, 100, 110, 110]
            : [160, 90, 120, 120, 120, 140, 130]
        let sum = base.reduce(0, +)
        let factor: CGFloat = sum > 0 ? (usable / sum) : 1
        func w(_ i: Int) -> CGFloat { max(0, base[i] * factor) }
        return ColumnWidths(
            account: w(0),
            apr: w(1),
            balance: w(2),
            payment: w(3),
            interest: w(4),
            afterPayment: w(5),
            payoff: w(6)
        )
    }

    // MARK: - View Builders

    private func payoffOrderString() -> String? {
        guard let plan = currentPlan, !plan.payoffOrder.isEmpty else { return nil }
        let names = plan.payoffOrder.compactMap { id in accounts.first(where: { $0.id == id })?.name }
        let order = names.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "  •  ")
        return "Payoff order: " + order
    }

    private func summaryStack(compact: Bool, availableWidth: CGFloat) -> some View {
        let widths = columnWidths(for: availableWidth, compact: compact)
        return VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            if let s = payoffOrderString() {
                Text(s)
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
            }
            headerRow(compact: compact, widths: widths)
            Divider()
            ForEach(accounts, id: \.id) { acct in
                row(for: acct, compact: compact, widths: widths)
                Divider()
            }
            totalRow(compact: compact, widths: widths)
        }
    }

    private func planHeader(compact: Bool) -> some View {
        HStack {
            Spacer()
            if appliedPlanMode == .projectedAtDate, let date = appliedPlanDate {
                HStack(spacing: 4) {
                    Text("Start on \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                    Text("• \(appliedStrategyDisplay)\(appliedBudgetText)")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 4) {
                    Text("Start now")
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
        // Keep hiding budget text for Minimums Only to match existing behavior
        guard appliedStrategy != .minimumsOnly else { return "" }

        let startMonth = appliedStartMonth()
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
    }
    
    private var planSubtitleText: String {
        if appliedPlanMode == .projectedAtDate, let date = appliedPlanDate {
            return "Start on \(date.formatted(date: .abbreviated, time: .omitted)) • \(appliedStrategyDisplay)\(appliedBudgetText)"
        } else {
            return "Start now • \(appliedStrategyDisplay)\(appliedBudgetText)"
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
            return " • Adj Budget: \(formatAmount(d))"
        } else {
            return " • Budget: —"
        }
    }

    private func headerRow(compact: Bool, widths: ColumnWidths) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 2 : 12) {
            Text("Account")
                .frame(width: widths.account, alignment: .leading)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("APR")
                .frame(width: widths.apr, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("Balance")
                .frame(width: widths.balance, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("Payment/mo")
                .frame(width: widths.payment, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("Interest/mo")
                .frame(width: widths.interest, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("After Payment")
                .frame(width: widths.afterPayment, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("Payoff")
                .frame(width: widths.payoff, alignment: .trailing)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private func row(for account: Account, compact: Bool, widths: ColumnWidths) -> some View {
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
            if let planDate = currentPlan?.payoffDates[account.id] {
                return planDate
            }
            let asOfDate = (appliedPlanMode == .projectedAtDate) ? (appliedPlanDate ?? Date()) : Date()
            return PayoffCalculator.payoffDate(for: account, asOf: asOfDate)
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
            .frame(width: widths.account, alignment: .leading)

            Text(formatAPR(apr, scale: account.loanTerms?.aprScale, compact: compact))
                .font(compact ? .footnote : .body)
                .frame(width: widths.apr, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(formatAmount(usedBal))
                .font(compact ? .footnote : .body)
                .frame(width: widths.balance, alignment: .trailing)
                .foregroundStyle(.red)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(formatAmount(payment))
                .font(compact ? .footnote : .body)
                .frame(width: widths.payment, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(formatAmount(step.interest))
                .font(compact ? .footnote : .body)
                .frame(width: widths.interest, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text(formatAmount(step.afterPaymentBalance))
                .font(compact ? .footnote : .body)
                .frame(width: widths.afterPayment, alignment: .trailing)
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
            .frame(width: widths.payoff, alignment: .trailing)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
        }
    }

    private func totalRow(compact: Bool, widths: ColumnWidths) -> some View {
        let totals = totalsForAccounts(accounts)
        return HStack(alignment: .firstTextBaseline, spacing: compact ? 2 : 12) {
            Text("Total")
                .font(compact ? .subheadline : .headline)
                .frame(width: widths.account, alignment: .leading)
            Text("")
                .frame(width: widths.apr)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(formatAmount(totals.balance))
                .font(compact ? .footnote : .body)
                .frame(width: widths.balance, alignment: .trailing)
                .foregroundStyle(.red)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(formatAmount(totals.payment))
                .font(compact ? .footnote : .body)
                .frame(width: widths.payment, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(formatAmount(totals.interest))
                .font(compact ? .footnote : .body)
                .frame(width: widths.interest, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(formatAmount(totals.afterPayment))
                .font(compact ? .footnote : .body)
                .frame(width: widths.afterPayment, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text("")
                .frame(width: widths.payoff)
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
                // Now that accounts are set, build the plan with current applied settings
                self.rebuildPlan()
            }
        } catch {
            await MainActor.run {
                self.accounts = []
                self.currentPlan = nil
            }
        }
    }

    // MARK: - Calculations

    // MARK: - Build/refresh the applied plan shown in this view
    private func rebuildPlan() {
        // Determine start month based on applied settings
        let startMonth = appliedStartMonth()

        // Build debts from current accounts using applied start mode/date
        let filteredAccounts = accounts.filter { acct in
            let baseBal = absDecimal(latestBalance(acct))
            let bal: Decimal = (appliedPlanMode == .projectedAtDate)
                ? absProjectedOrBase(for: acct, planDate: startMonth, base: baseBal)
                : baseBal
            return bal > 0
        }

        let debts: [DebtInput] = filteredAccounts.map { acct in
            let baseBal = absDecimal(latestBalance(acct))
            let bal: Decimal = (appliedPlanMode == .projectedAtDate)
                ? absProjectedOrBase(for: acct, planDate: startMonth, base: baseBal)
                : baseBal
            let minPay = monthlyPayment(for: acct, balance: bal)
            return DebtInput(
                id: acct.id,
                name: acct.name,
                apr: acct.loanTerms?.apr,
                balance: bal,
                minPayment: minPay
            )
        }

        guard !debts.isEmpty else {
            currentPlan = nil
            return
        }

        do {
            // Match the sheet’s logic: if we're using recurring net or including spreads,
            // build a per-month schedule; otherwise use a fixed monthly budget.
            if includeNonMonthlyIncomeSpreads || baselineBudgetSourceRaw == "recurringNet" {
                let schedule = budgetSchedule(
                    start: startMonth,
                    months: 120,
                    baselineOverride: baselineSource
                )
                currentPlan = try DebtPayoffEngine.plan(
                    debts: debts,
                    budgetByMonth: schedule,
                    strategy: appliedStrategy,
                    startDate: startMonth
                )
            } else {
                // Fixed monthly budget without spreads
                let budgetToUse: Decimal = appliedBudget ?? debts.reduce(0) { $0 + $1.minPayment }
                currentPlan = try DebtPayoffEngine.plan(
                    debts: debts,
                    monthlyBudget: budgetToUse,
                    strategy: appliedStrategy,
                    startDate: startMonth
                )
            }
        } catch {
            // If anything goes wrong, fall back to minimums-only display
            currentPlan = nil
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

    private func latestSnapshotDate(_ account: Account) -> Date? {
        let id = account.id
        let pred = #Predicate<BalanceSnapshot> { $0.account?.id == id }
        var desc = FetchDescriptor<BalanceSnapshot>(predicate: pred)
        desc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
        desc.fetchLimit = 1
        return try? modelContext.fetch(desc).first?.asOfDate
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
        let after = (balance - effectivePayment + interest).rounded(2)
        return (interest, after)
    }

    private func isCompactLayout(_ size: CGSize) -> Bool {
        return size.width < 1000
    }

    // MARK: - Formatting and helpers

    private func formatAmount(_ amount: Decimal?) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
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

    private func dateInSameMonth(_ date: Date, withDay targetDay: Int) -> Date {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: date))!
        let range = cal.range(of: .day, in: .month, for: monthStart)!
        let clampedDay = min(max(1, targetDay), range.count)
        var comps = cal.dateComponents([.year, .month], from: monthStart)
        comps.day = clampedDay
        return cal.date(from: comps) ?? date
    }

    // Helper: the start month currently applied in the summary
    private func appliedStartMonth() -> Date {
        let start = (appliedPlanMode == .projectedAtDate) ? (appliedPlanDate ?? Date()) : Date()
        return normalizeToMonth(start)
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
        let targetMonth = normalizeToMonth(targetDate)
        let result = try PayoffCalculator.project(for: account, asOf: targetMonth)
        if let point = projectionPoint(result.points, closestTo: targetMonth) {
            return point.balance
        }
        return nil
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
    
    private func reserveSeedingThisMonthTotal() -> Decimal {
        let now = Date()
        let items = allCashFlowItems().filter { !$0.isIncome }
        return items.reduce(Decimal(0)) { acc, item in
            if let plan = BillReservePlanner.planReserve(for: item, asOf: now, currentReserve: item.reserveBalance), plan.seedAmount > 0 {
                return acc + plan.seedAmount
            }
            return acc
        }
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
    
    private var computedMonthlyNet: Decimal { computedMonthlyIncome - computedMonthlyBills }
    
    // MARK: - New helpers for plan sheet additions

    private func shortMonth(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM"
        return fmt.string(from: date)
    }

    private func monthHeader(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "LLLL yyyy"
        return fmt.string(from: date)
    }

    // The existing formatAmount(_ amount: Decimal?) exists, so no duplicate for non-optional Decimal added
}

struct DebtPlanSheetView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    // AppStorage used by the planner
    @AppStorage("includeNonMonthlyIncomeSpreads") private var includeNonMonthlyIncomeSpreads: Bool = true
    @AppStorage("oneTimeIncomeDefaultSpreadMonths") private var oneTimeIncomeDefaultSpreadMonths: Int = 12
    @AppStorage("baselineBudgetSourceRaw") private var baselineBudgetSourceRaw: String = "recurringNet" // or "fixed"
    @AppStorage("useFixedDebtBudget") private var useFixedDebtBudget: Bool = false
    @AppStorage("debtBudgetOverrideAmount") private var debtBudgetOverrideAmount: Double = 0
    @AppStorage("debtPlanStartModeRaw") private var debtPlanStartModeRaw: String = "currentInputs"
    @AppStorage("debtPlanStartDate") private var debtPlanStartDateEpoch: Double = 0

    // Local planning state (mirrors the sheet in DebtSummaryView)
    private enum PlanMode: String, CaseIterable { case currentInputs = "Start now", projectedAtDate = "Start on date" }
    @State private var tempPlanDate: Date = Date()
    @State private var tempPlanMode: PlanMode = .currentInputs

    @State private var tempStrategy: PayoffStrategy = .minimumsOnly
    @State private var tempMonthlyBudget: String = ""
    
    // NEW: Buffer plan settings locally; do not persist until Set Plan
    @State private var tempBaselineBudgetSourceRaw: String = "recurringNet"
    @State private var tempIncludeNonMonthlyIncomeSpreads: Bool = true
    @State private var tempOneTimeIncomeDefaultSpreadMonths: Int = 12

    @State private var budgetValidationError: String? = nil
    @State private var showPlanErrorAlert = false
    @State private var planErrorMessage: String? = nil
    @State private var showBudgetingHint: Bool = false
    @State private var currentPlan: DebtPlanResult? = nil

    // Keyboard handling
    @FocusState private var focusedField: FocusField?
    private enum FocusField: Hashable { case monthlyBudget }
    private var isEditing: Bool { focusedField != nil }

    // Accounts for feasibility and plan building
    @State private var accounts: [Account] = []

    private func sanitizedDefaultSpread(_ v: Int) -> Int { [3,6,12].contains(v) ? v : 12 }

    private var baselineSource: IncomeScheduler.BaselineSource {
        if tempBaselineBudgetSourceRaw == "fixed",
           let d = parseCurrencyInput(tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines)),
           d > 0 {
            return .fixedAmount(d)
        } else {
            return .recurringNet
        }
    }

    private func tempBaselineSource() -> IncomeScheduler.BaselineSource {
        if tempBaselineBudgetSourceRaw == "fixed" {
            let trimmed = tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = parseCurrencyInput(trimmed), d > 0 { return .fixedAmount(d) }
        }
        return .recurringNet
    }

    private func allCashFlowItems() -> [CashFlowItem] {
        do { return try modelContext.fetch(FetchDescriptor<CashFlowItem>()) } catch { return [] }
    }

    private func budgetSchedule(start: Date, months: Int, baselineOverride: IncomeScheduler.BaselineSource? = nil) -> [Date: Decimal] {
        let items = allCashFlowItems()
        return IncomeScheduler.budgetByMonth(
            items: items,
            start: start,
            months: months,
            includeSpreads: tempIncludeNonMonthlyIncomeSpreads,
            oneTimeDefaultSpreadMonths: sanitizedDefaultSpread(tempOneTimeIncomeDefaultSpreadMonths),
            baselineSource: baselineOverride ?? baselineSource
        )
    }

    private func feasibilityForTempPlan() -> (available: Decimal, minimums: Decimal, shortfall: Decimal) {
        let startMonth = normalizeToMonth(tempPlanMode == .projectedAtDate ? tempPlanDate : Date())
        let schedule = budgetSchedule(start: startMonth, months: 12, baselineOverride: tempBaselineSource())
        let availableThisMonth = schedule[startMonth] ?? 0
        let filteredAccounts = accounts.filter { absDecimal(latestBalance($0)) > 0 }
        let minimumsTotal: Decimal = filteredAccounts.reduce(0) { acc, acct in
            let baseBal = absDecimal(latestBalance(acct))
            let bal: Decimal = (tempPlanMode == .projectedAtDate) ? absProjectedOrBase(for: acct, planDate: startMonth, base: baseBal) : baseBal
            return acc + monthlyPayment(for: acct, balance: bal)
        }
        let shortfall = max(0, (minimumsTotal - availableThisMonth))
        return (availableThisMonth, minimumsTotal, shortfall)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let showLandscapeHint = UIDevice.current.userInterfaceIdiom == .phone && geo.size.height > geo.size.width
                ScrollViewReader { proxy in
                    List {
                        Section {
                            DatePicker("Start date", selection: $tempPlanDate, displayedComponents: .date)
                                .datePickerStyle(.compact)
                                .onChange(of: tempPlanDate) { _, newValue in
                                    let isToday = Calendar.current.isDate(newValue, inSameDayAs: Date())
                                    tempPlanMode = isToday ? .currentInputs : .projectedAtDate
                                }
                        } footer: {
                            Text("Choose the date your strategy starts. The selected start date will appear above the summary headers.")
                                .font(.footnote)
                                .foregroundStyle(.primary.opacity(0.75))
                        }
                        Section("Mode") {
                            Picker("Start mode", selection: $tempPlanMode) {
                                Text("Start now").tag(PlanMode.currentInputs)
                                Text("Start on date").tag(PlanMode.projectedAtDate)
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: tempPlanMode) { _, newValue in
                                if newValue == .currentInputs { tempPlanDate = Date() }
                            }
                        }
                        Section("Strategy") {
                            Picker("Strategy", selection: $tempStrategy) {
                                Text("Minimums Only").tag(PayoffStrategy.minimumsOnly)
                                Text("Snowball").tag(PayoffStrategy.snowball)
                                Text("Avalanche").tag(PayoffStrategy.avalanche)
                            }
                            .pickerStyle(.segmented)
                            DebtStrategyInfoView()
                        }
                        Section {
                            LabeledContent("Base Budget") {
                                TextField("$0.00", text: $tempMonthlyBudget)
                                    .multilineTextAlignment(.trailing)
                                    .keyboardType(.decimalPad)
                                    .focused($focusedField, equals: .monthlyBudget)
                                    .submitLabel(.done)
                                    .onSubmit { commitAndDismissKeyboard() }
                                    .highPriorityGesture(TapGesture().onEnded { focusedField = .monthlyBudget; selectAllInFirstResponder() })
                            }
                        } header: {
                            Text("Payoff Plan")
                        } footer: {
                            Group {
                                Text("Your total monthly budget for debt payments. Leave empty if you use Minimums Only strategy or Reoccurring Net.")
                                    .font(.footnote)
                                    .foregroundStyle(.primary.opacity(0.75))
                                if let error = budgetValidationError {
                                    Text(error).font(.footnote).foregroundStyle(.red)
                                }
                            }
                        }

                        Section {
                            Picker("Baseline source", selection: $tempBaselineBudgetSourceRaw) {
                                Text("Recurring Net").tag("recurringNet")
                                Text("Fixed amount").tag("fixed")
                            }
                            .pickerStyle(.segmented)
                            // Budgeting hint disclosure
                            DisclosureGroup(isExpanded: $showBudgetingHint) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Recurring Net")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text("Uses your ongoing income and expenses to compute a monthly budget that can vary by month. It's adjusted for one‑time incomes/bills spread across several months. Debt payments adjust based on what’s available each month.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Divider()
                                    Text("Fixed Amount")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text("Uses a single, constant monthly budget for debt payoff. It's adjusted for one‑time incomes/bills spread across several months. If the fixed amount is too low to cover minimums, the plan will fail until you increase it.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.top, 4)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "info.circle")
                                        .foregroundStyle(.secondary)
                                    Text("Budgeting hint")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Toggle("Include non-monthly incomes/bills", isOn: $tempIncludeNonMonthlyIncomeSpreads)
                            Picker("Default spread for one-time income", selection: $tempOneTimeIncomeDefaultSpreadMonths) {
                                Text("3 months").tag(3)
                                Text("6 months").tag(6)
                                Text("12 months").tag(12)
                            }
                            .pickerStyle(.segmented)
                        } header: {
                            Text("Budget Source & Spreads")
                        } footer: {
                            Text("The above spread applies to non-monthly incomes/bills (e.g., yearly) set to 'Default' when created. If set to something other than 'Default', they will not be affected.")
                                .font(.footnote)
                                .foregroundStyle(.primary.opacity(0.75))
                        }

                        Section("Budget to Paydown Debt Over Time") {
                            let startMonth = normalizeToMonth(tempPlanMode == .projectedAtDate ? tempPlanDate : Date())
                            let schedule = budgetSchedule(start: startMonth, months: 12, baselineOverride: tempBaselineSource())
                            BudgetTimelinePreviewView(startMonth: startMonth, schedule: schedule)
                                .environmentObject(settings)
                                .id("sched-\(includeNonMonthlyIncomeSpreads)-\(oneTimeIncomeDefaultSpreadMonths)-\(baselineBudgetSourceRaw)-\(startMonth.timeIntervalSince1970)")
                        }

                        Section {
                            let startMonth = normalizeToMonth(tempPlanMode == .projectedAtDate ? tempPlanDate : Date())
                            let schedule = budgetSchedule(start: startMonth, months: 12, baselineOverride: tempBaselineSource())
                            DisclosureGroup {
                                let items = allCashFlowItems()
                                let rawExplainContributions = IncomeScheduler.contributionsByMonth(items: items, start: startMonth, months: 12, oneTimeDefaultSpreadMonths: sanitizedDefaultSpread(oneTimeIncomeDefaultSpreadMonths))
                                let explainContributions: [Date: [ExplainPlanView.ContributionRow]] = Dictionary(uniqueKeysWithValues: rawExplainContributions.map { (date, rows) in (date, rows.map { r in ExplainPlanView.ContributionRow(name: r.name, amount: r.amount) }) })
                                let rawBillContributions = IncomeScheduler.billContributionsByMonth(items: items, start: startMonth, months: 12, defaultSpreadMonths: sanitizedDefaultSpread(oneTimeIncomeDefaultSpreadMonths))
                                let explainBillContributions: [Date: [ExplainPlanView.ContributionRow]] = Dictionary(uniqueKeysWithValues: rawBillContributions.map { (date, rows) in (date, rows.map { r in ExplainPlanView.ContributionRow(name: r.name, amount: r.amount) }) })
                                ExplainPlanView(startMonth: startMonth, contributions: explainContributions, billContributions: explainBillContributions, monthlyBudgetByMonth: schedule)
                                    .environmentObject(settings)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    if showLandscapeHint {
                                        HStack {
                                            Text("Plan by Month")
                                            Label("Rotate for better view", systemImage: "rotate.left")
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                                .frame(maxWidth: .infinity, alignment: .center)
                                        }
                                    } else {
                                        Text("Plan by Month")
                                    }
                                }
                            }
                        } header: {
                            Text("Explain my plan")
                        } footer: {
                            Text("Shows which variable incomes/bills contribute to which months. Spreads begin the month after a pay date; remainders apply to the last month.")
                                .font(.footnote)
                                .foregroundStyle(.primary.opacity(0.75))
                        }

                        if tempStrategy != .minimumsOnly {
                            let feas = feasibilityForTempPlan()
                            let isInfeasible = feas.shortfall > 0
                            Section {
                                let planSummary: String = {
                                    if tempPlanMode == .projectedAtDate {
                                        return "Start on \(tempPlanDate.formatted(date: .abbreviated, time: .omitted)) • \(tempStrategyDisplay)\(tempBudgetText)"
                                    } else {
                                        return "Start now • \(tempStrategyDisplay)\(tempBudgetText)"
                                    }
                                }()
                                LabeledContent("Current Plan") { Text(planSummary).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7) }
                                if isInfeasible {
                                    Text("Budget is not enough to cover minimum payments this month.").font(.callout).bold().foregroundStyle(.red)
                                } else {
                                    Text("Budget covers minimum payments this month.").font(.callout).bold()
                                }
                                LabeledContent("Avail for debt (this month)") { Text(formatAmount(feas.available)) }
                                LabeledContent("Minimums due (this month)") { Text(formatAmount(feas.minimums)) }
                                if isInfeasible {
                                    LabeledContent("Shortfall") { Text(formatAmount(feas.shortfall)).foregroundStyle(.red) }
                                    Button("Switch to Minimums Only") { tempStrategy = .minimumsOnly }
                                        .buttonStyle(.borderedProminent)
                                        .tint(.blue)
                                }
                            } header: { Text("Feasibility") }
                            .id("feasibility-section")
                        }

                        Section("Income & Bills") {
                            NavigationLink("Manage Income & Bills") { IncomeAndBillsView() }
                            LabeledContent("Monthly Income") { Text(formatAmount(computedMonthlyIncome)) }
                            LabeledContent("Monthly Bills") { Text(formatAmount(computedMonthlyBills)) }
                            if reserveSeedingThisMonthTotal() > 0 {
                                LabeledContent("Reserve Seed (This Month)") { Text(formatAmount(reserveSeedingThisMonthTotal())) }
                            }
                            LabeledContent("Net for Debt") { Text(formatAmount(computedMonthlyIncome - computedMonthlyBills)) }
                            Button("Use Net as Budget") {
                                let net = computedMonthlyIncome - computedMonthlyBills
                                if net > 0 { tempMonthlyBudget = formatAmount(net) }
                            }
                            .disabled((computedMonthlyIncome - computedMonthlyBills) <= 0)
                        }
                    }
                    .safeAreaInset(edge: .top) {
                        let feas = feasibilityForTempPlan()
                        let isInfeasible = (tempStrategy != .minimumsOnly) && (feas.shortfall > 0)
                        if isInfeasible {
                            HStack {
                                Spacer()
                                Button {
                                    withAnimation(.snappy) { proxy.scrollTo("feasibility-section", anchor: .top) }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                        Text("Shortfall: \(formatAmount(feas.shortfall)) • View details")
                                    }
                                    .font(.caption)
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(.thinMaterial, in: Capsule())
                                .overlay(Capsule().stroke(Color.red.opacity(0.3)))
                                .foregroundStyle(.red)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 12)
                            .background(.bar)
                            .overlay(Divider(), alignment: .bottom)
                        } else { EmptyView() }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Strategy start")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // Prefill strategy from settings
                switch settings.defaultPayoffStrategyRaw {
                case "snowball": tempStrategy = .snowball
                case "avalanche": tempStrategy = .avalanche
                default: tempStrategy = .minimumsOnly
                }
                // Prefill budget with Net for Debt if enabled
                if settings.useNetForDebtBudgetDefault {
                    let net = computedMonthlyIncome - computedMonthlyBills
                    if net > 0 { tempMonthlyBudget = formatAmount(net) }
                }
                let trimmed = tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines)
                if let d = parseCurrencyInput(trimmed) { tempMonthlyBudget = formatAmount(d) }
                
                // Prefill from saved fixed amount whenever available,
                // regardless of the useFixedDebtBudget flag state.
                if debtBudgetOverrideAmount > 0 {
                    let saved = NSDecimalNumber(value: debtBudgetOverrideAmount).decimalValue
                    tempMonthlyBudget = formatAmount(saved)
                }

                if debtPlanStartModeRaw == "projectedAtDate" {
                    tempPlanMode = .projectedAtDate
                    if debtPlanStartDateEpoch > 0 {
                        tempPlanDate = Date(timeIntervalSince1970: debtPlanStartDateEpoch)
                    }
                } else {
                    tempPlanMode = .currentInputs
                }
                // NEW: Seed local plan settings from persisted values
                tempBaselineBudgetSourceRaw = baselineBudgetSourceRaw
                // If a fixed budget is currently in effect, force the sheet to show "Fixed amount"
                // and prefill the saved amount so validations use the correct value when launched
                // from PlanBanner.
                if useFixedDebtBudget, debtBudgetOverrideAmount > 0 {
                    tempBaselineBudgetSourceRaw = "fixed"
                    let saved = NSDecimalNumber(value: debtBudgetOverrideAmount).decimalValue
                    tempMonthlyBudget = formatAmount(saved)
                }
                tempIncludeNonMonthlyIncomeSpreads = includeNonMonthlyIncomeSpreads
                tempOneTimeIncomeDefaultSpreadMonths = oneTimeIncomeDefaultSpreadMonths
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    let feas = feasibilityForTempPlan()
                    let isInfeasible = (tempStrategy != .minimumsOnly) && (feas.shortfall > 0)
                    PlanToolbarButton("Set Plan") {
                        let feasCheck = feasibilityForTempPlan()
                        if tempStrategy != .minimumsOnly && feasCheck.shortfall > 0 {
                            let availText = formatAmount(feasCheck.available)
                            let minsText = formatAmount(feasCheck.minimums)
                            let message = "The budget available this month (\(availText)) is less than your minimum payments (\(minsText)). Please increase your budget, adjust income/bills, or choose Minimums Only."
                            budgetValidationError = message
                            planErrorMessage = message
                            showPlanErrorAlert = true
                            return
                        }
                        budgetValidationError = nil
                        let parsedBudget: Decimal? = {
                            if tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
                            else { return parseCurrencyInput(tempMonthlyBudget) }
                        }()
                        if tempStrategy != .minimumsOnly && parsedBudget == nil {
                            budgetValidationError = "Please enter a valid budget amount or select the Minimums Only strategy."
                            planErrorMessage = "Please enter a valid budget amount or select the Minimums Only strategy."
                            showPlanErrorAlert = true
                            return
                        }

                        // Build debts from current accounts
                        let filteredAccounts = accounts.filter { acct in
                            let baseBal = absDecimal(latestBalance(acct))
                            let bal: Decimal = (tempPlanMode == .projectedAtDate) ? absProjectedOrBase(for: acct, planDate: normalizeToMonth(tempPlanDate), base: baseBal) : baseBal
                            return bal > 0
                        }
                        let debts: [DebtInput] = filteredAccounts.map { acct in
                            let baseBal = absDecimal(latestBalance(acct))
                            let bal: Decimal = (tempPlanMode == .projectedAtDate) ? absProjectedOrBase(for: acct, planDate: normalizeToMonth(tempPlanDate), base: baseBal) : baseBal
                            let minPayment = monthlyPayment(for: acct, balance: bal)
                            return DebtInput(id: acct.id, name: acct.name, apr: acct.loanTerms?.apr, balance: bal, minPayment: minPayment)
                        }

                        // Determine budget series
                        let startDateForPlan = normalizeToMonth(tempPlanMode == .projectedAtDate ? tempPlanDate : Date())
                        // Replace the plan building condition to use temp values:
                        let schedule = budgetSchedule(start: startDateForPlan, months: 60, baselineOverride: tempBaselineSource())

                        do {
                            let planResult: DebtPlanResult
                            // Use tempIncludeNonMonthlyIncomeSpreads and tempBaselineBudgetSourceRaw for preview logic
                            if tempIncludeNonMonthlyIncomeSpreads || tempBaselineBudgetSourceRaw == "recurringNet" {
                                planResult = try DebtPayoffEngine.plan(
                                    debts: debts,
                                    budgetByMonth: schedule,
                                    strategy: tempStrategy,
                                    startDate: startDateForPlan
                                )
                            } else {
                                // Fixed path requires a valid parsed budget
                                let budgetToUse: Decimal = parsedBudget ?? debts.reduce(0) { $0 + $1.minPayment }
                                planResult = try DebtPayoffEngine.plan(
                                    debts: debts,
                                    monthlyBudget: budgetToUse,
                                    strategy: tempStrategy,
                                    startDate: startDateForPlan
                                )
                            }
                            currentPlan = planResult

                            // Persist selections for other views — only now (on Set Plan)

                            // 1) Strategy
                            switch tempStrategy {
                            case .minimumsOnly: settings.defaultPayoffStrategyRaw = "minimumsOnly"
                            case .snowball:     settings.defaultPayoffStrategyRaw = "snowball"
                            case .avalanche:    settings.defaultPayoffStrategyRaw = "avalanche"
                            }

                            // 2) Baseline source & spreads
                            baselineBudgetSourceRaw = tempBaselineBudgetSourceRaw
                            includeNonMonthlyIncomeSpreads = tempIncludeNonMonthlyIncomeSpreads
                            oneTimeIncomeDefaultSpreadMonths = tempOneTimeIncomeDefaultSpreadMonths

                            // 3) Fixed/Recurring budget persistence
                            if tempBaselineBudgetSourceRaw == "fixed" {
                                // Require a valid budget amount for fixed baseline
                                if let b = parsedBudget, b > 0 {
                                    useFixedDebtBudget = true
                                    debtBudgetOverrideAmount = NSDecimalNumber(decimal: b).doubleValue
                                } else {
                                    budgetValidationError = "Please enter a valid budget amount for Fixed source or choose Recurring Net."
                                    planErrorMessage = budgetValidationError
                                    showPlanErrorAlert = true
                                    return
                                }
                            } else {
                                // Recurring Net path: ensure we are not stuck in fixed mode
                                useFixedDebtBudget = false
                                debtBudgetOverrideAmount = 0.0
                            }

                            // 4) Start mode/date
                            debtPlanStartModeRaw = (tempPlanMode == .projectedAtDate) ? "projectedAtDate" : "currentInputs"
                            let normalizedStart = normalizeToMonth(tempPlanMode == .projectedAtDate ? tempPlanDate : Date())
                            debtPlanStartDateEpoch = (tempPlanMode == .projectedAtDate) ? normalizedStart.timeIntervalSince1970 : 0

                            NotificationCenter.default.post(name: .planSettingsDidChange, object: nil)
                            dismiss()
                        } catch DebtPlanError.infeasibleBudget {
                            budgetValidationError = "The budget is too low to cover minimum payments. Please increase your budget or choose Minimums Only strategy."
                            planErrorMessage = budgetValidationError
                            showPlanErrorAlert = true
                        } catch {
                            budgetValidationError = "An unexpected error occurred."
                            planErrorMessage = budgetValidationError
                            showPlanErrorAlert = true
                        }
                    }
                    .disabled(isInfeasible)
                }
                ToolbarItem(placement: .cancellationAction) {
                    PlanToolbarButton("Cancel", fixedWidth: 70) { dismiss() }
                }
            }
            .alert("Can't set plan", isPresented: $showPlanErrorAlert) { Button("OK", role: .cancel) { } } message: { Text(planErrorMessage ?? "") }
            .safeAreaInset(edge: .bottom) {
                Group {
                    if isEditing {
                        EditingAccessoryBar(
                            canGoPrevious: false,
                            canGoNext: false,
                            onPrevious: { },
                            onNext: { },
                            onDone: { commitAndDismissKeyboard() }
                        )
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else { EmptyView().frame(height: 0) }
                }
                .animation(.snappy, value: isEditing)
            }
            .task { await loadAccounts() }
        }
    }

    // MARK: - Helpers copied from DebtSummaryView

    private func loadAccounts() async {
        do {
            let all = try modelContext.fetch(FetchDescriptor<Account>())
            await MainActor.run { self.accounts = all.filter { $0.type == .loan || $0.type == .creditCard } }
        } catch { await MainActor.run { self.accounts = [] } }
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

    private func monthlyPayment(for account: Account, balance: Decimal) -> Decimal {
        if let configured = account.loanTerms?.paymentAmount, configured > 0 { return configured }
        let twoPercent = Decimal(string: "0.02") ?? 0.02
        return (balance * twoPercent).rounded(2)
    }

    private func absDecimal(_ d: Decimal) -> Decimal { d < 0 ? -d : d }

    private func normalizeToMonth(_ date: Date) -> Date {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month], from: date)
        return cal.date(from: comps) ?? date
    }

    private func projectedBalance(for account: Account, on targetDate: Date) throws -> Decimal? {
        let targetMonth = normalizeToMonth(targetDate)
        let result = try PayoffCalculator.project(for: account, asOf: targetMonth)
        let cal = Calendar.current
        let sorted = result.points.sorted { $0.date < $1.date }
        if let exact = sorted.first(where: { cal.isDate($0.date, equalTo: targetMonth, toGranularity: .month) }) { return exact.balance }
        return sorted.last(where: { $0.date <= targetMonth })?.balance ?? sorted.first?.balance
    }

    private func absProjectedOrBase(for account: Account, planDate: Date, base: Decimal) -> Decimal {
        do { if let projected = try projectedBalance(for: account, on: planDate) { return absDecimal(projected) } } catch { }
        return base
    }

    private var computedMonthlyIncome: Decimal {
        let items = allCashFlowItems().filter { $0.isIncome }
        return items.reduce(0) { $0 + ($1.amount * $1.frequency.monthlyEquivalentFactor) }
    }

    private var computedMonthlyBills: Decimal {
        let items = allCashFlowItems().filter { !$0.isIncome }
        return items.reduce(0) { $0 + ($1.amount * $1.frequency.monthlyEquivalentFactor) }
    }

    private func reserveSeedingThisMonthTotal() -> Decimal {
        let now = Date()
        let items = allCashFlowItems().filter { !$0.isIncome }
        return items.reduce(Decimal(0)) { acc, item in
            if let plan = BillReservePlanner.planReserve(for: item, asOf: now, currentReserve: item.reserveBalance), plan.seedAmount > 0 { return acc + plan.seedAmount }
            return acc
        }
    }

    private func parseCurrencyInput(_ input: String) -> Decimal? {
        let filtered = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "")
        return Decimal(string: filtered)
    }

    private func formatAmount(_ amount: Decimal?) -> String {
        let nf = NumberFormatter(); nf.numberStyle = .currency; nf.currencyCode = settings.currencyCode
        guard let amount = amount else { return "—" }
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private var tempStrategyDisplay: String {
        switch tempStrategy { case .minimumsOnly: return "Minimums"; case .snowball: return "Snowball"; case .avalanche: return "Avalanche" }
    }

    private var tempBudgetText: String {
        guard tempStrategy != .minimumsOnly else { return "" }
        let trimmed = tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let d = parseCurrencyInput(trimmed) { return " • Adj Budget: \(formatAmount(d))" } else { return " • Budget: —" }
    }

    private func commitAndDismissKeyboard() {
        let trimmed = tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = parseCurrencyInput(trimmed) { tempMonthlyBudget = formatAmount(d) }
        focusedField = nil
        #if canImport(UIKit)
        let keyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first { $0.isKeyWindow }
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

    // MARK: - Local copies of subviews used in the sheet

    private struct BudgetTimelinePreviewView: View {
        let startMonth: Date
        let schedule: [Date: Decimal]
        @EnvironmentObject private var settings: SettingsStore
        private func shortMonth(_ date: Date) -> String { let fmt = DateFormatter(); fmt.dateFormat = "MMM"; return fmt.string(from: date) }
        private func formatAmount(_ amount: Decimal?) -> String { let nf = NumberFormatter(); nf.numberStyle = .currency; nf.currencyCode = settings.currencyCode; guard let amount = amount else { return "—" }; return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)" }
        @ViewBuilder private func chartView(data: [(date: Date, value: Decimal)], minY: Double, maxY: Double, xStart: Date, xEnd: Date, labelDates: Set<Date>) -> some View {
            Chart(data, id: \.date) { point in
                LineMark(x: .value("Month", point.date), y: .value("Budget", NSDecimalNumber(decimal: point.value).doubleValue)).interpolationMethod(.monotone).foregroundStyle(Color.accentColor)
                AreaMark(x: .value("Month", point.date), yStart: .value("Baseline", minY), yEnd: .value("Budget", NSDecimalNumber(decimal: point.value).doubleValue)).interpolationMethod(.monotone).foregroundStyle(Color.accentColor.opacity(0.15))
                PointMark(x: .value("Month", point.date), y: .value("Budget", NSDecimalNumber(decimal: point.value).doubleValue)).symbol(Circle().strokeBorder(lineWidth: 1)).symbolSize(20).foregroundStyle(Color.accentColor)
                if labelDates.contains(point.date) {
                    PointMark(x: .value("Month", point.date), y: .value("Budget", NSDecimalNumber(decimal: point.value).doubleValue)).opacity(0).annotation(position: .top) { Text(formatAmount(point.value)).font(.caption2).foregroundStyle(.primary).padding(.horizontal, 6).padding(.vertical, 2).background(Color(.systemBackground).opacity(0.9), in: Capsule()).overlay(Capsule().stroke(Color.secondary.opacity(0.25))) }
                }
            }
            .chartXScale(domain: xStart...xEnd)
            .chartYScale(domain: (minY - max(25, (maxY - minY) * 0.1))...(maxY + max(25, (maxY - minY) * 0.1)))
            .chartXAxis { AxisMarks(values: .stride(by: .month, count: 2)) { value in AxisValueLabel() { if let d = value.as(Date.self) { Text(shortMonth(d)) } } } }
            .chartPlotStyle { plotArea in plotArea.padding(.bottom, 8) }
            .chartYAxis { AxisMarks(position: .leading) { value in AxisGridLine(); AxisTick(); AxisValueLabel { if let y = value.as(Double.self) { Text(formatAmount(Decimal(y))) } } } }
        }
        var body: some View {
            let sortedMonths = Array(schedule.keys).sorted(by: { $0 < $1 })
            let data: [(date: Date, value: Decimal)] = sortedMonths.map { ($0, schedule[$0] ?? 0) }
            let doubles = data.map { NSDecimalNumber(decimal: $0.value).doubleValue }
            let minY = doubles.min() ?? 0
            let maxY = doubles.max() ?? 0
            let labelDates: Set<Date> = Set([data.first?.date, data.count > 5 ? data[5].date : nil, data.count > 11 ? data[11].date : nil].compactMap { $0 })
            let cal = Calendar.current
            let firstMonth = sortedMonths.first ?? startMonth
            let lastMonth = sortedMonths.last ?? startMonth
            let xStart = cal.date(byAdding: .month, value: -1, to: firstMonth) ?? firstMonth
            let xEnd = cal.date(byAdding: .month, value: 1, to: lastMonth) ?? lastMonth
            let chart = chartView(data: data, minY: minY, maxY: maxY, xStart: xStart, xEnd: xEnd, labelDates: labelDates).frame(height: 160)
            let firstVal = data.first?.value
            let minValDec = data.map { $0.value }.min()
            let maxValDec = data.map { $0.value }.max()
            let firstText: String? = firstVal.map { "First: \(formatAmount($0))" }
            let rangeText: String? = {
                if let minValDec, let maxValDec {
                    return "Range: \(formatAmount(minValDec)) – \(formatAmount(maxValDec))"
                }
                return nil
            }()
            Group {
                if !data.isEmpty {
                    chart
                    HStack(spacing: 12) { if let firstText { Text(firstText) }; if let rangeText { Text(rangeText) } }.font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
                } else { Text("No data available").font(.footnote).foregroundStyle(.secondary) }
            }
        }
    }

    private struct ExplainPlanView: View {
        struct ContributionRow: Hashable { let name: String; let amount: Decimal }
        let startMonth: Date
        let contributions: [Date: [ContributionRow]]
        let billContributions: [Date: [ContributionRow]]
        let monthlyBudgetByMonth: [Date: Decimal]
        @EnvironmentObject private var settings: SettingsStore
        private func monthHeader(_ date: Date) -> String { let fmt = DateFormatter(); fmt.dateFormat = "LLLL yyyy"; return fmt.string(from: date) }
        private func formatAmount(_ amount: Decimal?) -> String { let nf = NumberFormatter(); nf.numberStyle = .currency; nf.currencyCode = settings.currencyCode; guard let amount = amount else { return "—" }; let absNumber = NSDecimalNumber(decimal: amount < 0 ? -amount : amount); let base = nf.string(from: absNumber) ?? "\(absNumber)"; return amount < 0 ? "(\(base))" : base }
        var body: some View {
            let monthSet = Set(contributions.keys).union(billContributions.keys)
            let monthsSorted = Array(monthSet).sorted(by: { $0 < $1 })
            let amountWidth: CGFloat = 100
            if monthsSorted.isEmpty { Text("No non-monthly income or bills contribute in this period.").font(.footnote).foregroundStyle(.secondary) }
            else {
                ForEach(monthsSorted, id: \.self) { m in
                    let incomeRows = contributions[m] ?? []
                    let billRows = billContributions[m] ?? []
                    let rowCount = max(incomeRows.count, billRows.count)
                    Section {
                        ForEach(0..<rowCount, id: \.self) { idx in
                            HStack(alignment: .firstTextBaseline, spacing: 24) {
                                HStack(spacing: 2) {
                                    if idx < incomeRows.count {
                                        Text(incomeRows[idx].name).frame(idealWidth: 120, maxWidth: .infinity, alignment: .leading).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 2)
                                        Text(formatAmount(incomeRows[idx].amount)).monospacedDigit().foregroundStyle(.secondary).frame(width: amountWidth, alignment: .trailing).layoutPriority(1)
                                    } else { Text("").frame(maxWidth: .infinity, alignment: .leading); Spacer(minLength: 2); Text("").frame(width: amountWidth) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                HStack(spacing: 2) {
                                    if idx < billRows.count {
                                        Text(billRows[idx].name).frame(idealWidth: 120, alignment: .leading).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 2)
                                        Text(formatAmount(billRows[idx].amount)).monospacedDigit().foregroundStyle(.red).frame(width: amountWidth, alignment: .trailing).layoutPriority(1)
                                    } else { Text("").frame(maxWidth: .infinity, alignment: .leading); Spacer(minLength: 2); Text("").frame(width: amountWidth) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } header: {
                        HStack {
                            Text("Variable Income").frame(maxWidth: .infinity, alignment: .center).underline()
                            Text(monthHeader(m)).frame(maxWidth: .infinity, alignment: .center)
                            Text("Variable Bills").frame(maxWidth: .infinity, alignment: .center).underline()
                        }
                    } footer: {
                        let variableIncome = (contributions[m] ?? []).reduce(0) { $0 + $1.amount }
                        let variableBills = (billContributions[m] ?? []).reduce(0) { $0 + $1.amount }
                        let budgetForMonth = monthlyBudgetByMonth[m] ?? 0
                        let baselineForMonth = budgetForMonth - variableIncome - variableBills
                        let incomeColor = Color(red: 0.0, green: 0.5, blue: 0.0)
                        let billsColor  = Color(red: 0.8, green: 0.0, blue: 0.0)
                        HStack {
                            column(title: "Adj Budget", value: budgetForMonth, color: .primary)
                            Image(systemName: "equal").foregroundStyle(.secondary)
                            column(title: "Base Budget", value: baselineForMonth, color: .primary)
                            Image(systemName: "plus").foregroundStyle(.secondary)
                            column(title: "Variable Income", value: variableIncome, color: incomeColor)
                            Image(systemName: "minus").foregroundStyle(.secondary)
                            column(title: "Variable Bills", value: -abs(variableBills), color: billsColor)
                        }
                        .multilineTextAlignment(.center)
                    }
                }
            }
        }
        func column(title: String, value: Decimal, color: Color) -> some View {
            VStack(spacing: 2) { Text(title).font(.caption2).foregroundStyle(.secondary); Text(formatAmount(value)).font(.caption).foregroundStyle(color) }.frame(maxWidth: .infinity)
        }
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

extension Notification.Name {
    static let planSettingsDidChange = Notification.Name("planSettingsDidChange")
}

#if canImport(UIKit)
extension UIView {
    func findFirstResponder() -> UIResponder? {
        if self.isFirstResponder { return self }
        for sub in subviews {
            if let responder = sub.findFirstResponder() {
                return responder
            }
        }
        return nil
    }
}
#endif

