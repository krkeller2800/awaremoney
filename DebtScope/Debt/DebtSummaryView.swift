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

struct DebtSummaryView: View {
    var embeddedInNavigation: Bool = false

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [Account] = []
    @State private var embeddedPlannerIsEditing = false
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
                            let outerPadding: CGFloat = embeddedInNavigation ? (compact ? 18 : 28) : (compact ? 6 : 12)
                            let maxContentWidth: CGFloat = compact ? 900 : 980
                            let contentWidth: CGFloat = min(maxContentWidth, proxy.size.width - 2 * outerPadding)
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
                        Text(planSubtitleText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                    }
                }
                if !embeddedInNavigation {
                    ToolbarItem(placement: .topBarLeading) {
                        PlanToolbarButton("Done", fixedWidth: 60) {
                            dismiss()
                        }
                        .accessibilityIdentifier("debtSummaryDoneButton")
                    }
                }
            }
            .task { recomputeAppliedState() }
            .task { await load() }
            .onReceive(NotificationCenter.default.publisher(for: .planSettingsDidChange)) { _ in
                recomputeAppliedState()
            }
            .onReceive(NotificationCenter.default.publisher(for: .debtSummaryEmbeddedPlannerEditingChanged)) { note in
                guard embeddedInNavigation, let isEditing = note.object as? Bool else { return }
                embeddedPlannerIsEditing = isEditing
            }
            .onChange(of: baselineBudgetSourceRaw) { _, _ in recomputeAppliedState() }
            .onChange(of: useFixedDebtBudget) { _, _ in recomputeAppliedState() }
            .onChange(of: debtBudgetOverrideAmount) { _, _ in recomputeAppliedState() }
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
        let gap: CGFloat = compact ? 2 : 12
        let gaps = 6 // number of gaps between 7 columns
        let totalSpacing = gap * CGFloat(gaps)
        let usable = max(0, totalWidth - totalSpacing)
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
        let widths = columnWidths(for: availableWidth, compact: compact)
        return VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack {
                Spacer()
                Picker("Strategy", selection: inlineStrategyBinding) {
                    Text("Minimums Only").tag(PayoffStrategy.minimumsOnly)
                    Text("Snowball").tag(PayoffStrategy.snowball)
                    Text("Avalanche").tag(PayoffStrategy.avalanche)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: min(availableWidth, compact ? 420 : 520))
                Spacer()
            }
            headerRow(compact: compact, widths: widths)
            Divider()
            ForEach(sortedAccountsByPayoffDate(), id: \.id) { acct in
                row(for: acct, compact: compact, widths: widths)
                Divider()
            }
            totalRow(compact: compact, widths: widths)
            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                Text("Plan Settings")
                    .font(compact ? .headline : .title3.weight(.semibold))
                    .padding(.horizontal, compact ? 12 : 16)
                    .padding(.top, compact ? 10 : 14)

                DebtPlanSheetView(embeddedInNavigation: true)
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
        autoApplyEmbeddedPlanIfPossible()
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
            autoApplyEmbeddedPlanIfPossible()
        }
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
    private var embeddedPlanEditorContent: some View {
        let showLandscapeHint = shouldShowPlanLandscapeHint
        VStack(alignment: .leading, spacing: 16) {
            embeddedSection {
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
            }
            .id("planEditorTop")

            embeddedSection("Payoff Plan") {
                LabeledContent("Base Budget") {
                    TextField("$0.00", text: $tempMonthlyBudget)
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                        .focused($focusedField, equals: .monthlyBudget)
                        .selectAllOnFocus()
                        .submitLabel(.done)
                        .onSubmit { commitAndDismissKeyboard() }
                        .onChange(of: tempMonthlyBudget) { _, _ in
                            autoApplyEmbeddedPlanIfPossible()
                        }
                }
                .id("monthlyBudgetField")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your total monthly budget for debt payments. Leave empty if you use Minimums Only strategy or Reoccurring Net.")
                    Text("Changes apply immediately as you edit this plan.")
                        .foregroundStyle(.secondary)
                    if let error = budgetValidationError {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }

            embeddedSection("Budget Source & Spreads") {
                Picker("Baseline source", selection: $tempBaselineBudgetSourceRaw) {
                    Text("Recurring Net").tag("recurringNet")
                    Text("Fixed amount").tag("fixed")
                }
                .pickerStyle(.segmented)
                .onChange(of: tempBaselineBudgetSourceRaw) { _, _ in
                    autoApplyEmbeddedPlanIfPossible()
                }

                DisclosureGroup(isExpanded: $showBudgetingHint) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Recurring Net")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Uses your ongoing income and expenses to compute a monthly budget that can vary by month. It's adjusted for one-time incomes/bills spread across several months. Debt payments adjust based on what's available each month.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Divider()
                        Text("Fixed Amount")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("Uses a single, constant monthly budget for debt payoff. It's adjusted for one-time incomes/bills spread across several months. If the fixed amount is too low to cover minimums, the plan will fail until you increase it.")
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
                    let rawExplainContributions = IncomeScheduler.contributionsByMonth(items: items, start: startMonth, months: 12, oneTimeDefaultSpreadMonths: sanitizedDefaultSpread(oneTimeIncomeDefaultSpreadMonths))
                    let explainContributions: [Date: [ExplainPlanView.ContributionRow]] = Dictionary(uniqueKeysWithValues: rawExplainContributions.map { (date, rows) in (date, rows.map { r in ExplainPlanView.ContributionRow(name: r.name, amount: r.amount) }) })
                    let rawBillContributions = IncomeScheduler.billContributionsByMonth(items: items, start: startMonth, months: 12, defaultSpreadMonths: sanitizedDefaultSpread(oneTimeIncomeDefaultSpreadMonths))
                    let explainBillContributions: [Date: [ExplainPlanView.ContributionRow]] = Dictionary(uniqueKeysWithValues: rawBillContributions.map { (date, rows) in (date, rows.map { r in ExplainPlanView.ContributionRow(name: r.name, amount: r.amount) }) })
                    ExplainPlanView(startMonth: startMonth, contributions: explainContributions, billContributions: explainBillContributions, monthlyBudgetByMonth: schedule)
                        .environmentObject(settings)
                } label: {
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
            } footer: {
                Text("Shows which variable incomes/bills contribute to which months. Spreads begin the month after a pay date; remainders apply to the last month.")
            }

            if tempStrategy != .minimumsOnly {
                embeddedSection("Feasibility") {
                    let feas = feasibilityForTempPlan()
                    let isInfeasible = feas.shortfall > 0
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
                }
                .id("feasibility-section")
            }

            embeddedSection("Income & Bills") {
                NavigationLink("Manage Income & Bills") { IncomeAndBillsView() }
                LabeledContent("Monthly Income") { Text(formatAmount(computedMonthlyIncome)) }
                LabeledContent("Monthly Bills") { Text(formatAmount(computedMonthlyBills)) }
                if reserveSeedingThisMonthTotal() > 0 {
                    LabeledContent("Reserve Seed (This Month)") { Text(formatAmount(reserveSeedingThisMonthTotal())) }
                }
                LabeledContent("Net for Debt") { Text(formatAmount(computedMonthlyIncome - computedMonthlyBills)) }
                Button("Use Net as Budget") {
                    let net = computedMonthlyIncome - computedMonthlyBills
                    if net > 0 {
                        tempMonthlyBudget = formatAmount(net)
                        autoApplyEmbeddedPlanIfPossible()
                    }
                }
                .disabled((computedMonthlyIncome - computedMonthlyBills) <= 0)
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
                            LabeledContent("Base Budget") {
                                TextField("$0.00", text: $tempMonthlyBudget)
                                    .multilineTextAlignment(.trailing)
                                    .keyboardType(.numbersAndPunctuation)
                                    .focused($focusedField, equals: .monthlyBudget)
                                    .selectAllOnFocus()
                                    .submitLabel(.done)
                                    .onSubmit { commitAndDismissKeyboard() }
                                    .onChange(of: tempMonthlyBudget) { _, _ in
                                        autoApplyEmbeddedPlanIfPossible()
                                    }
                            }
                            .id("monthlyBudgetField")
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
                            Picker("Baseline source", selection: $tempBaselineBudgetSourceRaw) {
                                Text("Recurring Net").tag("recurringNet")
                                Text("Fixed amount").tag("fixed")
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: tempBaselineBudgetSourceRaw) { _, _ in
                                autoApplyEmbeddedPlanIfPossible()
                            }
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
                                if net > 0 {
                                    tempMonthlyBudget = formatAmount(net)
                                    autoApplyEmbeddedPlanIfPossible()
                                }
                            }
                            .disabled((computedMonthlyIncome - computedMonthlyBills) <= 0)
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
            tempBaselineBudgetSourceRaw = baselineBudgetSourceRaw
            if useFixedDebtBudget, debtBudgetOverrideAmount > 0 {
                tempBaselineBudgetSourceRaw = "fixed"
                let saved = NSDecimalNumber(value: debtBudgetOverrideAmount).decimalValue
                tempMonthlyBudget = formatAmount(saved)
            }
            tempIncludeNonMonthlyIncomeSpreads = includeNonMonthlyIncomeSpreads
            tempOneTimeIncomeDefaultSpreadMonths = oneTimeIncomeDefaultSpreadMonths
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

    @discardableResult
    private func applyPlanSettings(showAlerts: Bool = true) -> Bool {
        let feasCheck = feasibilityForTempPlan()
        if tempStrategy != .minimumsOnly && feasCheck.shortfall > 0 {
            let availText = formatAmount(feasCheck.available)
            let minsText = formatAmount(feasCheck.minimums)
            let message = "The budget available this month (\(availText)) is less than your minimum payments (\(minsText)). Please increase your budget, adjust income/bills, or choose Minimums Only."
            budgetValidationError = message
            planErrorMessage = message
            if showAlerts { showPlanErrorAlert = true }
            return false
        }

        budgetValidationError = nil
        let parsedBudget: Decimal? = {
            if tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return parseCurrencyInput(tempMonthlyBudget)
        }()

        if tempStrategy != .minimumsOnly && parsedBudget == nil {
            budgetValidationError = "Please enter a valid budget amount or select the Minimums Only strategy."
            planErrorMessage = budgetValidationError
            if showAlerts { showPlanErrorAlert = true }
            return false
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
        let schedule = budgetSchedule(start: startDateForPlan, months: 60, baselineOverride: tempBaselineSource())

        do {
            let planResult: DebtPlanResult
            if tempIncludeNonMonthlyIncomeSpreads || tempBaselineBudgetSourceRaw == "recurringNet" {
                planResult = try DebtPayoffEngine.plan(
                    debts: debts,
                    budgetByMonth: schedule,
                    strategy: tempStrategy,
                    startDate: startDateForPlan
                )
            } else {
                let budgetToUse: Decimal = parsedBudget ?? debts.reduce(0) { $0 + $1.minPayment }
                planResult = try DebtPayoffEngine.plan(
                    debts: debts,
                    monthlyBudget: budgetToUse,
                    strategy: tempStrategy,
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

            if tempBaselineBudgetSourceRaw == "fixed" {
                if let b = parsedBudget, b > 0 {
                    useFixedDebtBudget = true
                    debtBudgetOverrideAmount = NSDecimalNumber(decimal: b).doubleValue
                } else {
                    budgetValidationError = "Please enter a valid budget amount for Fixed source or choose Recurring Net."
                    planErrorMessage = budgetValidationError
                    if showAlerts { showPlanErrorAlert = true }
                    return false
                }
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

    private func commitAndDismissKeyboard() {
        let trimmed = tempMonthlyBudget.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = parseCurrencyInput(trimmed) { tempMonthlyBudget = formatAmount(d) }
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
