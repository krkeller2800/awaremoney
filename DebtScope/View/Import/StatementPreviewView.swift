import SwiftUI

struct StatementPreviewView: View {
    var staged: StagedImport
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !staged.transactions.isEmpty { transactionsSection }
                if !staged.balances.isEmpty { balancesSection }
                if !staged.holdings.isEmpty { holdingsSection }
            }
            .padding()
        }
//        .navigationTitle("Statement Preview")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let inst = staged.inferredInstitutionName, !inst.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(inst)
                    .font(.headline)
            }
            Text("File: \(staged.sourceFileName)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Text("Transactions: \(staged.transactions.count)")
                if !staged.holdings.isEmpty { Text("Holdings: \(staged.holdings.count)") }
                if !staged.balances.isEmpty { Text("Balances: \(staged.balances.count)") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var transactionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transactions")
//                .font(.headline)
            ForEach(staged.transactions.indices, id: \.self) { idx in
                let t = staged.transactions[idx]
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.payee).font(.caption)
                        HStack(spacing: 6) {
                            if let acct = t.sourceAccountLabel, !acct.isEmpty {
                                Text(acct.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            Text(t.datePosted, style: .date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(t.amount as NSNumber, formatter: currencyFormatter)
                        .foregroundStyle(t.amount < 0 ? .red : .primary)
                        .font(.caption)
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
    }

    private var balancesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Balances")
                .font(.headline)
            ForEach(staged.balances.indices, id: \.self) { idx in
                let b = staged.balances[idx]
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(b.asOfDate, style: .date)
                        Spacer()
                        Text(b.balance as NSNumber, formatter: currencyFormatter)
                            .font(.callout.weight(.semibold))
                    }
                    HStack(spacing: 6) {
                        if let label = b.sourceAccountLabel, !label.isEmpty {
                            Text(label.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        if let apr = b.interestRateAPR {
                            Text(formatAPR(apr, scale: b.interestRateScale))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        if let tp = b.typicalPaymentAmount, tp > 0 {
                            Text("Payment: \(currencyFormatter.string(from: NSDecimalNumber(decimal: tp)) ?? "")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12))
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
    }

    private var holdingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Holdings")
                .font(.headline)
            ForEach(staged.holdings.indices, id: \.self) { idx in
                let h = staged.holdings[idx]
                HStack(alignment: .firstTextBaseline) {
                    Text("\(h.symbol) — \(h.quantity.description)")
                    Spacer()
                    if let mv = h.marketValue {
                        Text(mv as NSNumber, formatter: currencyFormatter)
                            .font(.callout.weight(.semibold))
                    }
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
    }

    private var currencyFormatter: NumberFormatter {
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        nf.currencyCode = settings.currencyCode
        return nf
    }

    private func formatAPR(_ apr: Decimal, scale: Int?) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .percent
        if let s = scale { nf.minimumFractionDigits = s; nf.maximumFractionDigits = s } else { nf.minimumFractionDigits = 2; nf.maximumFractionDigits = 3 }
        return nf.string(from: NSDecimalNumber(decimal: apr)) ?? "\(apr)"
    }
}
