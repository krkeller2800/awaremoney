import SwiftUI
import SwiftData

struct IncomeBillsSummarySections: View {
    let items: [CashFlowItem]

    // MARK: - Computed data
    private var incomes: [CashFlowItem] { items.filter { $0.isIncome } }
    private var bills: [CashFlowItem] { items.filter { !$0.isIncome } }

    private func monthlyEquivalent(_ item: CashFlowItem) -> Decimal {
        item.amount * item.frequency.monthlyEquivalentFactor
    }

    private var monthlyIncomeTotal: Decimal {
        incomes.reduce(0) { $0 + monthlyEquivalent($1) }
    }
    private var monthlyBillsTotal: Decimal {
        bills.reduce(0) { $0 + monthlyEquivalent($1) }
    }
    private var monthlyNetForDebt: Decimal { monthlyIncomeTotal - monthlyBillsTotal }

    private var billsToIncomeRatio: Double {
        guard monthlyIncomeTotal > 0 else { return 0 }
        let ratio = (monthlyBillsTotal as NSDecimalNumber).doubleValue / (monthlyIncomeTotal as NSDecimalNumber).doubleValue
        return max(0, min(1, ratio))
    }

    private var averageBill: Decimal {
        guard !bills.isEmpty else { return 0 }
        return monthlyBillsTotal / Decimal(bills.count)
    }

    private var topBills: [CashFlowItem] {
        Array(bills.sorted { monthlyEquivalent($0) > monthlyEquivalent($1) }.prefix(5))
    }

    private var billFrequencyCounts: [(label: String, count: Int)] {
        let groups = Dictionary(grouping: bills, by: { $0.frequency.displayLabel })
        return groups.map { (key, value) in (key, value.count) }
            .sorted { $0.count > $1.count }
    }

    private var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    // MARK: - Body (Sections-only, embed in a List)
    var body: some View {
        Group {
            if isPad {
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        metricCard(title: "Net for Debt", value: formatCurrency(monthlyNetForDebt), valueColor: monthlyNetForDebt < 0 ? .red : .primary)
                        metricCard(title: "Income", value: formatCurrency(monthlyIncomeTotal))
                        metricCard(title: "Bills", value: formatCurrency(monthlyBillsTotal))
                        utilizationMetricCard()
                        metricCard(title: "Avg Bill", value: formatCurrency(averageBill))
                    }
                    .padding(.vertical, 4)
                }

                if !topBills.isEmpty {
                    Section("Top Bills (Monthly Equivalent)") {
                        ForEach(topBills, id: \.id) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name).font(.headline)
                                    Text(item.frequency.displayLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(formatCurrency(monthlyEquivalent(item)))
                            }
                        }
                    }
                }

                if !billFrequencyCounts.isEmpty {
                    Section("Bills by Frequency") {
                        ForEach(billFrequencyCounts, id: \.label) { entry in
                            LabeledContent(entry.label) { Text("\(entry.count)") }
                        }
                    }
                }
            } else {
                Section("Monthly Summary") {
                    LabeledContent("Income") { Text(formatCurrency(monthlyIncomeTotal)) }
                    LabeledContent("Bills") { Text(formatCurrency(monthlyBillsTotal)) }
                    LabeledContent("Net for Debt") { Text(formatCurrency(monthlyNetForDebt)) }
                        .foregroundStyle(monthlyNetForDebt < 0 ? .red : .primary)

                    if monthlyIncomeTotal > 0 {
                        LabeledContent("Bills / Income") {
                            VStack(alignment: .trailing, spacing: 6) {
                                Text("\(Int(billsToIncomeRatio * 100))%")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                if #available(iOS 17.0, *) {
                                    Gauge(value: billsToIncomeRatio) { Text("") }
                                        .gaugeStyle(.linearCapacity)
                                        .tint(billsToIncomeRatio > 0.8 ? .red : (billsToIncomeRatio > 0.6 ? .orange : .green))
                                        .frame(height: 12)
                                } else {
                                    Gauge(value: billsToIncomeRatio) { Text("") }
                                        .gaugeStyle(.accessoryLinear)
                                        .tint(billsToIncomeRatio > 0.8 ? .red : (billsToIncomeRatio > 0.6 ? .orange : .green))
                                        .frame(height: 12)
                                }
                            }
                        }
                    } else {
                        Text("Add income to see utilization.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Metric cards
    @ViewBuilder
    private func metricCard(title: String, value: String, valueColor: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3)
                .bold()
                .foregroundStyle(valueColor ?? .primary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08))
        )
    }

    @ViewBuilder
    private func utilizationMetricCard() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Utilization")
                .font(.caption)
                .foregroundStyle(.secondary)
            if monthlyIncomeTotal > 0 {
                HStack {
                    Text("\(Int(billsToIncomeRatio * 100))%")
                        .font(.title3)
                        .bold()
                        .foregroundStyle(billsToIncomeRatio > 0.8 ? .red : (billsToIncomeRatio > 0.6 ? .orange : .green))
                    Spacer()
                }
                if #available(iOS 17.0, *) {
                    Gauge(value: billsToIncomeRatio) { Text("") }
                        .gaugeStyle(.linearCapacity)
                        .tint(billsToIncomeRatio > 0.8 ? .red : (billsToIncomeRatio > 0.6 ? .orange : .green))
                        .frame(height: 12)
                } else {
                    Gauge(value: billsToIncomeRatio) { Text("") }
                        .gaugeStyle(.accessoryLinear)
                        .tint(billsToIncomeRatio > 0.8 ? .red : (billsToIncomeRatio > 0.6 ? .orange : .green))
                        .frame(height: 12)
                }
            } else {
                Text("—")
                    .font(.title3)
                    .bold()
                Text("Add income to see utilization.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08))
        )
    }

    // MARK: - Formatting
    private func formatCurrency(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }
}
