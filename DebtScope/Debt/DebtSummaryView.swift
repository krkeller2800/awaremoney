//
//  DebtSummaryView.swift
//  DebtScope
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

fileprivate func incomeFundingAllocationTotals(from allocations: [BillFundingAllocation]) -> [UUID: Decimal] {
    allocations.reduce(into: [UUID: Decimal]()) { totals, allocation in
        totals[allocation.incomeID, default: 0] += allocation.amount
    }
}

fileprivate struct NonMonthlyAdjustmentBreakdown {
    let incomeSetAside: Decimal
    let billReserve: Decimal
    let netAdjustment: Decimal
}

struct DebtSummaryView: View {
    var embeddedInNavigation: Bool = false
    var onManageIncomeBills: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [Account] = []
    @State private var embeddedPlannerIsEditing = false
    @State private var showDebtChart = false
    @State private var showDebtSchedule = false
    @AppStorage("useFixedDebtBudget") private var useFixedDebtBudget: Bool = false
    @AppStorage("debtBudgetOverrideAmount") private var debtBudgetOverrideAmount: Double = 0
    @AppStorage("lastFixedDebtBudgetAmount") private var lastFixedDebtBudgetAmount: Double = 0
    @AppStorage("debtPaymentReinvestmentRate") private var debtPaymentReinvestmentRate: Double = 1
    @AppStorage("debtPlanStartModeRaw") private var debtPlanStartModeRaw: String = "currentInputs"
    @AppStorage("debtPlanStartDate") private var debtPlanStartDateEpoch: Double = 0
    @AppStorage("debtDiscretionaryReserveAmount") private var debtDiscretionaryReserveAmount: Double = 0
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

    private func usesProjectedBalances(mode: PlanMode, date: Date?) -> Bool {
        guard mode == .projectedAtDate, let date else { return false }
        return normalizeToMonth(date) > normalizeToMonth(Date())
    }
    
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
            baselineSource: baselineOverride ?? baselineSource,
            incomeFundingAllocations: incomeFundingAllocationTotals(from: allBillFundingAllocations())
        )
        return schedule
    }

    private func amortizationScheduleMonthCount() -> Int {
        max(1, currentPlan?.months.count ?? 120)
    }

    private func amortizationAvailableCashSchedule() -> [Date: Decimal] {
        budgetSchedule(
            start: appliedStartMonth(),
            months: amortizationScheduleMonthCount(),
            baselineOverride: baselineSource
        )
    }

    private func amortizationAvailableForDebtSchedule() -> [Date: Decimal] {
        let startMonth = appliedStartMonth()
        let monthCount = amortizationScheduleMonthCount()
        let availableCashSchedule = budgetSchedule(
            start: startMonth,
            months: monthCount,
            baselineOverride: baselineSource
        )

        if includeNonMonthlyIncomeSpreads || baselineBudgetSourceRaw == "recurringNet" {
            return PlanBudgetDisplay.reserveAdjustedBudgetSchedule(
                availableCashSchedule,
                discretionaryReserve: PlanBudgetDisplay.discretionaryReserve(from: debtDiscretionaryReserveAmount),
                appliesReserve: baselineBudgetSourceRaw == "recurringNet"
            )
        }

        let fixedBudget = appliedBudget ?? currentPlan?.months.first?.payments.values.reduce(0, +) ?? 0
        return monthlySchedule(start: startMonth, months: monthCount, amount: fixedBudget)
    }

    private func monthlySchedule(start: Date, months: Int, amount: Decimal) -> [Date: Decimal] {
        let calendar = Calendar.current
        return (0..<months).reduce(into: [:]) { schedule, offset in
            if let month = calendar.date(byAdding: .month, value: offset, to: start) {
                schedule[normalizeToMonth(month)] = amount
            }
        }
    }
    
    // MARK: - Feasibility pre-check for the current temp plan
    private func feasibilityForTempPlan() -> (available: Decimal, minimums: Decimal, shortfall: Decimal) {
        // Determine the start month based on current temp plan mode/date
        let startMonth = normalizeToMonth(tempPlanMode == .projectedAtDate ? tempPlanDate : Date())
        // Build a 12-month schedule and use the first month for feasibility
        let schedule = budgetSchedule(start: startMonth, months: 12, baselineOverride: tempBaselineSource())
        let availableCashThisMonth = schedule[startMonth] ?? 0
        let availableThisMonth = baselineBudgetSourceRaw == "recurringNet"
            ? PlanBudgetDisplay.availableForDebt(
                availableCash: availableCashThisMonth,
                discretionaryReserve: PlanBudgetDisplay.discretionaryReserve(from: debtDiscretionaryReserveAmount)
            )
            : availableCashThisMonth

        let shouldProjectBalances = usesProjectedBalances(mode: tempPlanMode, date: tempPlanDate)

        // Compute balances (projected when needed) and minimums for debts that have a positive balance
        let filteredAccounts = accounts.filter { acct in
            let baseBal = absDecimal(latestBalance(acct))
            let bal = shouldProjectBalances
                ? absProjectedOrBase(for: acct, planDate: startMonth, base: baseBal)
                : baseBal
            return bal > 0
        }

        let minimumsTotal: Decimal = filteredAccounts.reduce(0) { acc, acct in
            let baseBal = absDecimal(latestBalance(acct))
            let bal = shouldProjectBalances
                ? absProjectedOrBase(for: acct, planDate: startMonth, base: baseBal)
                : baseBal
            return acc + monthlyPayment(for: acct, balance: bal)
        }

        let shortfall = max(0, (minimumsTotal - availableThisMonth))
        return (availableThisMonth, minimumsTotal, shortfall)
    }

    private var bodyContent: some View {
        GeometryReader { proxy in
            let compact = isCompactLayout(proxy.size)
            let isPortrait = proxy.size.height > proxy.size.width
//                let toolbarCompact = !((hSizeClass == .regular) && proxy.size.width >= 844)
            ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Portrait hint for iPhone
                        if isPhone && isPortrait {
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: "rotate.left.fill")
                                    .font(.title2.weight(.bold))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Rotate to Landscape")
                                        .font(.headline.weight(.bold))
                                    Text("This table is much easier to read sideways on iPhone.")
                                        .font(.subheadline)
                                }
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(.white)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 14)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .shadow(color: Color.orange.opacity(0.35), radius: 8, x: 0, y: 4)
                            .padding(.horizontal, compact ? 6 : 12)
                            .padding(.bottom, compact ? 8 : 10)
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
                            let outerPadding: CGFloat = embeddedInNavigation ? (compact ? 18 : 28) : (compact ? 6 : 12)
                            let maxContentWidth: CGFloat = compact ? 900 : 980
                            let rawContentWidth = proxy.size.width - 2 * outerPadding
                            let contentWidth: CGFloat = rawContentWidth.isFinite ? min(maxContentWidth, max(0, rawContentWidth)) : 0
                            HStack {
                                Spacer(minLength: outerPadding)
                                summaryStack(compact: compact, availableWidth: contentWidth)
                                    .frame(width: contentWidth, alignment: .topLeading)
                                Spacer(minLength: outerPadding)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.vertical, 8)
                }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Debt Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Debt Summary")
                            .font(.headline)
                            .lineLimit(1)
                            .allowsTightening(true)
                            .minimumScaleFactor(isPhone ? 0.8 : 1)
                        Text(planSubtitleText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(isPhone ? 1 : 2)
                            .allowsTightening(true)
                            .minimumScaleFactor(isPhone ? 0.75 : 1)
                            .fixedSize(horizontal: false, vertical: !isPhone)
                            .layoutPriority(1)
                    }
                    .frame(minWidth: isPhone ? 260 : nil)
                }
                if !embeddedInNavigation {
                    ToolbarItem(placement: .topBarLeading) {
                        PlanToolbarButton("Done", fixedWidth: 60) {
                            dismiss()
                        }
                        .accessibilityIdentifier("debtSummaryDoneButton")
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    PlanToolbarButton("Schedule", fixedWidth: 90) {
                        showDebtSchedule = true
                    }
                    .accessibilityIdentifier("showDebtScheduleButton")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PlanToolbarButton("Chart", fixedWidth: 70) {
                        showDebtChart = true
                    }
                    .accessibilityIdentifier("showDebtChartButton")
                }
            }
            .sheet(isPresented: $showDebtChart) {
                DebtProjectionChartView(items: allCashFlowItems())
                    .environment(\.modelContext, modelContext)
                    .environmentObject(settings)
                    .applySheetSizing()
            }
            .sheet(isPresented: $showDebtSchedule) {
                DebtAmortizationScheduleView(
                    plan: currentPlan,
                    accounts: accounts,
                    availableCashByMonth: amortizationAvailableCashSchedule(),
                    availableForDebtByMonth: amortizationAvailableForDebtSchedule(),
                    discretionaryReserve: PlanBudgetDisplay.discretionaryReserve(from: debtDiscretionaryReserveAmount)
                )
                .environmentObject(settings)
                .applySheetSizing()
            }
            .task { recomputeAppliedState() }
            .task { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .planSettingsDidChange)) { _ in
                recomputeAppliedState()
            }
            .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { _ in
                accounts = []
                currentPlan = nil
                Task { await load() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .debtSummaryEmbeddedPlannerEditingChanged)) { note in
                guard embeddedInNavigation, let isEditing = note.object as? Bool else { return }
                embeddedPlannerIsEditing = isEditing
            }
            .onChange(of: baselineBudgetSourceRaw) { _, _ in recomputeAppliedState() }
            .onChange(of: useFixedDebtBudget) { _, _ in recomputeAppliedState() }
            .onChange(of: debtBudgetOverrideAmount) { _, _ in recomputeAppliedState() }
            .onChange(of: debtDiscretionaryReserveAmount) { _, _ in recomputeAppliedState() }
            .onChange(of: debtPaymentReinvestmentRate) { _, _ in recomputeAppliedState() }
            .onChange(of: debtPlanStartModeRaw) { _, _ in recomputeAppliedState() }
            .onChange(of: debtPlanStartDateEpoch) { _, _ in recomputeAppliedState() }

        }
    }


    @ViewBuilder
    var body: some View {
        if embeddedInNavigation {
            bodyContent
        } else {
            NavigationStack {
                bodyContent
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
        let safeTotalWidth = totalWidth.isFinite ? max(0, totalWidth) : 0
        let gap: CGFloat = compact ? 2 : 12
        let gaps = 6 // number of gaps between 7 columns
        let totalSpacing = gap * CGFloat(gaps)
        let usable = max(0, safeTotalWidth - totalSpacing)
        // Baseline widths taken from existing fixed widths to preserve proportions
        let base: [CGFloat] = compact
            ? [84, 60, 100, 100, 100, 110, 110]
            : [132, 90, 120, 120, 120, 140, 130]
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

    private var inlineStrategyBinding: Binding<PayoffStrategy> {
        Binding(
            get: { appliedStrategy },
            set: { newValue in
                switch newValue {
                case .minimumsOnly:
                    settings.defaultPayoffStrategyRaw = "minimumsOnly"
                case .snowball:
                    settings.defaultPayoffStrategyRaw = "snowball"
                case .avalanche:
                    settings.defaultPayoffStrategyRaw = "avalanche"
                }
                recomputeAppliedState()
                NotificationCenter.default.post(name: .planSettingsDidChange, object: nil)
            }
        )
    }

    private func summaryStack(compact: Bool, availableWidth: CGFloat) -> some View {
        let safeAvailableWidth = availableWidth.isFinite ? max(0, availableWidth) : 0
        let widths = columnWidths(for: safeAvailableWidth, compact: compact)
        return VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack {
                Spacer()
                Picker("Strategy", selection: inlineStrategyBinding) {
                    Text("Minimums Only").tag(PayoffStrategy.minimumsOnly)
                    Text("Snowball").tag(PayoffStrategy.snowball)
                    Text("Avalanche").tag(PayoffStrategy.avalanche)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: min(safeAvailableWidth, compact ? 420 : 520))
                Spacer()
            }
            if accounts.isEmpty {
                ContentUnavailableView(
                    "No debts yet",
                    systemImage: "creditcard",
                    description: Text("Add liability accounts to compare payoff strategies.")
                )
                .frame(maxWidth: .infinity, minHeight: compact ? 220 : 280)
            } else {
                headerRow(compact: compact, widths: widths)
                Divider()
                ForEach(sortedAccountsByPayoffDate(), id: \.id) { acct in
                    row(for: acct, compact: compact, widths: widths)
                    Divider()
                }
                totalRow(compact: compact, widths: widths)
            }
            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Plan Settings")
                        .font(compact ? .headline : .title3.weight(.semibold))
                    Spacer()
                    Text("Changes apply immediately as you edit this plan.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, compact ? 12 : 16)
                .padding(.top, compact ? 10 : 14)

                DebtPlanSheetView(embeddedInNavigation: true, onManageIncomeBills: onManageIncomeBills)
                    .environment(\.modelContext, modelContext)
                    .environmentObject(settings)
                    .frame(maxWidth: .infinity)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.secondary.opacity(0.14))
            )
            .padding(.top, compact ? 10 : 14)
            .id("planSettingsPanel")
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
                oneTimeIncomeDefaultSpreadMonths: oneTimeIncomeDefaultSpreadMonths,
                discretionaryReserveAmount: debtDiscretionaryReserveAmount
            ), avail > 0 {
            return " • Debt Budget: \(formatAmount(avail))"
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
            return " • Debt Budget: \(formatAmount(d))"
        } else {
            return " • Debt Budget: —"
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

            Text("Total Interest")
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
        let usedBal = usesProjectedBalances(mode: appliedPlanMode, date: appliedPlanDate)
            ? absProjectedOrBase(for: account, planDate: appliedStartMonth(), base: baseBal)
            : baseBal
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

        let payoff = projectedPayoffDate(for: account)
        let totalInterestToPayoff = totalInterestUntilPayoff(for: account, startingBalance: usedBal, fallbackPayment: payment)

        return HStack(alignment: .firstTextBaseline, spacing: compact ? 2 : 12) {
            Text(account.name)
                .font(compact ? .subheadline : .headline)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .truncationMode(.tail)
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

            Text(formatAmount(totalInterestToPayoff))
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

    private func projectedPayoffDate(for account: Account) -> Date? {
        if let planDate = currentPlan?.payoffDates[account.id] {
            return planDate
        }
        let asOfDate = usesProjectedBalances(mode: appliedPlanMode, date: appliedPlanDate) ? appliedStartMonth() : Date()
        return PayoffCalculator.payoffDate(for: account, asOf: asOfDate)
    }

    private func totalInterestUntilPayoff(for account: Account, startingBalance: Decimal, fallbackPayment: Decimal) -> Decimal? {
        let preStartInterest = projectedPreStartInterest(for: account)

        if let plan = currentPlan {
            let interestByMonth = plan.months.compactMap { $0.interest[account.id] }
            if !interestByMonth.isEmpty {
                return (preStartInterest + interestByMonth.reduce(0, +)).rounded(2)
            }
        }

        guard startingBalance > 0 else { return preStartInterest.rounded(2) }

        var balance = startingBalance
        var totalInterest = preStartInterest
        var remainingMonths = 600

        while balance > 0, remainingMonths > 0 {
            let step = monthStep(for: account, balance: balance, payment: fallbackPayment)
            totalInterest += step.interest
            if step.afterPaymentBalance >= balance {
                break
            }
            balance = step.afterPaymentBalance
            remainingMonths -= 1
        }

        return totalInterest.rounded(2)
    }

    private func projectedPreStartInterest(for account: Account) -> Decimal {
        guard usesProjectedBalances(mode: appliedPlanMode, date: appliedPlanDate) else { return 0 }
        let startMonth = appliedStartMonth()

        do {
            let projection = try PayoffCalculator.project(for: account, asOf: startMonth)
            return projection.points.reduce(Decimal(0)) { total, point in
                normalizeToMonth(point.date) < startMonth ? total + point.interestPaid : total
            }.rounded(2)
        } catch {
            return 0
        }
    }

    private func sortedAccountsByPayoffDate() -> [Account] {
        accounts.sorted { lhs, rhs in
            let lhsDate = projectedPayoffDate(for: lhs) ?? .distantFuture
            let rhsDate = projectedPayoffDate(for: rhs) ?? .distantFuture
            if lhsDate == rhsDate {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhsDate < rhsDate
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
            Text(formatAmount(totals.totalInterestToPayoff))
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

        let shouldProjectBalances = usesProjectedBalances(mode: appliedPlanMode, date: appliedPlanDate)

        // Build debts from current accounts using applied start mode/date
        let filteredAccounts = accounts.filter { acct in
            let baseBal = absDecimal(latestBalance(acct))
            let bal = shouldProjectBalances
                ? absProjectedOrBase(for: acct, planDate: startMonth, base: baseBal)
                : baseBal
            return bal > 0
        }

        let debts: [DebtInput] = filteredAccounts.map { acct in
            let baseBal = absDecimal(latestBalance(acct))
            let bal = shouldProjectBalances
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
                let availableCashSchedule = budgetSchedule(
                    start: startMonth,
                    months: 120,
                    baselineOverride: baselineSource
                )
                let schedule = PlanBudgetDisplay.reserveAdjustedBudgetSchedule(
                    availableCashSchedule,
                    discretionaryReserve: PlanBudgetDisplay.discretionaryReserve(from: debtDiscretionaryReserveAmount),
                    appliesReserve: baselineBudgetSourceRaw == "recurringNet"
                )
                currentPlan = try DebtPayoffEngine.plan(
                    debts: debts,
                    budgetByMonth: schedule,
                    strategy: appliedStrategy,
                    reinvestmentRate: Decimal(debtPaymentReinvestmentRate),
                    startDate: startMonth
                )
            } else {
                // Fixed monthly budget without spreads
                let budgetToUse: Decimal = appliedBudget ?? debts.reduce(0) { $0 + $1.minPayment }
                currentPlan = try DebtPayoffEngine.plan(
                    debts: debts,
                    monthlyBudget: budgetToUse,
                    strategy: appliedStrategy,
                    reinvestmentRate: Decimal(debtPaymentReinvestmentRate),
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

    private func totalsForAccounts(_ accts: [Account]) -> (balance: Decimal, payment: Decimal, interest: Decimal, totalInterestToPayoff: Decimal) {
        var totalBalance: Decimal = 0
        var totalPayment: Decimal = 0
        var totalInterest: Decimal = 0
        var totalInterestToPayoff: Decimal = 0
        
        let planMonth = currentPlan?.months.first

        for acct in accts {
            let base = absDecimal(latestBalance(acct))
            let bal = usesProjectedBalances(mode: appliedPlanMode, date: appliedPlanDate)
                ? absProjectedOrBase(for: acct, planDate: appliedStartMonth(), base: base)
                : base
            totalBalance += bal
            
            let pay: Decimal = planMonth?.payments[acct.id] ?? monthlyPayment(for: acct, balance: bal)
            totalPayment += pay
            totalInterestToPayoff += totalInterestUntilPayoff(for: acct, startingBalance: bal, fallbackPayment: pay) ?? 0
            
            if let m = planMonth, let i = m.interest[acct.id] {
                totalInterest += i
            } else {
                let step = monthStep(for: acct, balance: bal, payment: pay)
                totalInterest += step.interest
            }
        }
        return (totalBalance, totalPayment, totalInterest, totalInterestToPayoff)
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

    private func allBillFundingAllocations() -> [BillFundingAllocation] {
        do {
            return try modelContext.fetch(FetchDescriptor<BillFundingAllocation>())
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
    var embeddedInNavigation: Bool = false
    var onManageIncomeBills: (() -> Void)? = nil

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    // AppStorage used by the planner
    @AppStorage("includeNonMonthlyIncomeSpreads") private var includeNonMonthlyIncomeSpreads: Bool = true
    @AppStorage("oneTimeIncomeDefaultSpreadMonths") private var oneTimeIncomeDefaultSpreadMonths: Int = 12
    @AppStorage("baselineBudgetSourceRaw") private var baselineBudgetSourceRaw: String = "recurringNet" // or "fixed"
    @AppStorage("useFixedDebtBudget") private var useFixedDebtBudget: Bool = false
    @AppStorage("debtBudgetOverrideAmount") private var debtBudgetOverrideAmount: Double = 0
    @AppStorage("lastFixedDebtBudgetAmount") private var lastFixedDebtBudgetAmount: Double = 0
    @AppStorage("debtPaymentReinvestmentRate") private var debtPaymentReinvestmentRate: Double = 1
    @AppStorage("debtPlanStartModeRaw") private var debtPlanStartModeRaw: String = "currentInputs"
    @AppStorage("debtPlanStartDate") private var debtPlanStartDateEpoch: Double = 0
    @AppStorage("debtDiscretionaryReserveAmount") private var debtDiscretionaryReserveAmount: Double = 0

    // Local planning state (mirrors the sheet in DebtSummaryView)
    private enum PlanMode: String, CaseIterable { case currentInputs = "Start now", projectedAtDate = "Start on date" }
    @State private var tempPlanDate: Date = Date()
    @State private var tempPlanMode: PlanMode = .currentInputs

    @State private var tempStrategy: PayoffStrategy = .minimumsOnly
    @State private var tempMonthlyBudget: String = ""
    @State private var tempDiscretionaryReserve: String = ""
    @State private var tempDebtPaymentReinvestmentRate: Double = 1
    
    // NEW: Buffer plan settings locally; do not persist until Set Plan
    @State private var tempBaselineBudgetSourceRaw: String = "recurringNet"
    @State private var tempIncludeNonMonthlyIncomeSpreads: Bool = true
    @State private var tempOneTimeIncomeDefaultSpreadMonths: Int = 12

    @State private var budgetValidationError: String? = nil
    @State private var showPlanErrorAlert = false
    @State private var planErrorMessage: String? = nil
    @State private var showBudgetingHint: Bool = false
    @State private var currentPlan: DebtPlanResult? = nil
    @State private var expandedAmountRows: Set<String> = []

    // Keyboard handling
    @FocusState private var focusedField: FocusField?
    private enum FocusField: Hashable { case monthlyBudget, discretionaryReserve }
    private var isEditing: Bool { focusedField != nil }
    private var shouldShowPlanLandscapeHint: Bool {
        #if os(iOS)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return false }
        let bounds = UIScreen.main.bounds
        return bounds.height > bounds.width
        #else
        return false
        #endif
    }

    // Accounts for feasibility and plan building
    @State private var accounts: [Account] = []

    private func sanitizedDefaultSpread(_ v: Int) -> Int { [3,6,12].contains(v) ? v : 12 }

    private func usesProjectedBalances(mode: PlanMode, date: Date?) -> Bool {
        guard mode == .projectedAtDate, let date else { return false }
        return normalizeToMonth(date) > normalizeToMonth(Date())
    }

    private var effectiveEditorStrategy: PayoffStrategy {
        if embeddedInNavigation {
            switch settings.defaultPayoffStrategyRaw {
            case "snowball": return .snowball
            case "avalanche": return .avalanche
            default: return .minimumsOnly
            }
        }
        return tempStrategy
    }

    private var reinvestmentControlDisabled: Bool {
        effectiveEditorStrategy == .minimumsOnly || tempBaselineBudgetSourceRaw == "recurringNet"
    }

    private var budgetFieldIsEditable: Bool {
        effectiveEditorStrategy != .minimumsOnly && tempBaselineBudgetSourceRaw == "fixed"
    }

    private var discretionaryReserveFieldIsEditable: Bool {
        tempBaselineBudgetSourceRaw == "recurringNet"
    }

    private var budgetFieldTitle: String {
        if effectiveEditorStrategy == .minimumsOnly {
            return "Minimum Debt Payment"
        }
        return tempBaselineBudgetSourceRaw == "recurringNet" ? "Cash Available This Month" : "Debt Payment Budget"
    }

    private var budgetFieldHint: String {
        if effectiveEditorStrategy == .minimumsOnly {
            return "required minimums"
        }
        return tempBaselineBudgetSourceRaw == "recurringNet"
            ? "after bills and adjustments"
            : "for snowball and avalanche"
    }

    private func rememberCurrentFixedBudgetIfNeeded() {
        guard tempBaselineBudgetSourceRaw == "fixed",
              let currentFixed = parseCurrencyInput(tempMonthlyBudget),
              currentFixed >= 0 else { return }
        lastFixedDebtBudgetAmount = NSDecimalNumber(decimal: currentFixed).doubleValue
    }

    private func syncDisplayedBudgetForCurrentMode() {
        if effectiveEditorStrategy == .minimumsOnly {
            tempMonthlyBudget = formatAmount(feasibilityForTempPlan().minimums)
        } else if tempBaselineBudgetSourceRaw == "recurringNet" {
            tempMonthlyBudget = formatAmount(recurringNetAvailableForTempPlan())
        } else {
            let restored = lastFixedDebtBudgetAmount > 0
                ? NSDecimalNumber(value: lastFixedDebtBudgetAmount).decimalValue
                : Decimal(0)
            tempMonthlyBudget = formatAmount(restored)
        }
    }

    private var embeddedPlannerHeight: CGFloat {
        guard embeddedInNavigation else { return 0 }

        var height: CGFloat = 1800
        if tempStrategy != .minimumsOnly {
            height += 220
        }
        if showBudgetingHint {
            height += 220
        }
        return height
    }

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

    private var monthSymbols: [String] {
        DateFormatter().monthSymbols
    }

    private var shortMonthSymbols: [String] {
        DateFormatter().shortMonthSymbols
    }

    private var selectedPlanMonthTitle: String {
        let index = max(0, min(selectedPlanMonth - 1, shortMonthSymbols.count - 1))
        return shortMonthSymbols[index]
    }

    private var availablePlanYears: [Int] {
        let currentYear = Calendar.current.component(.year, from: Date())
        return Array((currentYear - 1)...(currentYear + 10))
    }

    private var selectedPlanMonth: Int {
        get { Calendar.current.component(.month, from: tempPlanDate) }
        set {
            updatePlanMonthYear(month: newValue, year: selectedPlanYear)
        }
    }

    private var selectedPlanYear: Int {
        get { Calendar.current.component(.year, from: tempPlanDate) }
        set {
            updatePlanMonthYear(month: selectedPlanMonth, year: newValue)
        }
    }

    private func updatePlanMonthYear(month: Int, year: Int) {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = 1
        let newDate = Calendar.current.date(from: components) ?? tempPlanDate
        tempPlanDate = newDate
        let currentMonth = normalizeToMonth(Date())
        tempPlanMode = Calendar.current.isDate(newDate, equalTo: currentMonth, toGranularity: .month)
            ? .currentInputs
            : .projectedAtDate
        syncDiscretionaryReserveForFixedBudgetIfNeeded()
        autoApplyEmbeddedPlanIfPossible()
    }

    private func allCashFlowItems() -> [CashFlowItem] {
        do { return try modelContext.fetch(FetchDescriptor<CashFlowItem>()) } catch { return [] }
    }

    private func allBillFundingAllocations() -> [BillFundingAllocation] {
        do { return try modelContext.fetch(FetchDescriptor<BillFundingAllocation>()) } catch { return [] }
    }

    private func budgetSchedule(start: Date, months: Int, baselineOverride: IncomeScheduler.BaselineSource? = nil) -> [Date: Decimal] {
        let items = allCashFlowItems()
        return IncomeScheduler.budgetByMonth(
            items: items,
            start: start,
            months: months,
            includeSpreads: tempIncludeNonMonthlyIncomeSpreads,
            oneTimeDefaultSpreadMonths: sanitizedDefaultSpread(tempOneTimeIncomeDefaultSpreadMonths),
            baselineSource: baselineOverride ?? baselineSource,
            incomeFundingAllocations: incomeFundingAllocationTotals(from: allBillFundingAllocations())
        )
    }

    private func recurringNetAvailableForTempPlan() -> Decimal {
        let startMonth = normalizeToMonth(tempPlanMode == .projectedAtDate ? tempPlanDate : Date())
        let schedule = budgetSchedule(start: startMonth, months: 12, baselineOverride: .recurringNet)
        return schedule[startMonth] ?? 0
    }

    private func fixedBudgetExcessForTempPlan(parsedBudget: Decimal? = nil) -> Decimal {
        guard tempStrategy != .minimumsOnly, tempBaselineBudgetSourceRaw == "fixed" else { return 0 }
        let budget = parsedBudget ?? parseCurrencyInput(tempMonthlyBudget)
        guard let budget else { return 0 }
        return max(0, budget - recurringNetAvailableForTempPlan())
    }

    private func availableAfterBillsAndLoansForTempPlan(parsedBudget: Decimal? = nil) -> Decimal {
        let availableCash = recurringNetAvailableForTempPlan()
        if tempStrategy == .minimumsOnly {
            return max(0, availableCash - feasibilityForTempPlan().minimums)
        }
        if tempBaselineBudgetSourceRaw == "fixed" {
            let budget = parsedBudget ?? parseCurrencyInput(tempMonthlyBudget)
            guard let budget else { return 0 }
            return max(0, availableCash - budget)
        }
        let plannedDebtPayment = currentPlan?.months.first?.payments.values.reduce(0, +) ?? 0
        return max(0, availableCash - plannedDebtPayment)
    }

    private func syncDiscretionaryReserveForFixedBudgetIfNeeded() {
        guard tempBaselineBudgetSourceRaw == "fixed" else { return }
        tempDiscretionaryReserve = formatAmount(availableAfterBillsAndLoansForTempPlan())
    }

    private var discretionaryReserveAmount: Decimal {
        let trimmed = tempDiscretionaryReserve.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let amount = parseCurrencyInput(trimmed),
              amount > 0 else { return 0 }
        return amount
    }

    private func isRecurringIncomeForPlan(_ frequency: PaymentFrequency) -> Bool {
        switch frequency.normalized {
        case .monthly, .semimonthly, .biweekly, .weekly, .socialSecurity:
            return true
        default:
            return false
        }
    }

    private func isRecurringBillForPlan(_ frequency: PaymentFrequency) -> Bool {
        switch frequency.normalized {
        case .monthly, .semimonthly, .biweekly, .weekly, .socialSecurity:
            return true
        default:
            return false
        }
    }

    private var recurringMonthlyIncomeForPlan: Decimal {
        allCashFlowItems()
            .filter { $0.kind == .income && isRecurringIncomeForPlan($0.frequency) }
            .reduce(0) { $0 + ($1.amount * $1.frequency.monthlyEquivalentFactor) }
    }

    private var recurringMonthlyBillsForPlan: Decimal {
        allCashFlowItems()
            .filter { $0.kind == .bill && isRecurringBillForPlan($0.frequency) }
            .reduce(0) { $0 + ($1.amount * $1.frequency.monthlyEquivalentFactor) }
    }

    private func nonMonthlyAdjustmentBreakdown(for startMonth: Date) -> NonMonthlyAdjustmentBreakdown {
        guard tempIncludeNonMonthlyIncomeSpreads else {
            return NonMonthlyAdjustmentBreakdown(incomeSetAside: 0, billReserve: 0, netAdjustment: 0)
        }
        let items = allCashFlowItems()
        let incomeFunding = incomeFundingAllocationTotals(from: allBillFundingAllocations())
        let spreadMonths = sanitizedDefaultSpread(tempOneTimeIncomeDefaultSpreadMonths)
        let incomeSpread = IncomeScheduler.spreadsByMonth(
            incomes: items,
            start: startMonth,
            months: 12,
            oneTimeDefaultSpreadMonths: spreadMonths,
            incomeFundingAllocations: incomeFunding
        )[startMonth] ?? 0
        let billSpread = IncomeScheduler.billSpreadsByMonth(
            bills: items.filter { $0.kind == .bill },
            start: startMonth,
            months: 12,
            defaultSpreadMonths: spreadMonths
        )[startMonth] ?? 0
        let billReserve = max(0, -billSpread)
        return NonMonthlyAdjustmentBreakdown(
            incomeSetAside: incomeSpread,
            billReserve: billReserve,
            netAdjustment: incomeSpread - billReserve
        )
    }

    private func feasibilityForTempPlan() -> (available: Decimal, minimums: Decimal, shortfall: Decimal) {
        let startMonth = normalizeToMonth(tempPlanMode == .projectedAtDate ? tempPlanDate : Date())
        let schedule = budgetSchedule(start: startMonth, months: 12, baselineOverride: tempBaselineSource())
        let availableCashThisMonth = schedule[startMonth] ?? 0
        let availableThisMonth = tempBaselineBudgetSourceRaw == "recurringNet"
            ? PlanBudgetDisplay.availableForDebt(
                availableCash: availableCashThisMonth,
                discretionaryReserve: discretionaryReserveAmount
            )
            : availableCashThisMonth
        let shouldProjectBalances = usesProjectedBalances(mode: tempPlanMode, date: tempPlanDate)
        let filteredAccounts = accounts.filter { acct in
            let baseBal = absDecimal(latestBalance(acct))
            let bal = shouldProjectBalances
                ? absProjectedOrBase(for: acct, planDate: startMonth, base: baseBal)
                : baseBal
            return bal > 0
        }
        let minimumsTotal: Decimal = filteredAccounts.reduce(0) { acc, acct in
            let baseBal = absDecimal(latestBalance(acct))
            let bal = shouldProjectBalances
                ? absProjectedOrBase(for: acct, planDate: startMonth, base: baseBal)
                : baseBal
            return acc + monthlyPayment(for: acct, balance: bal)
        }
        let shortfall = max(0, (minimumsTotal - availableThisMonth))
        return (availableThisMonth, minimumsTotal, shortfall)
    }

    private var monthYearPickerGroup: some View {
        HStack(spacing: 5) {
            Text("Month / Year: ")

            Menu {
                ForEach(Array(monthSymbols.enumerated()), id: \.offset) { index, month in
                    Button(month) {
                        updatePlanMonthYear(month: index + 1, year: selectedPlanYear)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(selectedPlanMonthTitle)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }
            .menuOrder(.fixed)

            Text("/")
                .foregroundStyle(.secondary)

            Menu {
                ForEach(availablePlanYears, id: \.self) { year in
                    Button(String(year)) {
                        updatePlanMonthYear(month: selectedPlanMonth, year: year)
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(String(selectedPlanYear))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }
            .menuOrder(.fixed)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var startModePicker: some View {
        Picker("Start mode", selection: $tempPlanMode) {
            Text("Now").tag(PlanMode.currentInputs)
            Text("Planned").tag(PlanMode.projectedAtDate)
        }
        .pickerStyle(.segmented)
        .onChange(of: tempPlanMode) { _, newValue in
            if newValue == .currentInputs { tempPlanDate = Date() }
            syncDiscretionaryReserveForFixedBudgetIfNeeded()
            autoApplyEmbeddedPlanIfPossible()
        }
    }

    private func inlinePlanLabel(title: String, hint: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .lineLimit(1)
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(nil)
                Text(hint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
            }
        }
    }

    private var discretionaryReserveInput: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            inlinePlanLabel(
                title: discretionaryReserveFieldIsEditable ? "Hold Back Cash" : "Cash Left After Debt",
                hint: discretionaryReserveFieldIsEditable
                    ? "Reduces the cash sent to debt payoff"
                    : "Amount left after debt"
            )
            .layoutPriority(1)

            Spacer(minLength: 12)

            TextField("$0.00", text: $tempDiscretionaryReserve)
                .multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation)
                .focused($focusedField, equals: .discretionaryReserve)
                .selectAllOnFocus()
                .submitLabel(.done)
                .onSubmit { commitAndDismissKeyboard() }
                .onChange(of: tempDiscretionaryReserve) { _, _ in
                    autoApplyEmbeddedPlanIfPossible()
                }
                .disabled(!discretionaryReserveFieldIsEditable)
                .opacity(discretionaryReserveFieldIsEditable ? 1 : 0.45)
                .frame(minWidth: 120, maxWidth: 180, alignment: .trailing)
        }
        .id("discretionaryReserveField")
    }

    private func embeddedSection<Content: View, Footer: View>(
        _ title: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            footer()
                .font(.footnote)
                .foregroundStyle(.primary.opacity(0.75))
                .padding(.horizontal, 16)
        }
    }

    private func embeddedSection<Content: View>(
        _ title: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        embeddedSection(title, content: content) { EmptyView() }
    }

    @ViewBuilder
    private var manageIncomeBillsControl: some View {
        if let onManageIncomeBills {
            Button("Manage Income & Bills", action: onManageIncomeBills)
        } else {
            NavigationLink("Manage Income & Bills") { IncomeAndBillsView() }
        }
    }

    @ViewBuilder
    private var embeddedPlanEditorContent: some View {
        let showLandscapeHint = shouldShowPlanLandscapeHint
        VStack(alignment: .leading, spacing: 16) {
            embeddedSection {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        monthYearPickerGroup
                        Text("choose the starting month (always the 1st)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        startModePicker
                            .frame(width: 180)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        monthYearPickerGroup
                        Text("choose the starting month (always the 1st)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        startModePicker
                    }
                }
            } footer: {
                EmptyView()
            }
            .id("planEditorTop")

            embeddedSection("Payoff Plan") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    inlinePlanLabel(title: budgetFieldTitle, hint: budgetFieldHint)
                        .layoutPriority(1)

                    Spacer(minLength: 12)

                    TextField("$0.00", text: $tempMonthlyBudget)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($focusedField, equals: .monthlyBudget)
                        .selectAllOnFocus()
                        .submitLabel(.done)
                        .onSubmit { commitAndDismissKeyboard() }
                        .onChange(of: tempMonthlyBudget) { _, newValue in
                            if budgetFieldIsEditable,
                               let currentFixed = parseCurrencyInput(newValue),
                               currentFixed >= 0 {
                                lastFixedDebtBudgetAmount = NSDecimalNumber(decimal: currentFixed).doubleValue
                            }
                            autoApplyEmbeddedPlanIfPossible()
                        }
                        .disabled(!budgetFieldIsEditable)
                        .opacity(budgetFieldIsEditable ? 1 : 0.45)
                        .frame(minWidth: 120, maxWidth: 180, alignment: .trailing)
                }
                .id("monthlyBudgetField")

                discretionaryReserveInput

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Reinvest paid-off payments")
                        Spacer()
                        Text(tempDebtPaymentReinvestmentRate, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $tempDebtPaymentReinvestmentRate, in: 0...1, step: 0.05)
                        .onChange(of: tempDebtPaymentReinvestmentRate) { _, _ in
                            autoApplyEmbeddedPlanIfPossible()
                        }
                }
                .disabled(reinvestmentControlDisabled)
                .opacity(reinvestmentControlDisabled ? 0.45 : 1)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let error = budgetValidationError {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }

            embeddedSection("Budget Source & Spreads") {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Budget source", selection: $tempBaselineBudgetSourceRaw) {
                        Text("Use available cash").tag("recurringNet")
                        Text("Set debt budget").tag("fixed")
                    }

                }
                .pickerStyle(.segmented)
                .onChange(of: tempBaselineBudgetSourceRaw) { _, newValue in
                    if newValue == "recurringNet" {
                        rememberCurrentFixedBudgetIfNeeded()
                    }
                    syncDisplayedBudgetForCurrentMode()
                    syncDiscretionaryReserveForFixedBudgetIfNeeded()
                    autoApplyEmbeddedPlanIfPossible()
                }

                DisclosureGroup(isExpanded: $showBudgetingHint) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Use Available Cash")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Uses cash available after bills and non-monthly adjustments. Enter Hold Back Cash if you do not want all available cash sent to debt.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider()
                        Text("Set Debt Budget")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Uses one debt payment budget for snowball and avalanche. Cash left after that budget is calculated for you.")
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
                    .onChange(of: tempIncludeNonMonthlyIncomeSpreads) { _, _ in
                        autoApplyEmbeddedPlanIfPossible()
                    }
                Picker("Default spread for one-time income", selection: $tempOneTimeIncomeDefaultSpreadMonths) {
                    Text("3 months").tag(3)
                    Text("6 months").tag(6)
                    Text("12 months").tag(12)
                }
                .pickerStyle(.segmented)
                .onChange(of: tempOneTimeIncomeDefaultSpreadMonths) { _, _ in
                    autoApplyEmbeddedPlanIfPossible()
                }
            } footer: {
                Text("The above spread applies to non-monthly incomes/bills (e.g., yearly) set to 'Default' when created. If set to something other than 'Default', they will not be affected.")
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            embeddedSection("Budget to Paydown Debt Over Time") {
                let startMonth = normalizeToMonth(tempPlanMode == .projectedAtDate ? tempPlanDate : Date())
                let schedule = budgetSchedule(start: startMonth, months: 12, baselineOverride: tempBaselineSource())
                BudgetTimelinePreviewView(startMonth: startMonth, schedule: schedule)
                    .environmentObject(settings)
                    .id("embedded-sched-\(includeNonMonthlyIncomeSpreads)-\(oneTimeIncomeDefaultSpreadMonths)-\(baselineBudgetSourceRaw)-\(startMonth.timeIntervalSince1970)")
            }

            embeddedSection("Explain my plan") {
                let startMonth = normalizeToMonth(tempPlanMode == .projectedAtDate ? tempPlanDate : Date())
                let schedule = budgetSchedule(start: startMonth, months: 12, baselineOverride: tempBaselineSource())
                DisclosureGroup {
                    let items = allCashFlowItems()
                    let rawExplainContributions = IncomeScheduler.contributionsByMonth(items: items, start: startMonth, months: 12, oneTimeDefaultSpreadMonths: sanitizedDefaultSpread(oneTimeIncomeDefaultSpreadMonths), incomeFundingAllocations: incomeFundingAllocationTotals(from: allBillFundingAllocations()))
                    let explainContributions: [Date: [ExplainPlanView.ContributionRow]] = Dictionary(uniqueKeysWithValues: rawExplainContributions.map { (date, rows) in (date, rows.map { r in ExplainPlanView.ContributionRow(name: r.name, amount: r.amount) }) })
                    let rawBillContributions = IncomeScheduler.billContributionsByMonth(items: items, start: startMonth, months: 12, defaultSpreadMonths: sanitizedDefaultSpread(oneTimeIncomeDefaultSpreadMonths))
                    let explainBillContributions: [Date: [ExplainPlanView.ContributionRow]] = Dictionary(uniqueKeysWithValues: rawBillContributions.map { (date, rows) in (date, rows.map { r in ExplainPlanView.ContributionRow(name: r.name, amount: r.amount) }) })
                    ExplainPlanView(startMonth: startMonth, contributions: explainContributions, billContributions: explainBillContributions, monthlyBudgetByMonth: schedule)
                        .environmentObject(settings)
                } label: {
                    if showLandscapeHint {
                        HStack {
                            Text("Plan by Month")
                            Label("Rotate iPhone", systemImage: "rotate.left.fill")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    } else {
                        Text("Plan by Month")
                    }
                }
            } footer: {
                Text("Shows which variable incomes/bills contribute to which months. Spreads begin the month after a pay date; remainders apply to the last month.")
            }

            if tempStrategy != .minimumsOnly {
                embeddedSection("Feasibility") {
                    currentPlanMathRows
                }
                .id("feasibility-section")
            }

            embeddedSection("Income & Bills") {
                incomeBillsMathRows
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .onChange(of: focusedField) { _, newValue in
            NotificationCenter.default.post(
                name: .debtSummaryEmbeddedPlannerEditingChanged,
                object: newValue != nil
            )
        }
    }

    @ViewBuilder
    private var planEditorContent: some View {
        let showLandscapeHint = shouldShowPlanLandscapeHint
        ScrollViewReader { proxy in
                List {
                        Section {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 12) {
                                    monthYearPickerGroup
                                    Spacer(minLength: 12)
                                    startModePicker
                                        .frame(width: 180)
                                }

                                VStack(alignment: .leading, spacing: 10) {
                                    monthYearPickerGroup
                                    startModePicker
                                }
                            }
                        } footer: {
                            Text("Choose the month your strategy starts. Plans always begin on the first day of the selected month.")
                                .font(.footnote)
                                .foregroundStyle(.primary.opacity(0.75))
                        }
                        .id("planEditorTop")
                        Section {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(budgetFieldTitle)
                                        .lineLimit(nil)
                                    Text(budgetFieldHint)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(nil)
                                }
                                .layoutPriority(1)

                                Spacer(minLength: 12)

                                TextField("$0.00", text: $tempMonthlyBudget)
                                    .multilineTextAlignment(.trailing)
                                    .keyboardType(.numbersAndPunctuation)
                                    .focused($focusedField, equals: .monthlyBudget)
                                    .selectAllOnFocus()
                                    .submitLabel(.done)
                                    .onSubmit { commitAndDismissKeyboard() }
                                    .onChange(of: tempMonthlyBudget) { _, newValue in
                                        if budgetFieldIsEditable,
                                           let currentFixed = parseCurrencyInput(newValue),
                                           currentFixed >= 0 {
                                            lastFixedDebtBudgetAmount = NSDecimalNumber(decimal: currentFixed).doubleValue
                                        }
                                        syncDiscretionaryReserveForFixedBudgetIfNeeded()
                                        autoApplyEmbeddedPlanIfPossible()
                                    }
                                    .disabled(!budgetFieldIsEditable)
                                    .opacity(budgetFieldIsEditable ? 1 : 0.45)
                                    .frame(minWidth: 120, maxWidth: 180, alignment: .trailing)
                            }
                            .id("monthlyBudgetField")

                            discretionaryReserveInput

                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Reinvest paid-off payments")
                                    Spacer()
                                    Text(tempDebtPaymentReinvestmentRate, format: .percent.precision(.fractionLength(0)))
                                        .foregroundStyle(.secondary)
                                }
                                Slider(value: $tempDebtPaymentReinvestmentRate, in: 0...1, step: 0.05)
                                    .onChange(of: tempDebtPaymentReinvestmentRate) { _, _ in
                                        autoApplyEmbeddedPlanIfPossible()
                                    }
                            }
                            .disabled(tempStrategy == .minimumsOnly || tempBaselineBudgetSourceRaw == "recurringNet")
                            .opacity((tempStrategy == .minimumsOnly || tempBaselineBudgetSourceRaw == "recurringNet") ? 0.45 : 1)
                        } header: {
                            Text("Payoff Plan")
                        } footer: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Your total monthly budget for debt payments. Leave empty if you use Minimums Only strategy or Reoccurring Net.")
                                    .font(.footnote)
                                    .foregroundStyle(.primary.opacity(0.75))
                                if embeddedInNavigation {
                                    Text("Changes apply immediately as you edit this plan.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                if let error = budgetValidationError {
                                    Text(error).font(.footnote).foregroundStyle(.red)
                                }
                            }
                        }

                        Section {
                            Picker("Budget source", selection: $tempBaselineBudgetSourceRaw) {
                                Text("Use available cash").tag("recurringNet")
                                Text("Set debt budget").tag("fixed")
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: tempBaselineBudgetSourceRaw) { _, newValue in
                                if newValue == "recurringNet" {
                                    rememberCurrentFixedBudgetIfNeeded()
                                }
                                syncDisplayedBudgetForCurrentMode()
                                syncDiscretionaryReserveForFixedBudgetIfNeeded()
                                autoApplyEmbeddedPlanIfPossible()
                            }
                            // Budgeting hint disclosure
                            DisclosureGroup(isExpanded: $showBudgetingHint) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Use Available Cash")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text("Uses cash available after bills and non-monthly adjustments. Enter Hold Back Cash if you do not want all available cash sent to debt.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Divider()
                                    Text("Set Debt Budget")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text("Uses one debt payment budget for snowball and avalanche. Cash left after that budget is calculated for you.")
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
                                .onChange(of: tempIncludeNonMonthlyIncomeSpreads) { _, _ in
                                    syncDiscretionaryReserveForFixedBudgetIfNeeded()
                                    autoApplyEmbeddedPlanIfPossible()
                                }
                            Picker("Default spread for one-time income", selection: $tempOneTimeIncomeDefaultSpreadMonths) {
                                Text("3 months").tag(3)
                                Text("6 months").tag(6)
                                Text("12 months").tag(12)
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: tempOneTimeIncomeDefaultSpreadMonths) { _, _ in
                                syncDiscretionaryReserveForFixedBudgetIfNeeded()
                                autoApplyEmbeddedPlanIfPossible()
                            }
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
                                let rawExplainContributions = IncomeScheduler.contributionsByMonth(items: items, start: startMonth, months: 12, oneTimeDefaultSpreadMonths: sanitizedDefaultSpread(oneTimeIncomeDefaultSpreadMonths), incomeFundingAllocations: incomeFundingAllocationTotals(from: allBillFundingAllocations()))
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
                                            Label("Rotate iPhone", systemImage: "rotate.left.fill")
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
                            Section {
                                currentPlanMathRows
                            } header: { Text("Feasibility") }
                            .id("feasibility-section")
                        }

                        Section("Income & Bills") {
                            incomeBillsMathRows
                        }

                        if embeddedInNavigation {
                            Section {
                                Color.clear
                                    .frame(height: 146)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                    .listRowBackground(Color.clear)
                            }
                        }
                }
                .scrollDisabled(embeddedInNavigation)
                .frame(height: embeddedInNavigation ? embeddedPlannerHeight : nil)
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
                    } else {
                        EmptyView()
                    }
                }
                .onChange(of: focusedField) { _, newValue in
                    if embeddedInNavigation {
                        NotificationCenter.default.post(
                            name: .debtSummaryEmbeddedPlannerEditingChanged,
                            object: newValue != nil
                        )
                    }


                }
            }
    }

    var body: some View {
        Group {
            if embeddedInNavigation {
                embeddedPlanEditorContent
            } else {
                NavigationStack {
                    planEditorContent
                        .navigationTitle("Strategy start")
                        .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            // Prefill strategy from settings
            switch settings.defaultPayoffStrategyRaw {
            case "snowball": tempStrategy = .snowball
            case "avalanche": tempStrategy = .avalanche
            default: tempStrategy = .minimumsOnly
            }
            // Prefill budget with adjusted available cash if enabled.
            if settings.useNetForDebtBudgetDefault {
                let availableCash = recurringNetAvailableForTempPlan()
                if availableCash > 0 { tempMonthlyBudget = formatAmount(availableCash) }
            }
            let trimmed = tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines)
            if let d = parseCurrencyInput(trimmed) { tempMonthlyBudget = formatAmount(d) }

            // Prefill from saved fixed amount whenever available,
            // regardless of the useFixedDebtBudget flag state.
            if debtBudgetOverrideAmount > 0 {
                let saved = NSDecimalNumber(value: debtBudgetOverrideAmount).decimalValue
                tempMonthlyBudget = formatAmount(saved)
                lastFixedDebtBudgetAmount = debtBudgetOverrideAmount
            }

            if debtPlanStartModeRaw == "projectedAtDate" {
                tempPlanMode = .projectedAtDate
                if debtPlanStartDateEpoch > 0 {
                    tempPlanDate = Date(timeIntervalSince1970: debtPlanStartDateEpoch)
                }
            } else {
                tempPlanMode = .currentInputs
            }
            tempBaselineBudgetSourceRaw = baselineBudgetSourceRaw
            if useFixedDebtBudget, debtBudgetOverrideAmount > 0 {
                tempBaselineBudgetSourceRaw = "fixed"
                let saved = NSDecimalNumber(value: debtBudgetOverrideAmount).decimalValue
                tempMonthlyBudget = formatAmount(saved)
            } else if tempBaselineBudgetSourceRaw == "recurringNet" {
                let availableCash = recurringNetAvailableForTempPlan()
                tempMonthlyBudget = availableCash > 0 ? formatAmount(availableCash) : formatAmount(0)
            } else if lastFixedDebtBudgetAmount > 0 {
                let saved = NSDecimalNumber(value: lastFixedDebtBudgetAmount).decimalValue
                tempMonthlyBudget = formatAmount(saved)
            }
            tempIncludeNonMonthlyIncomeSpreads = includeNonMonthlyIncomeSpreads
            tempOneTimeIncomeDefaultSpreadMonths = oneTimeIncomeDefaultSpreadMonths
            tempDebtPaymentReinvestmentRate = debtPaymentReinvestmentRate
            if debtDiscretionaryReserveAmount > 0 {
                let savedReserve = NSDecimalNumber(value: debtDiscretionaryReserveAmount).decimalValue
                tempDiscretionaryReserve = formatAmount(savedReserve)
            } else {
                tempDiscretionaryReserve = ""
            }
            syncDisplayedBudgetForCurrentMode()
            syncDiscretionaryReserveForFixedBudgetIfNeeded()
        }
        .onChange(of: settings.defaultPayoffStrategyRaw) { _, newValue in
            guard embeddedInNavigation else { return }
            // Preserve a user-entered fixed amount only when the prior local strategy
            // was already using an editable fixed budget. Do not let a displayed
            // Minimums amount overwrite the remembered fixed amount during a switch.
            if tempStrategy != .minimumsOnly && tempBaselineBudgetSourceRaw == "fixed" {
                rememberCurrentFixedBudgetIfNeeded()
            }
            switch newValue {
            case "snowball": tempStrategy = .snowball
            case "avalanche": tempStrategy = .avalanche
            default: tempStrategy = .minimumsOnly
            }
            syncDisplayedBudgetForCurrentMode()
            syncDiscretionaryReserveForFixedBudgetIfNeeded()
        }
        .toolbar {
            if !embeddedInNavigation {
                ToolbarItem(placement: .confirmationAction) {
                    let feas = feasibilityForTempPlan()
                    let isInfeasible = (tempStrategy != .minimumsOnly) && (feas.shortfall > 0)
                    PlanToolbarButton("Set Plan") {
                        applyPlanSettings()
                    }
                    .disabled(isInfeasible)
                }
                ToolbarItem(placement: .cancellationAction) {
                    PlanToolbarButton("Cancel", fixedWidth: 70) { dismiss() }
                }
            }
        }
        .alert("Can't set plan", isPresented: $showPlanErrorAlert) { Button("OK", role: .cancel) { } } message: { Text(planErrorMessage ?? "") }
        .onChange(of: focusedField) { _, newValue in
            guard newValue == .discretionaryReserve, discretionaryReserveFieldIsEditable else { return }
            selectFocusedTextInput()
        }
        .onReceive(NotificationCenter.default.publisher(for: .debtSummaryEmbeddedPlannerCommitKeyboard)) { _ in
            guard embeddedInNavigation else { return }
            commitAndDismissKeyboard()
        }
        .safeAreaInset(edge: .bottom) {
            Group {
                if !embeddedInNavigation && isEditing {
                    EditingAccessoryBar(
                        canGoPrevious: false,
                        canGoNext: false,
                        onPrevious: { },
                        onNext: { },
                        onDone: { commitAndDismissKeyboard() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    EmptyView().frame(height: 0)
                }
            }
            .animation(.snappy, value: isEditing)
        }
        .onDisappear {
            if embeddedInNavigation {
                NotificationCenter.default.post(name: .debtSummaryEmbeddedPlannerEditingChanged, object: false)
            }
        }
        .task { await loadAccounts() }
        .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { _ in
            accounts = []
            currentPlan = nil
            Task { await loadAccounts() }
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

    private func formatSignedAmount(_ amount: Decimal) -> String {
        if amount > 0 { return "+\(formatAmount(amount))" }
        if amount < 0 { return "-\(formatAmount(-amount))" }
        return formatAmount(amount)
    }

    @ViewBuilder
    private func expandableAmountRow<Details: View>(
        _ title: String,
        value: Decimal,
        valueColor: Color = .primary,
        @ViewBuilder details: @escaping () -> Details
    ) -> some View {
        let isExpanded = expandedAmountRows.contains(title)

        VStack(alignment: .leading, spacing: 6) {
            Button {
                if isExpanded {
                    expandedAmountRows.remove(title)
                } else {
                    expandedAmountRows.insert(title)
                }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    HStack(spacing: 4) {
                        Text(title)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formatAmount(value))
                        .foregroundStyle(valueColor)
                        .monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    details()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
                .padding(.leading, 14)
            }
        }
    }

    private func formulaRow(_ label: String, amount: Decimal, signed: Bool = false) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(signed ? formatSignedAmount(amount) : formatAmount(amount))
                .monospacedDigit()
        }
    }

    private struct FutureReserveStatus {
        let month: Date
        let discretionaryRemaining: Decimal
        let reserveGap: Decimal
    }

    private struct NextPayoffImpact {
        let date: Date
        let accountNames: [String]
        let discretionaryIncrease: Decimal
        let futureReserveStatus: FutureReserveStatus?
    }

    private func previewPlanForTempSettings(startMonth: Date) -> DebtPlanResult? {
        let parsedBudget: Decimal? = {
            if tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return parseCurrencyInput(tempMonthlyBudget)
        }()
        guard tempStrategy == .minimumsOnly || parsedBudget != nil else { return nil }
        guard feasibilityForTempPlan().shortfall == 0 else { return nil }

        let shouldProjectBalances = usesProjectedBalances(mode: tempPlanMode, date: tempPlanDate)
        let debts: [DebtInput] = accounts.compactMap { account in
            let baseBalance = absDecimal(latestBalance(account))
            let balance = shouldProjectBalances
                ? absProjectedOrBase(for: account, planDate: startMonth, base: baseBalance)
                : baseBalance
            guard balance > 0 else { return nil }
            return DebtInput(
                id: account.id,
                name: account.name,
                apr: account.loanTerms?.apr,
                balance: balance,
                minPayment: monthlyPayment(for: account, balance: balance)
            )
        }
        guard !debts.isEmpty else { return nil }

        let availableCashSchedule = budgetSchedule(start: startMonth, months: 600, baselineOverride: tempBaselineSource())
        let schedule = PlanBudgetDisplay.reserveAdjustedBudgetSchedule(
            availableCashSchedule,
            discretionaryReserve: discretionaryReserveAmount,
            appliesReserve: tempBaselineBudgetSourceRaw == "recurringNet"
        )

        do {
            if tempIncludeNonMonthlyIncomeSpreads || tempBaselineBudgetSourceRaw == "recurringNet" {
                return try DebtPayoffEngine.plan(
                    debts: debts,
                    budgetByMonth: schedule,
                    strategy: tempStrategy,
                    reinvestmentRate: Decimal(tempDebtPaymentReinvestmentRate),
                    startDate: startMonth
                )
            } else {
                let budgetToUse = parsedBudget ?? debts.reduce(0) { $0 + $1.minPayment }
                return try DebtPayoffEngine.plan(
                    debts: debts,
                    monthlyBudget: budgetToUse,
                    strategy: tempStrategy,
                    reinvestmentRate: Decimal(tempDebtPaymentReinvestmentRate),
                    startDate: startMonth
                )
            }
        } catch {
            return nil
        }
    }

    private func nextPayoffImpact(for plan: DebtPlanResult?, startMonth: Date) -> NextPayoffImpact? {
        guard let plan else { return nil }
        let calendar = Calendar.current
        let normalizedStartMonth = normalizeToMonth(startMonth)
        let payoffDatesByAccount = plan.payoffDates.reduce(into: [UUID: Date]()) { result, item in
            result[item.key] = normalizeToMonth(item.value)
        }
        guard let nextPayoffMonth = payoffDatesByAccount.values
            .filter({ $0 >= normalizedStartMonth })
            .sorted()
            .first else {
            return nil
        }

        let paidOffAccountIDs = payoffDatesByAccount
            .filter { calendar.isDate($0.value, equalTo: nextPayoffMonth, toGranularity: .month) }
            .map(\.key)
        let paidOffAccounts = accounts.filter { paidOffAccountIDs.contains($0.id) }
        let payoffMonthIndex = plan.months.firstIndex { calendar.isDate($0.date, equalTo: nextPayoffMonth, toGranularity: .month) }
        let releasedPayments = paidOffAccountIDs.reduce(Decimal(0)) { total, accountID in
            let payoffMonthPayment = payoffMonthIndex.map { plan.months[$0].payments[accountID] ?? 0 } ?? 0
            let previousPayment = payoffMonthIndex.flatMap { index in
                index > 0 ? plan.months[index - 1].payments[accountID] : nil
            } ?? 0
            return total + max(payoffMonthPayment, previousPayment).rounded(2)
        }
        let reinvestmentRate = Decimal(tempDebtPaymentReinvestmentRate)
        let discretionaryIncrease = (releasedPayments * (1 - reinvestmentRate)).rounded(2)
        let futureReserveStatus: FutureReserveStatus? = {
            guard let monthAfterPayoff = calendar.date(byAdding: .month, value: 1, to: nextPayoffMonth),
                  let futurePlanMonth = plan.months.first(where: { calendar.isDate($0.date, equalTo: monthAfterPayoff, toGranularity: .month) }) else {
                return nil
            }
            let futureMonth = normalizeToMonth(monthAfterPayoff)
            let futureCashSchedule = budgetSchedule(start: startMonth, months: max(2, plan.months.count + 1), baselineOverride: .recurringNet)
            let futureAvailableCash = futureCashSchedule[futureMonth] ?? 0
            let futureDebtPayment = futurePlanMonth.payments.values.reduce(0, +)
            let futureDiscretionaryRemaining = (futureAvailableCash - futureDebtPayment).rounded(2)
            let futureReserveGap = PlanBudgetDisplay.reserveGap(
                discretionaryReserve: discretionaryReserveAmount,
                discretionaryRemaining: futureDiscretionaryRemaining
            ).rounded(2)
            return FutureReserveStatus(
                month: futureMonth,
                discretionaryRemaining: futureDiscretionaryRemaining,
                reserveGap: futureReserveGap
            )
        }()
        let accountNames = paidOffAccounts
            .map(\.name)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        return NextPayoffImpact(
            date: nextPayoffMonth,
            accountNames: accountNames,
            discretionaryIncrease: discretionaryIncrease,
            futureReserveStatus: futureReserveStatus
        )
    }

    @ViewBuilder
    private var currentPlanMathRows: some View {
        let startMonth = normalizeToMonth(tempPlanMode == .projectedAtDate ? tempPlanDate : Date())
        let feas = feasibilityForTempPlan()
        let isInfeasible = feas.shortfall > 0
        let fixedBudgetExcess = fixedBudgetExcessForTempPlan()
        let fixedBudget = parseCurrencyInput(tempMonthlyBudget) ?? 0
        let availableCash = recurringNetAvailableForTempPlan()
        let discretionaryReserve = discretionaryReserveAmount
        let breakdown = nonMonthlyAdjustmentBreakdown(for: startMonth)
        let availableForDebt = tempBaselineBudgetSourceRaw == "recurringNet"
            ? PlanBudgetDisplay.availableForDebt(availableCash: availableCash, discretionaryReserve: discretionaryReserve)
            : feas.available
        let plannedDebtPayment = currentPlan?.months.first?.payments.values.reduce(0, +) ?? availableForDebt
        let discretionaryRemaining = availableCash - plannedDebtPayment
        let reserveGap = PlanBudgetDisplay.reserveGap(
            discretionaryReserve: discretionaryReserve,
            discretionaryRemaining: discretionaryRemaining
        )
        let planAdjustment = tempBaselineBudgetSourceRaw == "fixed"
            ? feas.available - fixedBudget
            : availableCash - recurringMonthlyIncomeForPlan + recurringMonthlyBillsForPlan
        let previewPlan = previewPlanForTempSettings(startMonth: startMonth)
        let nextPayoffImpact = nextPayoffImpact(for: previewPlan, startMonth: startMonth)
            ?? nextPayoffImpact(for: currentPlan, startMonth: startMonth)
        let hasPayoffPlan = currentPlan != nil || previewPlan != nil
        let planSummary: String = {
            if tempPlanMode == .projectedAtDate {
                return "Start on \(tempPlanDate.formatted(date: .abbreviated, time: .omitted)) • \(tempStrategyDisplay)\(tempBudgetText)"
            } else {
                return "Start now • \(tempStrategyDisplay)\(tempBudgetText)"
            }
        }()

        LabeledContent("Current Plan") {
            Text(planSummary)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        if isInfeasible {
            Text("Budget is not enough to cover minimum payments this month.")
                .font(.callout)
                .bold()
                .foregroundStyle(.red)
        } else {
            Text("Budget covers minimum payments this month.")
                .font(.callout)
                .bold()
        }

        if tempBaselineBudgetSourceRaw == "fixed" {
            LabeledContent("Debt Payment Budget") { Text(formatAmount(fixedBudget)) }
        }

        expandableAmountRow(tempBaselineBudgetSourceRaw == "recurringNet" ? "Hold Back Cash" : "Cash Left After Debt", value: discretionaryReserve) {
            Text(tempBaselineBudgetSourceRaw == "recurringNet"
                 ? "Cash kept out of the debt payoff budget."
                 : "Cash available after the fixed debt payment budget.")
        }

        expandableAmountRow("Net Non-Monthly Adjustment", value: planAdjustment) {
            formulaRow("Income Set Aside", amount: breakdown.incomeSetAside, signed: true)
            formulaRow("Bill Reserve", amount: -breakdown.billReserve, signed: true)
            let remaining = planAdjustment - breakdown.netAdjustment
            if remaining != 0 {
                formulaRow("Schedule Difference", amount: remaining, signed: true)
            }
            Text("Income Set Aside minus Bill Reserve for this plan month.")
        }

        expandableAmountRow("Debt Budget This Month", value: availableForDebt) {
            formulaRow(tempBaselineBudgetSourceRaw == "fixed" ? "Debt Payment Budget" : "Cash Available This Month", amount: tempBaselineBudgetSourceRaw == "fixed" ? fixedBudget : availableCash)
            if tempBaselineBudgetSourceRaw == "recurringNet" {
                formulaRow("Hold Back Cash", amount: -discretionaryReserve, signed: true)
            } else {
                formulaRow("Net Non-Monthly Adjustment", amount: planAdjustment, signed: true)
            }
            Text("This is the amount the payoff plan can use this month.")
        }

        if tempBaselineBudgetSourceRaw == "fixed" {
            expandableAmountRow("Available Cash This Month", value: availableCash) {
                let netForDebt = recurringMonthlyIncomeForPlan - recurringMonthlyBillsForPlan
                formulaRow("Recurring Cash After Bills", amount: netForDebt)
                formulaRow("Net Non-Monthly Adjustment", amount: breakdown.netAdjustment, signed: true)
                Text("This is what cash flow says is available before comparing it to the fixed budget.")
            }
        }

        expandableAmountRow("Minimums Due This Month", value: feas.minimums) {
            Text("System calculated: sum of required minimum payments on active debts this month.")
        }

        expandableAmountRow("Planned Debt Payment", value: plannedDebtPayment) {
            Text("Actual total debt payment assigned by the selected payoff plan this month.")
        }

        expandableAmountRow("Cash Left After Debt", value: discretionaryRemaining, valueColor: discretionaryRemaining < 0 ? .red : .primary) {
            formulaRow("Cash Available This Month", amount: availableCash)
            formulaRow("Planned Debt Payment", amount: -plannedDebtPayment, signed: true)
            Text("Cash left after the selected plan's actual debt payment.")
        }

        if reserveGap > 0 {
            expandableAmountRow("Below Holdback Target This Month", value: reserveGap, valueColor: .red) {
                formulaRow("Hold Back Cash", amount: discretionaryReserve)
                formulaRow("Cash Left After Debt", amount: discretionaryRemaining)
                Text("This is how far the selected plan leaves this month below the holdback target.")
            }
        }

        Text("Future Payoff Impact")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 8)

        if let nextPayoffImpact {
            if let futureReserveStatus = nextPayoffImpact.futureReserveStatus {
                LabeledContent("First Month After Payoff") {
                    Text(futureReserveStatus.month.formatted(.dateTime.month(.abbreviated).year()))
                }
                expandableAmountRow("Monthly Increase After Next Payoff", value: nextPayoffImpact.discretionaryIncrease) {
                    if !nextPayoffImpact.accountNames.isEmpty {
                        LabeledContent(nextPayoffImpact.accountNames.count == 1 ? "Paid-Off Account" : "Paid-Off Accounts") {
                            Text(nextPayoffImpact.accountNames.joined(separator: ", "))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    Text("Future monthly increase beginning in the first full month after the next payoff. This is separate from this month's reserve gap.")
                }
                expandableAmountRow(
                    "Projected Cash Left After Debt",
                    value: futureReserveStatus.discretionaryRemaining,
                    valueColor: futureReserveStatus.discretionaryRemaining < 0 ? .red : .primary
                ) {
                    Text("Projected cash left after the planned debt payment in the first full month after the next payoff.")
                }
                if futureReserveStatus.reserveGap > 0 {
                    expandableAmountRow("Projected Holdback Gap After Payoff", value: futureReserveStatus.reserveGap, valueColor: .red) {
                        formulaRow("Hold Back Cash", amount: discretionaryReserve)
                        formulaRow("Projected Cash Left After Debt", amount: futureReserveStatus.discretionaryRemaining)
                        Text("Projected gap in the first full month after the next payoff.")
                    }
                }
            } else {
                LabeledContent("First Month After Payoff") {
                    Text("No following month in plan")
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            LabeledContent("First Month After Payoff") {
                Text(hasPayoffPlan ? "No payoff in plan horizon" : "Unavailable")
                    .foregroundStyle(.secondary)
            }
        }

        if fixedBudgetExcess > 0 {
            expandableAmountRow("Debt Budget Over Available Cash", value: fixedBudgetExcess, valueColor: .red) {
                formulaRow("Debt Payment Budget", amount: fixedBudget)
                formulaRow("Cash Available This Month", amount: -availableCash, signed: true)
                Text("The debt payment budget is higher than cash available this month.")
            }
        }

        if isInfeasible {
            expandableAmountRow("Shortfall", value: feas.shortfall, valueColor: .red) {
                formulaRow("Minimums Due", amount: feas.minimums)
                formulaRow("Debt Budget This Month", amount: -availableForDebt, signed: true)
                Text("Minimum payments are higher than the debt budget this month.")
            }
            Button("Switch to Minimums Only") { tempStrategy = .minimumsOnly }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
        }
    }

    @ViewBuilder
    private var incomeBillsMathRows: some View {
        let monthlyIncome = recurringMonthlyIncomeForPlan
        let monthlyBills = recurringMonthlyBillsForPlan
        let netForDebt = monthlyIncome - monthlyBills
        let availableCash = recurringNetAvailableForTempPlan()
        let startMonth = normalizeToMonth(tempPlanMode == .projectedAtDate ? tempPlanDate : Date())
        let breakdown = nonMonthlyAdjustmentBreakdown(for: startMonth)
        let cashAdjustment = breakdown.netAdjustment
        let reserveSeed = reserveSeedingThisMonthTotal()

        manageIncomeBillsControl
        LabeledContent("Monthly Income") { Text(formatAmount(monthlyIncome)) }
        LabeledContent("Monthly Bills") { Text(formatAmount(monthlyBills)) }
        expandableAmountRow("Recurring Cash After Bills", value: netForDebt) {
            formulaRow("Monthly Income", amount: monthlyIncome)
            formulaRow("Monthly Bills", amount: -monthlyBills, signed: true)
            Text("Recurring monthly income minus recurring monthly bills.")
        }
        expandableAmountRow("Net Non-Monthly Adjustment", value: cashAdjustment) {
            formulaRow("Income Set Aside", amount: breakdown.incomeSetAside, signed: true)
            formulaRow("Bill Reserve", amount: -breakdown.billReserve, signed: true)
            Text("Income Set Aside minus Bill Reserve for this month.")
        }
        expandableAmountRow("Available Cash This Month", value: availableCash) {
            formulaRow("Recurring Cash After Bills", amount: netForDebt)
            formulaRow("Net Non-Monthly Adjustment", amount: cashAdjustment, signed: true)
            Text("This is the cash available for debt payoff or holdback this month.")
        }
        if reserveSeed > 0 {
            expandableAmountRow("Reserve Seed This Month", value: reserveSeed) {
                Text("System calculated: amount needed to keep non-monthly bill reserves on track. (Info Only)")
            }
        }
        Button("Use Available Cash as Debt Budget") {
            if availableCash > 0 {
                tempMonthlyBudget = formatAmount(availableCash)
                autoApplyEmbeddedPlanIfPossible()
            }
        }
        .disabled(availableCash <= 0)
    }

    private var tempStrategyDisplay: String {
        switch tempStrategy { case .minimumsOnly: return "Minimums"; case .snowball: return "Snowball"; case .avalanche: return "Avalanche" }
    }

    private var tempBudgetText: String {
        guard tempStrategy != .minimumsOnly else { return "" }
        let trimmed = tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if let d = parseCurrencyInput(trimmed) { return " • Debt Budget: \(formatAmount(d))" } else { return " • Debt Budget: —" }
    }

    @discardableResult
    private func applyPlanSettings(showAlerts: Bool = true) -> Bool {
        let feasCheck = feasibilityForTempPlan()
        if tempStrategy != .minimumsOnly && feasCheck.shortfall > 0 {
            let availText = formatAmount(feasCheck.available)
            let minsText = formatAmount(feasCheck.minimums)
            let message = "The debt budget this month (\(availText)) is less than your minimum payments (\(minsText)). Please increase your debt budget, adjust income/bills, or choose Minimums Only."
            budgetValidationError = message
            planErrorMessage = message
            if showAlerts { showPlanErrorAlert = true }
            return false
        }

        budgetValidationError = nil
        syncDiscretionaryReserveForFixedBudgetIfNeeded()
        let parsedBudget: Decimal? = {
            if tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return parseCurrencyInput(tempMonthlyBudget)
        }()
        let parsedDiscretionaryReserve = discretionaryReserveAmount

        if tempStrategy != .minimumsOnly && parsedBudget == nil {
            budgetValidationError = "Please enter a valid budget amount or select the Minimums Only strategy."
            planErrorMessage = budgetValidationError
            if showAlerts { showPlanErrorAlert = true }
            return false
        }

        let fixedBudgetExcess = fixedBudgetExcessForTempPlan(parsedBudget: parsedBudget)
        if fixedBudgetExcess > 0 {
            let excessText = formatAmount(fixedBudgetExcess)
            let message = "Your fixed budget is \(excessText) more than the cash available this month."
            budgetValidationError = message
            planErrorMessage = message
        }

        let shouldProjectBalances = usesProjectedBalances(mode: tempPlanMode, date: tempPlanDate)
        let planStartMonth = normalizeToMonth(tempPlanDate)
        let filteredAccounts = accounts.filter { acct in
            let baseBal = absDecimal(latestBalance(acct))
            let bal = shouldProjectBalances
                ? absProjectedOrBase(for: acct, planDate: planStartMonth, base: baseBal)
                : baseBal
            return bal > 0
        }
        let debts: [DebtInput] = filteredAccounts.map { acct in
            let baseBal = absDecimal(latestBalance(acct))
            let bal = shouldProjectBalances
                ? absProjectedOrBase(for: acct, planDate: planStartMonth, base: baseBal)
                : baseBal
            let minPayment = monthlyPayment(for: acct, balance: bal)
            return DebtInput(id: acct.id, name: acct.name, apr: acct.loanTerms?.apr, balance: bal, minPayment: minPayment)
        }

        let startDateForPlan = normalizeToMonth(tempPlanMode == .projectedAtDate ? tempPlanDate : Date())
        let availableCashSchedule = budgetSchedule(start: startDateForPlan, months: 60, baselineOverride: tempBaselineSource())
        let schedule = PlanBudgetDisplay.reserveAdjustedBudgetSchedule(
            availableCashSchedule,
            discretionaryReserve: parsedDiscretionaryReserve,
            appliesReserve: tempBaselineBudgetSourceRaw == "recurringNet"
        )

        do {
            let planResult: DebtPlanResult
            if tempIncludeNonMonthlyIncomeSpreads || tempBaselineBudgetSourceRaw == "recurringNet" {
                planResult = try DebtPayoffEngine.plan(
                    debts: debts,
                    budgetByMonth: schedule,
                    strategy: tempStrategy,
                    reinvestmentRate: Decimal(tempDebtPaymentReinvestmentRate),
                    startDate: startDateForPlan
                )
            } else {
                let budgetToUse: Decimal = parsedBudget ?? debts.reduce(0) { $0 + $1.minPayment }
                planResult = try DebtPayoffEngine.plan(
                    debts: debts,
                    monthlyBudget: budgetToUse,
                    strategy: tempStrategy,
                    reinvestmentRate: Decimal(tempDebtPaymentReinvestmentRate),
                    startDate: startDateForPlan
                )
            }
            currentPlan = planResult

            switch tempStrategy {
            case .minimumsOnly: settings.defaultPayoffStrategyRaw = "minimumsOnly"
            case .snowball:     settings.defaultPayoffStrategyRaw = "snowball"
            case .avalanche:    settings.defaultPayoffStrategyRaw = "avalanche"
            }

            baselineBudgetSourceRaw = tempBaselineBudgetSourceRaw
            includeNonMonthlyIncomeSpreads = tempIncludeNonMonthlyIncomeSpreads
            oneTimeIncomeDefaultSpreadMonths = tempOneTimeIncomeDefaultSpreadMonths
            debtPaymentReinvestmentRate = tempDebtPaymentReinvestmentRate
            debtDiscretionaryReserveAmount = NSDecimalNumber(decimal: parsedDiscretionaryReserve).doubleValue
            if tempBaselineBudgetSourceRaw == "fixed" {
                if tempStrategy != .minimumsOnly {
                    if let b = parsedBudget, b > 0 {
                        useFixedDebtBudget = true
                        debtBudgetOverrideAmount = NSDecimalNumber(decimal: b).doubleValue
                        lastFixedDebtBudgetAmount = debtBudgetOverrideAmount
                    } else {
                        budgetValidationError = "Please enter a valid debt budget or choose Use available cash."
                        planErrorMessage = budgetValidationError
                        if showAlerts { showPlanErrorAlert = true }
                        return false
                    }
                }
                // Minimums Only may display the required minimum total in this field,
                // but that is not a user-entered fixed budget and must not replace the remembered fixed amount.
            } else {
                useFixedDebtBudget = false
                debtBudgetOverrideAmount = 0.0
            }

            let normalizedStart = normalizeToMonth(tempPlanMode == .projectedAtDate ? tempPlanDate : Date())
            let shouldPersistProjectedStart = usesProjectedBalances(mode: tempPlanMode, date: tempPlanDate)
            debtPlanStartModeRaw = shouldPersistProjectedStart ? "projectedAtDate" : "currentInputs"
            debtPlanStartDateEpoch = shouldPersistProjectedStart ? normalizedStart.timeIntervalSince1970 : 0

            NotificationCenter.default.post(name: .planSettingsDidChange, object: nil)
            if !embeddedInNavigation {
                dismiss()
            }
            return true
        } catch DebtPlanError.infeasibleBudget {
            budgetValidationError = "The budget is too low to cover minimum payments. Please increase your budget or choose Minimums Only strategy."
            planErrorMessage = budgetValidationError
            if showAlerts { showPlanErrorAlert = true }
        } catch {
            budgetValidationError = "An unexpected error occurred."
            planErrorMessage = budgetValidationError
            if showAlerts { showPlanErrorAlert = true }
        }
        return false
    }

    private func autoApplyEmbeddedPlanIfPossible() {
        guard embeddedInNavigation else { return }
        _ = applyPlanSettings(showAlerts: false)
    }

    private func selectFocusedTextInput() {
        #if canImport(UIKit)
        DispatchQueue.main.async {
            let keyWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
            guard let responder = keyWindow?.findFirstResponder() else { return }
            if let textField = responder as? UITextField {
                textField.selectAll(nil)
            } else if let textView = responder as? UITextView {
                textView.selectAll(nil)
            }
        }
        #endif
    }

    private func commitAndDismissKeyboard() {
        let trimmed = tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = parseCurrencyInput(trimmed) { tempMonthlyBudget = formatAmount(d) }
        let trimmedReserve = tempDiscretionaryReserve.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedReserve = parseCurrencyInput(trimmedReserve)
        if let reserve = parsedReserve, reserve > 0 {
            tempDiscretionaryReserve = formatAmount(reserve)
        } else if trimmedReserve.isEmpty || parsedReserve == nil || (parsedReserve ?? 0) <= 0 {
            tempDiscretionaryReserve = ""
        }
        focusedField = nil
        autoApplyEmbeddedPlanIfPossible()
        #if canImport(UIKit)
        let keyWindow = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first { $0.isKeyWindow }
        keyWindow?.endEditing(true)
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
                            column(title: "Debt Budget", value: budgetForMonth, color: .primary)
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

private extension Notification.Name {
    static let debtSummaryEmbeddedPlannerEditingChanged = Notification.Name("DebtSummaryEmbeddedPlannerEditingChanged")
    static let debtSummaryEmbeddedPlannerCommitKeyboard = Notification.Name("DebtSummaryEmbeddedPlannerCommitKeyboard")
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
