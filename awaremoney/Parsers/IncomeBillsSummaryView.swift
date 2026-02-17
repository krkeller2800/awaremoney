import SwiftUI
import SwiftData

struct IncomeBillsSummaryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CashFlowItem.createdAt, order: .reverse) private var items: [CashFlowItem]

    private var monthlyIncomeTotal: Decimal {
        items.filter { $0.isIncome }.reduce(0) { $0 + ($1.amount * $1.frequency.monthlyEquivalentFactor) }
    }
    private var monthlyBillsTotal: Decimal {
        items.filter { !$0.isIncome }.reduce(0) { $0 + ($1.amount * $1.frequency.monthlyEquivalentFactor) }
    }
    private var monthlyNetForDebt: Decimal { monthlyIncomeTotal - monthlyBillsTotal }

    var body: some View {
        List {
            Section("Monthly Summary") {
                LabeledContent("Income") { Text(formatCurrency(monthlyIncomeTotal)) }
                LabeledContent("Bills") { Text(formatCurrency(monthlyBillsTotal)) }
                LabeledContent("Net for Debt") { Text(formatCurrency(monthlyNetForDebt)) }
                    .foregroundStyle(monthlyNetForDebt < 0 ? .red : .primary)
            }
        }
        .navigationTitle("Summary")
        .listStyle(.insetGrouped)
    }

    private func formatCurrency(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = "USD"
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }
}
