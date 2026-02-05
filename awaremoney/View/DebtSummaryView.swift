//
//  DebtSummaryView.swift
//  awaremoney
//
//  Created by Assistant on 2/1/26
//

import SwiftUI
import SwiftData

struct DebtSummaryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var hSizeClass
    @State private var accounts: [Account] = []
    @State private var showPlanSheet = false
    @State private var tempPlanDate: Date = {
        Calendar.current.date(byAdding: .month, value: 12, to: Date()) ?? Date()
    }()
    @State private var appliedPlanDate: Date? = nil
    private enum PlanMode: String, CaseIterable {
        case currentInputs = "Use current inputs"
        case projectedAtDate = "Use projected at date"
    }
    @State private var tempPlanMode: PlanMode = .currentInputs
    @State private var appliedPlanMode: PlanMode = .currentInputs

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
                                VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                                    planHeader(compact: compact)
                                    headerRow(compact: compact)
                                    Divider()
                                    ForEach(accounts, id: \.id) { acct in
                                        row(for: acct, compact: compact)
                                        Divider()
                                    }
                                    totalRow(compact: compact)
                                }
                                .padding(.horizontal, compact ? 6 : 12)
                                .frame(width: 844, alignment: .topLeading)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                                planHeader(compact: compact)
                                headerRow(compact: compact)
                                Divider()
                                ForEach(accounts, id: \.id) { acct in
                                    row(for: acct, compact: compact)
                                    Divider()
                                }
                                totalRow(compact: compact)
                            }
                            .padding(.horizontal, compact ? 6 : 12)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.vertical, 8)
                }
                .navigationTitle("Debt Summary")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            showPlanSheet = true
                        } label: {
                            Text("Project")
//                            Image(systemName: "calendar.badge.clock")
                        }
                        .accessibilityIdentifier("planByDateButton")
                    }
                }
                .task { await load() }
                .sheet(isPresented: $showPlanSheet) {
                    NavigationStack {
                        List {
                            Section {
                                DatePicker("Target date", selection: $tempPlanDate, displayedComponents: .date)
                                    .datePickerStyle(.compact)
                                    .onChange(of: tempPlanDate) { newValue in
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
                                    Text("Use current inputs").tag(PlanMode.currentInputs)
                                    Text("Use projected at date").tag(PlanMode.projectedAtDate)
                                }
                                .pickerStyle(.segmented)
                                .onChange(of: tempPlanMode) { newValue in
                                    if newValue == .currentInputs {
                                        tempPlanDate = Date()
                                    }
                                }
                            }

                            Section("Current Plan") {
                                if appliedPlanMode == .projectedAtDate, let date = appliedPlanDate {
                                    Text("Plan as of \(date.formatted(date: .abbreviated, time: .omitted))")
                                } else {
                                    Text("Using current inputs")
                                }
                            }
                        }
                        .navigationTitle("Adjust Date")
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Apply") {
                                    appliedPlanDate = tempPlanDate
                                    appliedPlanMode = tempPlanMode
                                    showPlanSheet = false
                                }
                            }
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button("Clear") {
                                    appliedPlanDate = nil
                                    appliedPlanMode = .currentInputs
                                    // Also reset the in-sheet controls so the UI reflects a cleared state
                                    tempPlanDate = Date()
                                    tempPlanMode = .currentInputs
                                }
                                .disabled(appliedPlanDate == nil)
                            }
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { showPlanSheet = false }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func planHeader(compact: Bool) -> some View {
        Group {
            HStack {
                Spacer()
                if appliedPlanMode == .projectedAtDate, let date = appliedPlanDate {
                    Text("Plan as of \(date.formatted(date: .abbreviated, time: .omitted))")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Using current inputs")
                        .font(compact ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                }
            }
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
            if let plan = appliedPlanDate, appliedPlanMode == .projectedAtDate, let proj = try? projectedBalance(for: account, on: plan) {
                return absDecimal(proj)
            } else {
                return baseBal
            }
        }()
        let apr = account.loanTerms?.apr
        let payment = monthlyPayment(for: account, balance: usedBal)
        let step = monthStep(for: account, balance: usedBal)
        let payoff: Date? = {
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
                if let payoff {
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

        if let anchor = latestSnapshotDate(account), payment > 0 {
            // Statement-anchored monthly simulation
            let sDay = Calendar.current.component(.day, from: anchor)
            var bal = startingBalance
            var stmt = nextStatementDate(after: statementDate(onOrBefore: anchor, day: sDay), day: sDay)
            for _ in 0..<600 {
                bal -= payment
                if bal <= 0 { return stmt }
                if let apr, apr > 0 {
                    bal += bal * (apr / 12)
                }
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

    private func isCompactLayout(_ size: CGSize) -> Bool {
        return size.width < 1000
    }

    // MARK: - Formatting and helpers

    private func formatAmount(_ amount: Decimal?) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        guard let amount else { return "—" }
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

    private func totalsForAccounts(_ accts: [Account]) -> (balance: Decimal, payment: Decimal, interest: Decimal, afterPayment: Decimal) {
        var totalBalance: Decimal = 0
        var totalPayment: Decimal = 0
        var totalInterest: Decimal = 0
        var totalAfter: Decimal = 0

        for acct in accts {
            let base = absDecimal(latestBalance(acct))
            let bal: Decimal = {
                if let plan = appliedPlanDate, appliedPlanMode == .projectedAtDate, let proj = try? projectedBalance(for: acct, on: plan) {
                    return absDecimal(proj)
                } else {
                    return base
                }
            }()
            totalBalance += bal
            let pay = monthlyPayment(for: acct, balance: bal)
            totalPayment += pay
            let step = monthStep(for: acct, balance: bal)
            totalInterest += step.interest
            totalAfter += step.afterPaymentBalance
        }
        return (totalBalance, totalPayment, totalInterest, totalAfter)
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

