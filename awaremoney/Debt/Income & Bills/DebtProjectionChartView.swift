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
    
    @AppStorage("useFixedDebtBudget") private var useFixedDebtBudget: Bool = false
    @AppStorage("debtBudgetOverrideAmount") private var debtBudgetOverrideAmount: Double = 0
    
    private let items: [CashFlowItem]
    
    @State private var selectedYear: Int
    @State private var selectedStrategy: PayoffStrategy = .minimumsOnly
    @State private var amountSelectionTrigger: Int = 0
    
    init(items: [CashFlowItem]) {
        self.items = items
        _selectedYear = State(initialValue: Calendar.current.component(.year, from: Date()))
    }
    
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Button {
                    selectedYear -= 1
                } label: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityLabel("Previous year")
                
                Spacer()
                
                Text(String(selectedYear))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                
                Spacer()
                
                Button {
                    selectedYear += 1
                } label: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityLabel("Next year")
            }
            .padding(.horizontal)
            .padding(.top)
            
            let monthlyNet = calculateMonthlyNet()
            
            Text("Budget: \(formatCurrencyDecimal(effectiveBudget(for: monthlyNet, strategy: selectedStrategy))) • Strategy: \(strategyDisplayName(selectedStrategy))")
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

                    // Trailing amount area that maintains constant width across toggle states
                    ZStack(alignment: .trailing) {
                        // Editable amount UI (shown when toggle is on)
                        Group {
#if os(iOS)
                            HStack(spacing: 6) {
                                CurrencyTextField(placeholder: "Amount", value: $debtBudgetOverrideAmount, currencyCode: settings.currencyCode, selectionTrigger: $amountSelectionTrigger)
                                Button {
                                    amountSelectionTrigger += 1
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Edit amount")
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(height: 36)
#else
                            TextField("Amount", value: $debtBudgetOverrideAmount, format: .currency(code: settings.currencyCode))
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

            }
            .padding(.horizontal)
            
            Chart {
                RuleMark(y: .value("Zero", 0))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.gray.opacity(0.5))
                
                let points = buildMonthlyPoints(net: monthlyNet, year: selectedYear, strategy: selectedStrategy)
                let actualPoints = points.filter { $0.type == .actual }
                let projectedPoints = points.filter { $0.type == .projected }
                
                if !actualPoints.isEmpty {
                    ForEach(actualPoints) { point in
                        LineMark(
                            x: .value("Month", point.month),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(Color.accentColor)
                        .interpolationMethod(.catmullRom)
                    }
                }
                
                if !projectedPoints.isEmpty {
                    ForEach(projectedPoints) { point in
                        LineMark(
                            x: .value("Month", point.month),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(Color.secondary)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                }
            }
            .chartXScale(domain: 1...12)
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
            .padding(.horizontal)
            .frame(minHeight: 200)
        }
        .onAppear {
            // Initialize from current settings when the view appears
            selectedStrategy = defaultStrategy
        }
        .onChange(of: selectedStrategy) { newValue in
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
    
    private func value(for account: Account, on date: Date) -> Decimal {
        let snaps = account.balanceSnapshots.filter { !$0.isExcluded && $0.asOfDate <= date }
        if let last = snaps.max(by: { $0.asOfDate < $1.asOfDate }) {
            let txs = account.transactions.filter {
                !$0.isExcluded && $0.datePosted > last.asOfDate && $0.datePosted <= date
            }
            let delta = txs.reduce(Decimal(0)) { partialResult, tx in
                partialResult + tx.amount
            }
            return last.balance + delta
        } else {
            let txs = account.transactions.filter { !$0.isExcluded && $0.datePosted <= date }
            return txs.reduce(Decimal(0)) { partialResult, tx in
                partialResult + tx.amount
            }
        }
    }
    
    private func liabilityMagnitude(on date: Date) -> Decimal {
        liabilities.reduce(Decimal(0)) { partialResult, account in
            let val = value(for: account, on: date)
            if val < 0 {
                return partialResult + (-val)
            } else {
                return partialResult
            }
        }
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
        
        // Actual history points
        for month in 1...12 {
            let date = endOfMonth(year: year, month: month)
            let type: MonthlyPoint.PointType
            
            if year < currentYear {
                type = .actual
            } else if year > currentYear {
                type = .projected
            } else {
                type = (month <= currentMonth) ? .actual : .projected
            }
            
            if type == .actual {
                let total = liabilityMagnitude(on: date)
                points.append(MonthlyPoint(month: month, value: NSDecimalNumber(decimal: total).doubleValue, type: .actual))
            }
        }
        
        // Projection points
        let startMonth: Int
        if year > currentYear {
            startMonth = 1
        } else if year == currentYear {
            startMonth = currentMonth + 1
        } else {
            // Past years have no projection
            return points
        }
        
        guard startMonth <= 12 else {
            return points
        }
        
        // Prepare debts for DebtPayoffEngine
        let startDateComps = DateComponents(year: year, month: startMonth, day: 1)
        guard let startDate = calendar.date(from: startDateComps) else {
            return points
        }
        
        var debts: [DebtInput] = []
        
        for account in liabilities {
            // Get balance magnitude at end of previous month
            let prevMonth = startMonth - 1
            let prevDate: Date
            if prevMonth >= 1 {
                prevDate = endOfMonth(year: year, month: prevMonth)
            } else {
                // Previous year December
                prevDate = endOfMonth(year: year - 1, month: 12)
            }
            let val = value(for: account, on: prevDate)
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
        
        let budget = effectiveBudget(for: net, debts: debts, strategy: strategy)
        
        let plan = try? DebtPayoffEngine.plan(debts: debts, monthlyBudget: budget, strategy: strategy, startDate: startDate)
        
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
                // Find the plan month matching this chart month by date
                if let planMonth = plan.months.first(where: { calendar.isDate($0.date, inSameDayAs: monthDate) }) {
                    // Assuming balances is a [UUID: Decimal] dictionary
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
        Coordinator(valueBinding: $value, currencyCode: currencyCode)
    }

    class Coordinator: NSObject, UITextFieldDelegate {
        var valueBinding: Binding<Double>
        var currencyCode: String
        var isEditing: Bool = false
        var lastSelectionTrigger: Int = 0

        init(valueBinding: Binding<Double>, currencyCode: String) {
            self.valueBinding = valueBinding
            self.currencyCode = currencyCode
        }

        @objc func editingChanged(_ sender: UITextField) {
            guard let text = sender.text else { return }
            if let number = parse(text: text, currencyCode: currencyCode) {
                valueBinding.wrappedValue = number
            }
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            isEditing = true
            // Select all text when editing begins
            DispatchQueue.main.async {
                textField.selectAll(nil)
            }
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            isEditing = false
            // Reformat to currency when editing ends
            textField.text = format(value: valueBinding.wrappedValue, currencyCode: currencyCode)
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


