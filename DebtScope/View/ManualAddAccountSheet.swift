import SwiftUI
import SwiftData
#if canImport(UIKit)
import UIKit
#endif

struct ManualAddAccountSheet: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @Binding var selectedType: StatementType?
    @Binding var editedInstitution: String
    @Binding var bankSubtype: QuickIngestAccountType?
    @Binding var monthlyPaymentInput: String
    @Binding var aprPercentInput: String
    @Binding var balanceInput: String
    @State private var balanceDate: Date = Date()
    @State private var showDebtImpactPreview = false

    var onCancel: () -> Void
    var onSaved: (Account) -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add Account")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onCancel() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            formatMoneyInput(&monthlyPaymentInput)
                            formatAPRInput()
                            formatMoneyInput(&balanceInput)

                            if let account = createAccount() {
                                onSaved(account)
                            }
                        }
                        .disabled(selectedType == nil || editedInstitution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if horizontalSizeClass == .regular {
            HStack(spacing: 0) {
                manualAccountFormPanel
                    .frame(minWidth: 320, maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)
                    .padding()

                Divider()

                manualDebtImpactPreview
                    .frame(minWidth: 400, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity, alignment: .topLeading)
                    .background(.quaternary.opacity(0.1))
            }
        } else {
            VStack(spacing: 0) {
                manualAccountFormPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding()

                Spacer(minLength: 12)

                Button {
                    showDebtImpactPreview = true
                } label: {
                    Label("View Debt Impact", systemImage: "chart.line.uptrend.xyaxis")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .sheet(isPresented: $showDebtImpactPreview) {
                NavigationStack {
                    manualDebtImpactPreview
                        .navigationTitle("Debt Impact")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") {
                                    showDebtImpactPreview = false
                                }
                            }
                        }
                }
            }
        }
    }

    private var manualAccountFormPanel: some View {
        ManualAccountFormPanel(
            selectedType: $selectedType,
            editedInstitution: $editedInstitution,
            bankSubtype: $bankSubtype,
            monthlyPaymentInput: $monthlyPaymentInput,
            aprPercentInput: $aprPercentInput,
            balanceInput: $balanceInput,
            balanceDate: $balanceDate,
            onSave: {
                formatMoneyInput(&monthlyPaymentInput)
                formatAPRInput()
                formatMoneyInput(&balanceInput)

                if let account = createAccount() {
                    onSaved(account)
                }
            }
        )
    }

    
    private var manualDebtImpactPreview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Debt Impact")
                .font(.title3.weight(.semibold))

            Text("Preview based on the account details entered on the left.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                readOnlyImpactRow("Balance", formattedCurrency(parseDecimal(balanceInput)))
                readOnlyImpactRow("APR", formattedAPR(parseAPRPercent(aprPercentInput)?.0, scale: parseAPRPercent(aprPercentInput)?.1))
                readOnlyImpactRow("Monthly payment", formattedCurrency(parseDecimal(monthlyPaymentInput)))
            }

            Divider()

            if let summary = payoffPreviewSummary {
                VStack(alignment: .leading, spacing: 10) {
                    readOnlyImpactRow("Estimated payoff", summary.monthsText)
                    readOnlyImpactRow("Estimated interest", summary.interestText)
                    readOnlyImpactRow("Total paid", summary.totalPaidText)
                }
            } else {
                ContentUnavailableView(
                    "Enter loan details",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("Add a balance, APR, and monthly payment to preview payoff impact.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            }

            Spacer(minLength: 0)
        }
        .padding()
    }

    private func readOnlyImpactRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.body.monospacedDigit())
                .multilineTextAlignment(.trailing)
        }
    }

    private var payoffPreviewSummary: (monthsText: String, interestText: String, totalPaidText: String)? {
        guard let balance = parseDecimal(balanceInput),
              let payment = parseDecimal(monthlyPaymentInput),
              balance > 0,
              payment > 0 else {
            return nil
        }

        let apr = parseAPRPercent(aprPercentInput)?.0 ?? 0
        let result = estimatePayoff(balance: balance, apr: apr, monthlyPayment: payment)

        return (
            monthsText: result.months.map { formattedMonths($0) } ?? "Not enough payment",
            interestText: formattedCurrency(result.interest),
            totalPaidText: formattedCurrency(result.totalPaid)
        )
    }

    private func estimatePayoff(balance: Decimal, apr: Decimal, monthlyPayment: Decimal) -> (months: Int?, interest: Decimal, totalPaid: Decimal) {
        var remaining = NSDecimalNumber(decimal: balance).doubleValue
        let monthlyRate = NSDecimalNumber(decimal: apr).doubleValue / 12.0
        let payment = NSDecimalNumber(decimal: monthlyPayment).doubleValue
        var interestPaid = 0.0
        var totalPaid = 0.0
        var months = 0

        guard remaining > 0, payment > 0 else {
            return (nil, 0, 0)
        }

        while remaining > 0.005 && months < 1200 {
            let interest = max(0, remaining * monthlyRate)

            if payment <= interest && monthlyRate > 0 {
                return (nil, Decimal(interestPaid), Decimal(totalPaid))
            }

            let actualPayment = min(payment, remaining + interest)
            remaining = remaining + interest - actualPayment
            interestPaid += interest
            totalPaid += actualPayment
            months += 1
        }

        return (months, Decimal(interestPaid), Decimal(totalPaid))
    }

    private func formattedCurrency(_ value: Decimal?) -> String {
        guard let value else { return "—" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = settings.currencyCode
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }

    private func formattedAPR(_ value: Decimal?, scale: Int?) -> String {
        guard let value else { return "—" }
        let percent = NSDecimalNumber(decimal: value * 100)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = max(scale ?? 2, 2)
        formatter.minimumFractionDigits = min(scale ?? 2, 2)
        return (formatter.string(from: percent) ?? "—") + "%"
    }

    private func formattedMonths(_ months: Int) -> String {
        if months < 12 {
            return "\(months) mo"
        }

        let years = months / 12
        let rem = months % 12
        if rem == 0 {
            return "\(years) yr"
        }
        return "\(years) yr \(rem) mo"
    }

    private func formatMoneyInput(_ input: inout String) {
        guard let value = parseDecimal(input) else { return }
        input = formattedCurrency(value)
    }

    private func formatAPRInput() {
        guard let parsed = parseAPRPercent(aprPercentInput) else { return }
        aprPercentInput = formattedAPR(parsed.0, scale: parsed.1)
    }
    private func displayName(for t: StatementType) -> String {
        switch t {
        case .creditCard: return "Credit Card"
        case .bank: return "Bank"
        case .loan: return "Loan"
        case .brokerage: return "Brokerage"
        }
    }

    private func toAccountType(_ t: StatementType?, bankSubtype: QuickIngestAccountType?) -> Account.AccountType {
        guard let t else { return .other }
        switch t {
        case .creditCard: return .creditCard
        case .loan:       return .loan
        case .brokerage:  return .brokerage
        case .bank:
            switch bankSubtype {
            case .some(.savings): return .savings
            default: return .checking
            }
        }
    }

    private func parseDecimal(_ s: String) -> Decimal? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "-0123456789.,")
        let filtered = String(trimmed.unicodeScalars.filter { allowed.contains($0) })
        var normalized = filtered
        if filtered.contains(",") && filtered.contains(".") {
            normalized = filtered.replacingOccurrences(of: ",", with: "")
        } else if filtered.contains(",") && !filtered.contains(".") {
            normalized = filtered.replacingOccurrences(of: ",", with: ".")
        }
        return Decimal(string: normalized)
    }

    private func parseAPRPercent(_ s: String) -> (Decimal, Int)? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleaned = trimmed.replacingOccurrences(of: "%", with: "").replacingOccurrences(of: ",", with: ".")
        guard let dec = Decimal(string: cleaned) else { return nil }
        let scale: Int = cleaned.split(separator: ".").last.map { $0.count } ?? 0
        var fraction = dec
        if fraction > 1 { fraction /= 100 }
        return (fraction, scale)
    }

    private func createAccount() -> Account? {
        let type = toAccountType(selectedType, bankSubtype: bankSubtype)
        let inst = editedInstitution.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inst.isEmpty else { return nil }

        let acct = Account(
            name: inst,
            type: type,
            institutionName: inst,
            currencyCode: settings.currencyCode
        )
        modelContext.insert(acct)

        // Optional terms
        if let pmt = parseDecimal(monthlyPaymentInput), pmt > 0 || !aprPercentInput.isEmpty {
            var terms = acct.loanTerms ?? LoanTerms()
            if let p = parseDecimal(monthlyPaymentInput), p > 0 { terms.paymentAmount = p }
            if let (apr, scale) = parseAPRPercent(aprPercentInput) { terms.apr = apr; terms.aprScale = scale }
            acct.loanTerms = terms
        }

        // Optional starting/ending balance
        if let bal = parseDecimal(balanceInput) {
            let snap = BalanceSnapshot(
                asOfDate: balanceDate,
                balance: bal,
                interestRateAPR: acct.loanTerms?.apr,
                interestRateScale: acct.loanTerms?.aprScale,
                account: acct,
                importBatch: nil
            )
            modelContext.insert(snap)
        }

        do {
            try modelContext.save()
            NotificationCenter.default.post(name: .accountsDidChange, object: nil)
            return acct
        } catch {
            return nil
        }
    }
}

#Preview {
    @Previewable @State var t: StatementType? = .creditCard
    @Previewable @State var inst: String = ""
    @Previewable @State var subtype: QuickIngestAccountType? = nil
    @Previewable @State var pay: String = ""
    @Previewable @State var apr: String = ""
    @Previewable @State var bal: String = ""

    return ManualAddAccountSheet(
        selectedType: $t,
        editedInstitution: $inst,
        bankSubtype: $subtype,
        monthlyPaymentInput: $pay,
        aprPercentInput: $apr,
        balanceInput: $bal,
        onCancel: {},
        onSaved: { _ in }
    )
    .environmentObject(SettingsStore())
}
