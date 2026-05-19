import SwiftUI
import Charts
import SwiftData

struct DebtProjectionChartView: View {
    struct MonthlyPoint: Identifiable {
        enum PointType {
            case actual, projected
        }
        var id: Int { month }
        let month: Int
        let value: Double
        let type: PointType
    }
    
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    @AppStorage("useFixedDebtBudget") private var useFixedDebtBudget: Bool = false
    @AppStorage("debtBudgetOverrideAmount") private var debtBudgetOverrideAmount: Double = 0
    @AppStorage("debtPaymentReinvestmentRate") private var debtPaymentReinvestmentRate: Double = 1
    
    // Added as per instructions
    @AppStorage("includeNonMonthlyIncomeSpreads") private var includeNonMonthlyIncomeSpreads: Bool = true
    @AppStorage("oneTimeIncomeDefaultSpreadMonths") private var oneTimeIncomeDefaultSpreadMonths: Int = 12
    @AppStorage("baselineBudgetSourceRaw") private var baselineBudgetSourceRaw: String = "recurringNet"
    
    private let items: [CashFlowItem]
    
    @State private var selectedYear: Int
    @State private var selectedStrategy: PayoffStrategy = .minimumsOnly
    @State private var amountSelectionTrigger: Int = 0
    @State private var requiredMinimumForBudget: Decimal? = nil
    @State private var isEditingBudgetAmount: Bool = false
    @FocusState private var amountFieldFocused: Bool
    @State private var headerHeight: CGFloat = 0
    
    init(items: [CashFlowItem]) {
        self.items = items
        _selectedYear = State(initialValue: Calendar.current.component(.year, from: Date()))
    }
    
    private var baselineSource: IncomeScheduler.BaselineSource {
        if baselineBudgetSourceRaw == "fixed", useFixedDebtBudget, debtBudgetOverrideAmount > 0 {
            return .fixedAmount(Decimal(debtBudgetOverrideAmount))
        } else {
            return .recurringNet
        }
    }
    
    var body: some View {
        NavigationStack {
#if os(iOS)
        let topComp: CGFloat = (horizontalSizeClass == .compact ? 0 : 0)
#else
        let topComp: CGFloat = 0
#endif
        GeometryReader { proxy in
        let monthlyNet = calculateMonthlyNet()
        
        // Precompute data outside of the Chart closure to help the type-checker
        let points = buildMonthlyPoints(net: monthlyNet, year: selectedYear, strategy: selectedStrategy)
        let actualPoints: [MonthlyPoint] = points.filter { $0.type == .actual }
        let projectedPoints: [MonthlyPoint] = points.filter { $0.type == .projected }
        let calendar = Calendar.current
        let now = Date()
        let nowYear = calendar.component(.year, from: now)
        let nowMonth = calendar.component(.month, from: now)
        let minSelectableYear: Int = {
            let years = yearsWithLiabilityData()
            if let minYear = years.min() {
                return minYear
            } else {
                return nowYear
            }
        }()
        
        VStack(alignment: .leading) {
            VStack(alignment: .leading) {
                HStack {
                    
                    Spacer()
                    
                    Button {
                        if let prev = previousAvailableYear(from: selectedYear, minYear: minSelectableYear) {
                            selectedYear = prev
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .accessibilityLabel("Previous year")
                    .disabled(previousAvailableYear(from: selectedYear, minYear: minSelectableYear) == nil)
                    
                    Text(String(selectedYear))
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    
                    Button {
                        selectedYear += 1
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .accessibilityLabel("Next year")
                    
                    Spacer()
                    
                }
                .padding(.horizontal)

               
                let displayBudget = max(Decimal(0), effectiveBudget(for: monthlyNet, strategy: selectedStrategy))
                
                Text("Budget: \(formatCurrencyDecimal(displayBudget)) • Strategy: \(strategyDisplayName(selectedStrategy))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 6)

                VStack(spacing: 8) {
                    Picker("Strategy", selection: $selectedStrategy) {
                        Text("Minimums only").tag(PayoffStrategy.minimumsOnly)
                        Text("Snowball").tag(PayoffStrategy.snowball)
                        Text("Avalanche").tag(PayoffStrategy.avalanche)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Payoff strategy")

                    HStack(spacing: 8) {
                        // Leading label
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use custom budget amount")
                                .lineLimit(1)
                            Text("Otherwise uses income minus bills")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        // Toggle directly after the label
                        Toggle("", isOn: $useFixedDebtBudget)
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityLabel("Use custom budget amount")
                            .accessibilityHint("When off, the app uses your income minus bills as the budget.")
                        Spacer()
                        // Inline validation shown between the toggle and the amount field
                        if useFixedDebtBudget, let min = requiredMinimumForBudget {
                            Text("Minimum required: \(formatCurrencyDecimal(min))")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .lineLimit(1)
                                .layoutPriority(1)
                                .minimumScaleFactor(0.75)
                        }

                        Spacer()

                        // Trailing amount area that maintains constant width across toggle states
                        ZStack(alignment: .trailing) {
                            // Editable amount UI (shown when toggle is on)
                            Group {
    #if os(iOS)
                                CurrencyTextField(placeholder: "Amount", value: $debtBudgetOverrideAmount, currencyCode: settings.currencyCode, selectionTrigger: $amountSelectionTrigger, isEditing: $isEditingBudgetAmount)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .frame(height: 36)
    #else
                                TextField("Amount", value: $debtBudgetOverrideAmount, format: .currency(code: settings.currencyCode))
                                    .focused($amountFieldFocused)
                                    .fixedSize(horizontal: true, vertical: false)
    #endif
                            }
                            .opacity(useFixedDebtBudget ? 1 : 0)
                            .allowsHitTesting(useFixedDebtBudget)
                            .accessibilityHidden(!useFixedDebtBudget)

                            // Automatic budget text (shown when toggle is off)
                            Text(formatCurrencyDecimal(monthlyNet))
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Automatic budget")
                                .accessibilityValue(formatCurrencyDecimal(monthlyNet))
                                .opacity(useFixedDebtBudget ? 0 : 1)
                                .allowsHitTesting(!useFixedDebtBudget)
                                .accessibilityHidden(useFixedDebtBudget)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !(UIDevice.type == "iPhone") {
                        DebtStrategyInfoView()
                            .padding()
                    }
                }
                .padding(.horizontal)
            }
            .background(
                GeometryReader { g in
                    Color.clear.preference(key: ViewHeightKey.self, value: g.size.height)
                }
            )
            .onPreferenceChange(ViewHeightKey.self) { headerHeight = $0 }
            let yMax = max(((actualPoints + projectedPoints).map(\.value).max() ?? 0.0), 1.0)
            let chartHeight = max(120, proxy.size.height - headerHeight - topComp - 16 - proxy.safeAreaInsets.bottom - 60)
            Chart {
                RuleMark(y: .value("Zero", 0))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.gray.opacity(0.5))
                
                if !actualPoints.isEmpty {
                    ForEach(actualPoints) { point in
                        LineMark(
                            x: .value("Month", point.month),
                            y: .value("Value", point.value)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(by: .value("Series", "Actual"))
                        .zIndex(2)
                    }
                }
                
                if !projectedPoints.isEmpty {
                    ForEach(projectedPoints) { point in
                        LineMark(
                            x: .value("Month", point.month),
                            y: .value("Value", point.value)
                        )
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(by: .value("Series", "Projected"))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
                        .zIndex(1)
                    }
                }
                
                let endOfYearPoint: MonthlyPoint? = {
                    guard !projectedPoints.isEmpty else { return nil }
                    if let p = projectedPoints.first(where: { $0.month == 12 }) { return p }
                    return projectedPoints.last
                }()
                
                if let eoy = endOfYearPoint {
                    PointMark(
                        x: .value("Month", eoy.month),
                        y: .value("Value", eoy.value)
                    )
                    .foregroundStyle(by: .value("Series", "Projected"))
                    .symbolSize(0)
                    .zIndex(11)
                    .annotation(position: .bottomLeading, spacing: 4) {
                        Text("End of year: \(formatCurrency(eoy.value))")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(
                                Color(.systemBackground).opacity(0.85),
                                in: Capsule()
                            )
                            .overlay(
                                Capsule().stroke(Color.secondary.opacity(0.25))
                            )
                    }
                    .accessibilityLabel("End of year total")
                    .accessibilityValue(formatCurrency(eoy.value))
                }
                // Current date marker (align to month axis 1...12)
                // Only show the marker when it falls within the selected year's 1...12 window
                if nowYear == selectedYear {
                    RuleMark(x: .value("Month", nowMonth))
                        .foregroundStyle(Color.accentColor.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 5]))
                        .zIndex(10)
                        .annotation(position: .bottomTrailing, spacing: 4) {
                            Text("Today")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    Color(.systemBackground).opacity(0.85),
                                    in: Capsule()
                                )
                                .overlay(
                                    Capsule().stroke(Color.secondary.opacity(0.25))
                                )
                                .offset(y: -24)
                        }
                        .accessibilityLabel("Today")
                }
            }
            .chartForegroundStyleScale([
                "Actual": Color.accentColor as Color,
                "Projected": Color.secondary as Color
            ])
            .chartXScale(domain: 1...12)
            .chartYScale(domain: 0.0...(yMax * 1.1))
            .chartXAxis {
                AxisMarks(values: Array(1...12)) { v in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let month = v.as(Int.self) {
                            Text(shortMonthName(month))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { v in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let doubleValue = v.as(Double.self) {
                            Text(formatCurrency(doubleValue))
                        }
                    }
                }
            }
            .chartPlotStyle { plotArea in
                plotArea
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .padding(.leading, 8)
                    .padding(.trailing, 8)
            }
            .chartLegend(.hidden)
            .padding(.horizontal)
            .frame(height: chartHeight)
            if !actualPoints.isEmpty || !projectedPoints.isEmpty {
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: 28, height: 3)
                            .cornerRadius(1.5)
                        Text("Actual")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Text("---")
                            .font(.headline)
                            .foregroundStyle(Color.secondary)
                        Text("Projected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal)
                .padding(.top, 4)
            }
#if os(iOS)
            // iPhone portrait hint — match DebtSummaryView
            if UIDevice.current.userInterfaceIdiom == .phone && proxy.size.height > proxy.size.width {
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
                .padding(.top, 8)
            }
#endif
        }
        .padding(.top, topComp)
        }
        .onAppear {
            // Initialize from current settings when the view appears
            selectedStrategy = defaultStrategy

            // Compute current year and minimum selectable year locally for this scope
            let now = Date()
            let calendar = Calendar.current
            let nowYear = calendar.component(.year, from: now)
            let minSelectableYear: Int = {
                let years = yearsWithLiabilityData()
                if let minYear = years.min() {
                    return minYear
                } else {
                    return nowYear
                }
            }()

            if selectedYear < minSelectableYear {
                selectedYear = minSelectableYear
            }
            if !hasLiabilityData(in: selectedYear) {
                if let latest = latestAvailableYear(upTo: nowYear, minYear: minSelectableYear) {
                    selectedYear = latest
                } else {
                    selectedYear = max(minSelectableYear, nowYear)
                }
            }
        }
        .onChange(of: selectedStrategy) { _, newValue in
            // Persist selection back to settings so it is remembered
            switch newValue {
            case .minimumsOnly:
                settings.defaultPayoffStrategyRaw = "minimumsOnly"
            case .snowball:
                settings.defaultPayoffStrategyRaw = "snowball"
            case .avalanche:
                settings.defaultPayoffStrategyRaw = "avalanche"
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                PlanToolbarButton("Done",fixedWidth: 65) {
                    dismiss()
                }
                .accessibilityLabel("Done")
                .accessibilityHint("Dismiss")
            }
#if !os(iOS)
            ToolbarItem(placement: .confirmationAction) {
                if amountFieldFocused {
                    Button {
                        // Finalize the edit and remove focus
                        amountFieldFocused = false
                    } label: {
                        Label("Done", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityLabel("Done")
                    .accessibilityHint("Finalize the amount and dismiss editing")
                }
            }
#endif
        }
        .navigationTitle("Debt Chart")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
#if os(iOS)
//        .presentationDragIndicator(.visible)
#endif
        }
    }
    
    private func reserveSeedingThisMonthTotal() -> Decimal {
        do {
            let all = try modelContext.fetch(FetchDescriptor<CashFlowItem>())
            let bills = all.filter { !$0.isIncome }
            let now = Date()
            return bills.reduce(Decimal(0)) { acc, item in
                if let plan = BillReservePlanner.planReserve(for: item, asOf: now, currentReserve: item.reserveBalance), plan.seedAmount > 0 {
                    return acc + plan.seedAmount
                }
                return acc
            }
        } catch {
            return 0
        }
    }
    
    private func calculateMonthlyNet() -> Decimal {
        func monthlyEquivalent(amount: Decimal, frequency: PaymentFrequency) -> Decimal {
            amount * frequency.monthlyEquivalentFactor
        }
        var total: Decimal = 0
        for item in items {
            let monthlyValue = monthlyEquivalent(amount: item.amount, frequency: item.frequency)
            switch item.kind {
            case .income:
                total += monthlyValue
            case .bill:
                total -= monthlyValue
            }
        }
        return total
    }
    
    private var liabilities: [Account] {
        do {
            let all = try modelContext.fetch(FetchDescriptor<Account>())
            return all.filter { $0.type == .loan || $0.type == .creditCard }
        } catch {
            return []
        }
    }
    
    private func endOfMonth(year: Int, month: Int) -> Date {
        let calendar = Calendar.current
        var comps = DateComponents(year: year, month: month)
        comps.day = 1
        guard let firstOfMonth = calendar.date(from: comps) else {
            return Date()
        }
        guard let range = calendar.range(of: .day, in: .month, for: firstOfMonth) else {
            return firstOfMonth
        }
        comps.day = range.count
        return calendar.date(from: comps) ?? firstOfMonth
    }
    
    // Guardrail: ignore obviously invalid historical dates (e.g., year < 1970)
    private var minValidDataDate: Date {
        Calendar.current.date(from: DateComponents(year: 1970, month: 1, day: 1)) ?? Date(timeIntervalSince1970: 0)
    }
    
    private func value(for account: Account, on date: Date) -> Decimal {
        let snaps = account.balanceSnapshots.filter { !$0.isExcluded && $0.asOfDate <= date && $0.asOfDate >= minValidDataDate }
        if let last = snaps.max(by: { $0.asOfDate < $1.asOfDate }) {
            let txs = account.transactions.filter {
                !$0.isExcluded && $0.datePosted > last.asOfDate && $0.datePosted <= date
            }
            let delta = txs.reduce(Decimal(0)) { partialResult, tx in
                partialResult + tx.amount
            }
            return last.balance + delta
        } else {
            let txs = account.transactions.filter { !$0.isExcluded && $0.datePosted <= date && $0.datePosted >= minValidDataDate }
            return txs.reduce(Decimal(0)) { partialResult, tx in
                partialResult + tx.amount
            }
        }
    }
    
    /// Computes the total liability magnitude (sum of negative balances as positive values)
    /// across all liability accounts at the given date.
    private func liabilityMagnitude(on date: Date) -> Decimal {
        var total: Decimal = 0
        for account in liabilities {
            let v = value(for: account, on: date)
            if v < 0 {
                total += -v
            }
        }
        return total
    }
    
    private func earliestLiabilityDataDate() -> Date? {
        let now = Date()
        var earliest: Date? = nil
        for account in liabilities {
            for snap in account.balanceSnapshots where !snap.isExcluded && snap.asOfDate >= minValidDataDate && snap.asOfDate <= now {
                if let e = earliest {
                    if snap.asOfDate < e { earliest = snap.asOfDate }
                } else {
                    earliest = snap.asOfDate
                }
            }
            for tx in account.transactions where !tx.isExcluded && tx.datePosted >= minValidDataDate && tx.datePosted <= now {
                if let e = earliest {
                    if tx.datePosted < e { earliest = tx.datePosted }
                } else {
                    earliest = tx.datePosted
                }
            }
        }
        return earliest
    }
    
    private func yearsWithLiabilityData() -> Set<Int> {
        var years = Set<Int>()
        let cal = Calendar.current
        let now = Date()
        for account in liabilities {
            for snap in account.balanceSnapshots where !snap.isExcluded && snap.asOfDate <= now && snap.asOfDate >= minValidDataDate {
                years.insert(cal.component(.year, from: snap.asOfDate))
            }
            for tx in account.transactions where !tx.isExcluded && tx.datePosted <= now && tx.datePosted >= minValidDataDate {
                years.insert(cal.component(.year, from: tx.datePosted))
            }
        }
        return years
    }

    private func hasLiabilityData(in year: Int) -> Bool {
        // Consider a year to have data if any month ends with a non-zero liability magnitude
        for month in 1...12 {
            let date = endOfMonth(year: year, month: month)
            if liabilityMagnitude(on: date) > 0 {
                return true
            }
        }
        return false
    }

    private func previousAvailableYear(from year: Int, minYear: Int) -> Int? {
        guard year - 1 >= minYear else { return nil }
        var y = year - 1
        while y >= minYear {
            if hasLiabilityData(in: y) { return y }
            y -= 1
        }
        return nil
    }

    private func latestAvailableYear(upTo year: Int, minYear: Int) -> Int? {
        var y = year
        while y >= minYear {
            if hasLiabilityData(in: y) { return y }
            y -= 1
        }
        return nil
    }
    
    private var defaultStrategy: PayoffStrategy {
        // Handle both numeric strings ("0", "1", "2") and named strings ("minimumsOnly", "snowball", "avalanche")
        let raw = settings.defaultPayoffStrategyRaw

        // Try to parse as an integer first
        if let intValue = Int(raw) {
            switch intValue {
            case 0:
                return .minimumsOnly
            case 1:
                return .snowball
            case 2:
                return .avalanche
            default:
                break
            }
        }

        // Fallback: compare lowercased string names
        switch raw.lowercased() {
        case "minimumsonly", "minimums_only", "minimums-minus", "minimums":
            return .minimumsOnly
        case "snowball":
            return .snowball
        case "avalanche":
            return .avalanche
        default:
            return .minimumsOnly
        }
    }
    
    private func strategyDisplayName(_ s: PayoffStrategy) -> String {
        switch s {
        case .minimumsOnly:
            return "Minimums only"
        case .snowball:
            return "Snowball"
        case .avalanche:
            return "Avalanche"
        }
    }
    
    private func monthlyPayment(for account: Account, balance: Decimal) -> Decimal {
        if let payment = account.loanTerms?.paymentAmount, payment > 0 {
            return payment
        }
        // 2% of balance, rounded to 2 decimals
        let payment = (balance * Decimal(0.02)).rounded(scale: 2)
        return payment > 0 ? payment : Decimal(0)
    }
    
    private func buildMonthlyPoints(net: Decimal, year: Int, strategy: PayoffStrategy) -> [MonthlyPoint] {
        let now = Date()
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: now)
        let currentMonth = calendar.component(.month, from: now)
        
        var points: [MonthlyPoint] = []
        let firstDataDate = earliestLiabilityDataDate()
        let firstDataMonthStart: Date? = {
            guard let d = firstDataDate else { return nil }
            let y = calendar.component(.year, from: d)
            let m = calendar.component(.month, from: d)
            return calendar.date(from: DateComponents(year: y, month: m, day: 1))
        }()
        
        // Actual history points
        for month in 1...12 {
            let date = endOfMonth(year: year, month: month)
            let type: MonthlyPoint.PointType
            
            if year < currentYear {
                type = .actual
            } else if year > currentYear {
                type = .projected
            } else {
                // For the current year, include the current month as actual to avoid a gap.
                type = (month <= currentMonth) ? .actual : .projected
            }
            
            if type == .actual {
                // Skip months that occur before any liability data exists to avoid fictitious balances
                if let firstDataMonthStart, date < firstDataMonthStart {
                    continue
                }
                let total = liabilityMagnitude(on: date)
                points.append(MonthlyPoint(month: month, value: NSDecimalNumber(decimal: total).doubleValue, type: .actual))
            }
        }
        
        // Projection points
        let startMonth: Int
        if year > currentYear {
            startMonth = 1
        } else if year == currentYear {
            // Start projections next month; the current month remains solid (actual).
            startMonth = currentMonth + 1
        } else {
            // Past years have no projection
            return points
        }
        
        // If projecting a future year, compute carry-forward balances from the previous year's projection
        var carryForward: [UUID: Decimal] = [:]
        if year > currentYear {
            // Build a plan for the remainder of the current year to get end-of-year balances
            let cfStartMonth: Int = {
                if currentYear == calendar.component(.year, from: now) {
                    return min(12, currentMonth + 1)
                } else {
                    return 1
                }
            }()
            if cfStartMonth <= 12 {
                if let cfStartDate = calendar.date(from: DateComponents(year: currentYear, month: cfStartMonth, day: 1)) {
                    var cfDebts: [DebtInput] = []
                    // Seed from actuals as of the end of the month before cfStartMonth
                    let prevMonthForCF = cfStartMonth - 1
                    let prevCFDate: Date = (prevMonthForCF >= 1) ? endOfMonth(year: currentYear, month: prevMonthForCF) : endOfMonth(year: currentYear - 1, month: 12)
                    for account in liabilities {
                        let v = value(for: account, on: prevCFDate)
                        let balMag = v < 0 ? -v : Decimal(0)
                        if balMag > 0 {
                            let input = DebtInput(
                                id: account.id,
                                name: account.name,
                                apr: account.loanTerms?.apr,
                                balance: balMag,
                                minPayment: monthlyPayment(for: account, balance: balMag)
                            )
                            cfDebts.append(input)
                        }
                    }
                    if !cfDebts.isEmpty {
                        let cfBudget = effectiveBudget(for: net, debts: cfDebts, strategy: strategy)
                        if let cfPlan = try? DebtPayoffEngine.plan(debts: cfDebts, monthlyBudget: cfBudget, strategy: strategy, reinvestmentRate: Decimal(debtPaymentReinvestmentRate), startDate: cfStartDate) {
                            // Capture balances for December of the year before the selected year (end-of-year carry forward into the selected year)
                            let targetYear = year - 1
                            let decDate = endOfMonth(year: targetYear, month: 12)
                            if let cfMonth = cfPlan.months.first(where: { calendar.isDate($0.date, equalTo: decDate, toGranularity: .month) }) {
                                for (debtId, balance) in cfMonth.balances {
                                    carryForward[debtId] = balance
                                }
                            } else if let lastMonth = cfPlan.months.last {
                                // Fallback: if we didn't reach December, use the last planned month
                                for (debtId, balance) in lastMonth.balances {
                                    carryForward[debtId] = balance
                                }
                            }
                        }
                    }
                }
            }
        }
        
        // Bridge current month with projected series to avoid a visual gap
        if year == currentYear {
            if let currentActual = points.last(where: { $0.type == .actual && $0.month == currentMonth }) {
                points.append(MonthlyPoint(month: currentMonth, value: currentActual.value, type: .projected))
            }
        }
        
        guard startMonth <= 12 else {
            return points
        }
        
        // Prepare debts for DebtPayoffEngine
        var debts: [DebtInput] = []
        
        for account in liabilities {
            // Get balance magnitude at end of previous month (or carry-forward for future years)
            let prevMonth = startMonth - 1
            let prevDate: Date = (prevMonth >= 1) ? endOfMonth(year: year, month: prevMonth) : endOfMonth(year: year - 1, month: 12)

            let val: Decimal
            if year > currentYear, let cfBal = carryForward[account.id] {
                // Use projected carry-forward balance for future years
                // cfBal is already a magnitude for liabilities
                val = -cfBal
            } else {
                // Use historical snapshot-derived value
                val = value(for: account, on: prevDate)
            }
            let bal = val < 0 ? -val : Decimal(0)
            if bal > 0 {
                let input = DebtInput(
                    id: account.id,
                    name: account.name,
                    apr: account.loanTerms?.apr,
                    balance: bal,
                    minPayment: monthlyPayment(for: account, balance: bal)
                )
                debts.append(input)
            }
        }
        
        if debts.isEmpty {
            return points
        }
        
        // IncomeScheduler budget schedule for variable budget path
        let schedule: [Date: Decimal]
        do {
            let allocations = try modelContext.fetch(FetchDescriptor<BillFundingAllocation>())
            schedule = IncomeScheduler.budgetByMonth(
                items: try modelContext.fetch(FetchDescriptor<CashFlowItem>()),
                start: {
                    let comps = DateComponents(year: year, month: startMonth, day: 1)
                    return calendar.date(from: comps) ?? Date()
                }(),
                months: 60,
                includeSpreads: includeNonMonthlyIncomeSpreads,
                oneTimeDefaultSpreadMonths: [3,6,12].contains(oneTimeIncomeDefaultSpreadMonths) ? oneTimeIncomeDefaultSpreadMonths : 12,
                baselineSource: baselineSource,
                incomeFundingAllocations: IncomeScheduler.incomeFundingAllocationTotals(from: allocations)
            )
        } catch {
            schedule = [:]
        }
        
        let startDate: Date = {
            let comps = DateComponents(year: year, month: startMonth, day: 1)
            return calendar.date(from: comps) ?? Date()
        }()
        
        var plan: DebtPlanResult?
        do {
            if includeNonMonthlyIncomeSpreads || baselineBudgetSourceRaw == "recurringNet" {
                plan = try DebtPayoffEngine.plan(
                    debts: debts,
                    budgetByMonth: schedule,
                    strategy: strategy,
                    reinvestmentRate: Decimal(debtPaymentReinvestmentRate),
                    startDate: startDate
                )
            } else {
                let budget = effectiveBudget(for: net, debts: debts, strategy: strategy)
                plan = try DebtPayoffEngine.plan(
                    debts: debts,
                    monthlyBudget: budget,
                    strategy: strategy,
                    reinvestmentRate: Decimal(debtPaymentReinvestmentRate),
                    startDate: startDate
                )
            }
        } catch DebtPlanError.infeasibleBudget(let requiredMin) {
            plan = nil
            // Record the required minimum; defer alert presentation to when editing ends.
            DispatchQueue.main.async {
                self.requiredMinimumForBudget = requiredMin
            }
        } catch {
            plan = nil
        }
        if plan != nil {
            DispatchQueue.main.async {
                if self.requiredMinimumForBudget != nil {
                    self.requiredMinimumForBudget = nil
                }
            }
        }
        
        var lastKnownBalances: [UUID: Decimal] = [:]
        if let plan = plan {
            // Seed lastKnownBalances from the first planned month, if available.
            if let firstMonth = plan.months.first {
                // Assuming balances are keyed by debtId: UUID to balance: Decimal
                for (debtId, balance) in firstMonth.balances {
                    lastKnownBalances[debtId] = balance
                }
            }
        }
        
        for monthIndex in 0..<(12 - startMonth + 1) {
            let month = startMonth + monthIndex
            let monthDateComps = DateComponents(year: year, month: month, day: 1)
            guard let monthDate = calendar.date(from: monthDateComps) else {
                continue
            }
            var sum: Decimal = Decimal(0)
            if let plan = plan {
                // Find the plan month matching this chart month by month granularity
                if let planMonth = plan.months.first(where: { calendar.isDate($0.date, equalTo: monthDate, toGranularity: .month) }) {
                    for (debtId, balance) in planMonth.balances {
                        sum += balance
                        lastKnownBalances[debtId] = balance
                    }
                } else {
                    // If no plan month found, fallback to sum last known balances
                    sum = lastKnownBalances.values.reduce(Decimal(0), +)
                }
            } else {
                // No plan available, naive projection: reuse last known or zero
                sum = lastKnownBalances.values.reduce(Decimal(0), +)
            }
            points.append(MonthlyPoint(month: month, value: NSDecimalNumber(decimal: sum).doubleValue, type: .projected))
        }
        
        return points
    }
    
    private func effectiveBudget(for net: Decimal, debts: [DebtInput]? = nil, strategy: PayoffStrategy) -> Decimal {
        if useFixedDebtBudget, debtBudgetOverrideAmount > 0 {
            return Decimal(debtBudgetOverrideAmount)
        }
        
        if strategy == .minimumsOnly {
            return debts?.reduce(Decimal(0)) { partialResult, debt in
                partialResult + debt.minPayment
            } ?? Decimal(0)
        }
        
        if settings.useNetForDebtBudgetDefault && net > 0 {
            return net
        }
        
        if let debts = debts, !debts.isEmpty {
            let sumMin = debts.reduce(Decimal(0)) { partialResult, debt in
                partialResult + debt.minPayment
            }
            return max(net, sumMin)
        }
        
        return net
    }
    
    private func formatCurrencyDecimal(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = settings.currencyCode
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }
    
    private func formatCurrency(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = settings.currencyCode
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
    
    private func shortMonthName(_ month: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        return formatter.shortMonthSymbols[(month - 1) % 12]
    }
}

private struct ViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension Decimal {
    /// Rounds the decimal to the specified scale using plain rounding mode
    func rounded(scale: Int, mode: NSDecimalNumber.RoundingMode = .plain) -> Decimal {
        var result = Decimal()
        var value = self
        NSDecimalRound(&result, &value, scale, mode)
        return result
    }
}

#if os(iOS)
import UIKit

struct CurrencyTextField: UIViewRepresentable {
    var placeholder: String
    @Binding var value: Double
    var currencyCode: String
    @Binding var selectionTrigger: Int
    @Binding var isEditing: Bool

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(frame: .zero)
        tf.keyboardType = .decimalPad
        tf.borderStyle = .roundedRect
        tf.placeholder = placeholder
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        tf.text = context.coordinator.format(value: value, currencyCode: currencyCode)

        // Prevent horizontal expansion
        tf.setContentHuggingPriority(.required, for: .horizontal)
        tf.setContentCompressionResistancePriority(.required, for: .horizontal)
        tf.setContentHuggingPriority(.required, for: .vertical)
        tf.setContentCompressionResistancePriority(.required, for: .vertical)

        // Keep a reference to the text field in the coordinator
        context.coordinator.textField = tf

        // Add an input accessory toolbar with a trailing checkmark to finalize and dismiss
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(image: UIImage(systemName: "checkmark.circle.fill"), style: .done, target: context.coordinator, action: #selector(Coordinator.doneTapped))
        done.accessibilityLabel = "Done"
        toolbar.items = [flex, done]
        tf.inputAccessoryView = toolbar

        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        // Update placeholder and keyboard if needed
        uiView.placeholder = placeholder
        uiView.keyboardType = .decimalPad
        context.coordinator.currencyCode = currencyCode
        context.coordinator.valueBinding = $value

        // If not editing, keep text in sync with the bound value
        if context.coordinator.isEditing == false {
            let formatted = context.coordinator.format(value: value, currencyCode: currencyCode)
            if uiView.text != formatted {
                uiView.text = formatted
            }
        }

        // Trigger select-all and focus when selectionTrigger changes
        if context.coordinator.lastSelectionTrigger != selectionTrigger {
            context.coordinator.lastSelectionTrigger = selectionTrigger
            uiView.becomeFirstResponder()
            // Delay selectAll to ensure responder status
            DispatchQueue.main.async {
                uiView.selectAll(nil)
            }
        }
    }

    @available(iOS 16.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize {
        // Keep a compact, consistent height for the text field
        let targetHeight: CGFloat = 36
        let width = proposal.width ?? uiView.intrinsicContentSize.width
        return CGSize(width: width, height: targetHeight)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(valueBinding: $value, currencyCode: currencyCode, isEditingBinding: $isEditing)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        var valueBinding: Binding<Double>
        var currencyCode: String
        var isEditing: Bool = false
        var lastSelectionTrigger: Int = 0
        var isEditingBinding: Binding<Bool>
        weak var textField: UITextField?

        init(valueBinding: Binding<Double>, currencyCode: String, isEditingBinding: Binding<Bool>) {
            self.valueBinding = valueBinding
            self.currencyCode = currencyCode
            self.isEditingBinding = isEditingBinding
        }

        @objc func editingChanged(_ sender: UITextField) {
            guard let text = sender.text else { return }
            if let number = parse(text: text, currencyCode: currencyCode) {
                valueBinding.wrappedValue = number
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            isEditing = true
            isEditingBinding.wrappedValue = true
            // Select all text when editing begins
            DispatchQueue.main.async {
                textField.selectAll(nil)
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            isEditing = false
            isEditingBinding.wrappedValue = false
            // Reformat to currency when editing ends
            textField.text = format(value: valueBinding.wrappedValue, currencyCode: currencyCode)
        }

        @objc func doneTapped() {
            if let tf = textField {
                if let text = tf.text, let number = parse(text: text, currencyCode: currencyCode) {
                    valueBinding.wrappedValue = number
                }
                isEditing = false
                isEditingBinding.wrappedValue = false
                tf.resignFirstResponder()
                tf.text = format(value: valueBinding.wrappedValue, currencyCode: currencyCode)
            } else {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }

        func format(value: Double, currencyCode: String) -> String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currencyCode
            formatter.maximumFractionDigits = 2
            return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        }

        func parse(text: String, currencyCode: String) -> Double? {
            // Try using a currency formatter first
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currencyCode
            formatter.maximumFractionDigits = 2
            if let num = formatter.number(from: text) {
                return num.doubleValue
            }
            // Fallback: parse using decimal separator for current locale
            let decFormatter = NumberFormatter()
            decFormatter.numberStyle = .decimal
            decFormatter.maximumFractionDigits = 2
            if let num = decFormatter.number(from: text) {
                return num.doubleValue
            }
            // Last resort: strip non-numeric except decimal separator
            let locale = Locale.current
            let decimalSeparator = locale.decimalSeparator ?? "."
            let allowed = Set("0123456789" + decimalSeparator)
            let filtered = text.filter { allowed.contains($0) }
            return Double(filtered.replacingOccurrences(of: decimalSeparator, with: "."))
        }
    }
}
#endif

// MARK: - Preview

struct DebtProjectionChartView_Previews: PreviewProvider {
#if compiler(>=6)
    static let sampleItems: [CashFlowItem] = []
#else
    static let sampleItems: [CashFlowItem] = []
#endif
    
    static var previews: some View {
        DebtProjectionChartView(items: sampleItems)
            .environmentObject({ let store = SettingsStore(); store.currencyCode = "USD"; return store }())
    }
}

