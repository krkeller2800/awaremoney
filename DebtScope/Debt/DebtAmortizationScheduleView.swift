import SwiftUI

struct DebtAmortizationScheduleView: View {
    let plan: DebtPlanResult?
    let accounts: [Account]
    let availableCashByMonth: [Date: Decimal]
    let availableForDebtByMonth: [Date: Decimal]
    let discretionaryReserve: Decimal

    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ScheduleMode = .allDebts
    @State private var selectedAccountID: UUID?

    private enum ScheduleMode: String, CaseIterable, Identifiable {
        case allDebts = "All Debts"
        case byAccount = "By Account"

        var id: String { rawValue }
    }

    private var rows: [DebtAmortizationMonthRow] {
        guard let plan else { return [] }
        return DebtAmortizationScheduleRows.makeRows(
            plan: plan,
            accounts: accounts,
            availableCashByMonth: availableCashByMonth,
            availableForDebtByMonth: availableForDebtByMonth,
            discretionaryReserve: discretionaryReserve
        )
    }

    private var accountOptions: [Account] {
        accounts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var effectiveSelectedAccountID: UUID? {
        selectedAccountID ?? accountOptions.first?.id
    }

    var body: some View {
        NavigationStack {
            List {
                if rows.isEmpty {
                    ContentUnavailableView(
                        "No schedule available",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("Apply a valid payoff plan to view the amortization schedule.")
                    )
                } else {
                    Section {
                        Picker("View", selection: $mode) {
                            ForEach(ScheduleMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        if mode == .byAccount {
                            Picker("Account", selection: Binding(
                                get: { effectiveSelectedAccountID },
                                set: { selectedAccountID = $0 }
                            )) {
                                ForEach(accountOptions, id: \.id) { account in
                                    Text(account.name).tag(Optional(account.id))
                                }
                            }
                        }
                    }

                    switch mode {
                    case .allDebts:
                        allDebtsSection
                    case .byAccount:
                        accountSection
                    }
                }
            }
            .navigationTitle("Amortization Schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if selectedAccountID == nil {
                    selectedAccountID = accountOptions.first?.id
                }
            }
        }
    }

    private var allDebtsSection: some View {
        Section("All Debts") {
            ForEach(rows) { row in
                DisclosureGroup {
                    scheduleDetailRows(for: row)

                    if !row.accountRows.isEmpty {
                        Divider()
                        ForEach(row.accountRows) { accountRow in
                            accountDetailRow(accountRow, includeStartingBalance: false)
                        }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(monthTitle(row.month))
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(formatAmount(row.endingDebtBalance))
                                .monospacedDigit()
                            Text(formatAmount(row.totalDebtPayment))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private var accountSection: some View {
        Section("Account") {
            if let accountID = effectiveSelectedAccountID {
                let accountRows = rows.compactMap { monthRow in
                    monthRow.accountRows.first { $0.accountID == accountID }
                }

                if accountRows.isEmpty {
                    Text("No schedule rows for this account.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(accountRows) { row in
                        DisclosureGroup {
                            accountDetailRow(row, includeStartingBalance: true)
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text(monthTitle(row.month))
                                Spacer(minLength: 12)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(formatAmount(row.endingBalance))
                                        .monospacedDigit()
                                    Text(formatAmount(row.payment))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func scheduleDetailRows(for row: DebtAmortizationMonthRow) -> some View {
        amountRow("Available Cash", row.availableCash)
        amountRow("Hold Back Cash", row.discretionaryReserve)
        amountRow("Debt Budget", row.availableForDebt)
        amountRow("Total Debt Payment", row.totalDebtPayment)
        amountRow("Interest", row.interest)
        amountRow("Ending Debt Balance", row.endingDebtBalance)
        amountRow("Cash Left After Debt", row.discretionaryRemaining)
        if row.belowReserveTarget > 0 {
            amountRow("Below Holdback Target", row.belowReserveTarget, color: .orange)
        }
    }

    private func accountDetailRow(_ row: DebtAmortizationAccountRow, includeStartingBalance: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.accountName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if row.isPayoffMonth {
                    Text("Paid off")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
            if includeStartingBalance {
                amountRow("Starting Balance", row.startingBalance)
            }
            amountRow("Payment", row.payment)
            amountRow("Interest", row.interest)
            amountRow("Ending Balance", row.endingBalance)
        }
        .font(.subheadline)
        .padding(.vertical, 4)
    }

    private func amountRow(_ title: String, _ amount: Decimal, color: Color = .primary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(formatAmount(amount))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .font(.subheadline)
    }

    private func monthTitle(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).year())
    }

    private func formatAmount(_ amount: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = settings.currencyCode
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }
}

struct DebtAmortizationMonthRow: Identifiable {
    let id: Date
    let month: Date
    let availableCash: Decimal
    let discretionaryReserve: Decimal
    let availableForDebt: Decimal
    let totalDebtPayment: Decimal
    let interest: Decimal
    let endingDebtBalance: Decimal
    let discretionaryRemaining: Decimal
    let belowReserveTarget: Decimal
    let accountRows: [DebtAmortizationAccountRow]
}

struct DebtAmortizationAccountRow: Identifiable {
    let id: String
    let accountID: UUID
    let accountName: String
    let month: Date
    let startingBalance: Decimal
    let payment: Decimal
    let interest: Decimal
    let endingBalance: Decimal
    let isPayoffMonth: Bool
}

enum DebtAmortizationScheduleRows {
    static func makeRows(
        plan: DebtPlanResult,
        accounts: [Account],
        availableCashByMonth: [Date: Decimal],
        availableForDebtByMonth: [Date: Decimal],
        discretionaryReserve: Decimal,
        calendar: Calendar = .current
    ) -> [DebtAmortizationMonthRow] {
        let accountNames = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.name) })
        let normalizedAvailableCash = normalize(schedule: availableCashByMonth, calendar: calendar)
        let normalizedAvailableForDebt = normalize(schedule: availableForDebtByMonth, calendar: calendar)
        var previousEndingBalances: [UUID: Decimal] = [:]

        return plan.months.map { month in
            let monthKey = normalize(month.date, calendar: calendar)
            let accountIDs = Set(month.payments.keys)
                .union(month.interest.keys)
                .union(month.balances.keys)

            let accountRows = accountIDs.compactMap { accountID -> DebtAmortizationAccountRow? in
                let payment = month.payments[accountID] ?? 0
                let interest = month.interest[accountID] ?? 0
                let endingBalance = month.balances[accountID] ?? previousEndingBalances[accountID] ?? 0
                let startingBalance = startingBalance(
                    accountID: accountID,
                    endingBalance: endingBalance,
                    payment: payment,
                    interest: interest,
                    previousEndingBalances: previousEndingBalances
                )

                previousEndingBalances[accountID] = endingBalance

                guard startingBalance > 0 || payment > 0 || interest > 0 || endingBalance > 0 else {
                    return nil
                }

                return DebtAmortizationAccountRow(
                    id: "\(accountID.uuidString)-\(monthKey.timeIntervalSince1970)",
                    accountID: accountID,
                    accountName: accountNames[accountID] ?? "Account",
                    month: monthKey,
                    startingBalance: startingBalance,
                    payment: payment,
                    interest: interest,
                    endingBalance: endingBalance,
                    isPayoffMonth: isSameMonth(plan.payoffDates[accountID], monthKey, calendar: calendar)
                )
            }
            .sorted { lhs, rhs in
                if lhs.isPayoffMonth != rhs.isPayoffMonth { return lhs.isPayoffMonth }
                return lhs.accountName.localizedCaseInsensitiveCompare(rhs.accountName) == .orderedAscending
            }

            let totalDebtPayment = month.payments.values.reduce(0, +).rounded(scale: 2)
            let interest = month.interest.values.reduce(0, +).rounded(scale: 2)
            let endingDebtBalance = month.balances.values.reduce(0, +).rounded(scale: 2)
            let availableCash = (normalizedAvailableCash[monthKey] ?? normalizedAvailableForDebt[monthKey] ?? totalDebtPayment).rounded(scale: 2)
            let availableForDebt = (normalizedAvailableForDebt[monthKey] ?? totalDebtPayment).rounded(scale: 2)
            let discretionaryRemaining = (availableCash - totalDebtPayment).rounded(scale: 2)
            let belowReserveTarget = PlanBudgetDisplay.reserveGap(
                discretionaryReserve: discretionaryReserve,
                discretionaryRemaining: discretionaryRemaining
            ).rounded(scale: 2)

            return DebtAmortizationMonthRow(
                id: monthKey,
                month: monthKey,
                availableCash: availableCash,
                discretionaryReserve: discretionaryReserve.rounded(scale: 2),
                availableForDebt: availableForDebt,
                totalDebtPayment: totalDebtPayment,
                interest: interest,
                endingDebtBalance: endingDebtBalance,
                discretionaryRemaining: discretionaryRemaining,
                belowReserveTarget: belowReserveTarget,
                accountRows: accountRows
            )
        }
    }

    static func startingBalance(
        accountID: UUID,
        endingBalance: Decimal,
        payment: Decimal,
        interest: Decimal,
        previousEndingBalances: [UUID: Decimal]
    ) -> Decimal {
        if let previousEndingBalance = previousEndingBalances[accountID] {
            return previousEndingBalance.rounded(scale: 2)
        }
        return (endingBalance + payment - interest).rounded(scale: 2)
    }

    private static func normalize(schedule: [Date: Decimal], calendar: Calendar) -> [Date: Decimal] {
        schedule.reduce(into: [:]) { result, item in
            result[normalize(item.key, calendar: calendar)] = item.value
        }
    }

    private static func normalize(_ date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }

    private static func isSameMonth(_ lhs: Date?, _ rhs: Date, calendar: Calendar) -> Bool {
        guard let lhs else { return false }
        return calendar.isDate(lhs, equalTo: rhs, toGranularity: .month)
    }
}
