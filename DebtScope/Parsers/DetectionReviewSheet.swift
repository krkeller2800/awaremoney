import SwiftUI

struct DetectionReviewSheet: View {
    let detection: IntakeDetection
    let url: URL
    @Binding var selectedType: StatementType?
    @Binding var editedInstitution: String
    @Binding var bankSubtype: QuickIngestAccountType?
    @Binding var monthlyPaymentInput: String
    @Binding var aprPercentInput: String
    @Binding var balanceInput: String
    let account: Account?
    let latestBalance: Decimal?
    @Binding var isQuickIngesting: Bool
    let onSave: (IntakeDetection, URL) -> Void
    let onDiscard: () -> Void

    // Local payoff state
    @State private var computedPayoffDate: Date? = nil
    @State private var nonReducingPayment: Bool = false

    // Focus management
    @FocusState private var focusedField: FocusedField?
    private enum FocusedField: Hashable {
        case institution
        case monthlyPayment
        case aprPercent
        case endingBalance
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HStack(spacing: 0) {
                    leftColumn
                        .frame(minWidth: 320, maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)
                        .padding()

                    Divider()

                    PDFPreview(url: url)
                        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
                        .background(.quaternary.opacity(0.1))
                }

                if isQuickIngesting {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.large)
                        Text("Ingesting…")
                            .font(.headline)
                    }
                    .padding(20)
                    .background(.ultraThickMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(radius: 12)
                }
            }
            .navigationTitle("Import Ready")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard") { onDiscard() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveAction() }
                }
            }
            .onAppear { prefillAndCompute() }
            .onChange(of: focusedField) { oldValue, newValue in
                handleFocusChange(from: oldValue, to: newValue)
            }
        }
    }

    // MARK: - Left Column
    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review detected details and make changes if needed.")
                .foregroundStyle(.secondary)

            // Type picker
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Type")
                Spacer()
                Picker("Type", selection: $selectedType) {
                    Text("Choose…").tag(nil as StatementType?)
                    let types: [StatementType] = StatementType.allCases
                    ForEach(types, id: \.self) { t in
                        Text(displayName(for: t)).tag(t as StatementType?)
                    }
                }
                .pickerStyle(.menu)
            }

            // Confidence display
            HStack {
                Text("Confidence")
                Spacer()
                Text("\(Int(detection.confidence * 100))%")
                    .fontWeight(.semibold)
            }

            // Institution
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Institution")
                Spacer()
                HStack(spacing: 6) {
                    TextField("Institution", text: $editedInstitution)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .institution)
                        .frame(minWidth: 200)
                        .simultaneousGesture(TapGesture().onEnded {
                            focusedField = .institution
                            selectAll(.institution)
                        })
                    Button {
                        focusedField = .institution
                        selectAll(.institution)
                    } label: {
                        Image(systemName: "pencil")
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit institution")
                }
            }

            // Bank subtype if needed
            if selectedType == .bank {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Bank Subtype")
                    Spacer()
                    Picker("Bank Subtype", selection: $bankSubtype) {
                        Text("Auto").tag(nil as QuickIngestAccountType?)
                        Text("Checking").tag(QuickIngestAccountType.checking as QuickIngestAccountType?)
                        Text("Savings").tag(QuickIngestAccountType.savings as QuickIngestAccountType?)
                    }
                    .pickerStyle(.menu)
                }
            }

            // Payoff estimate
            if let acct = account, shouldShowPayoff(for: acct) {
                payoffSection(account: acct)
            }

            Spacer()
        }
    }

    // MARK: - Payoff Section
    @ViewBuilder
    private func payoffSection(account: Account) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().padding(.top, 4)

            Text("Payoff estimate")
                .font(.headline)

            // Monthly payment
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Monthly payment")
                Spacer()
                TextField("Amount", text: $monthlyPaymentInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140)
#if os(iOS) || os(visionOS)
                    .keyboardType(.decimalPad)
#endif
                    .focused($focusedField, equals: .monthlyPayment)
                    .simultaneousGesture(TapGesture().onEnded {
                        focusedField = .monthlyPayment
                        selectAll(.monthlyPayment)
                    })
            }

            // APR (%)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("APR (%)")
                Spacer()
                TextField("e.g., 19.99", text: $aprPercentInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140)
#if os(iOS) || os(visionOS)
                    .keyboardType(.decimalPad)
#endif
                    .focused($focusedField, equals: .aprPercent)
                    .simultaneousGesture(TapGesture().onEnded {
                        focusedField = .aprPercent
                        selectAll(.aprPercent)
                    })
            }

            // Ending/current balance
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Ending balance")
                Spacer()
                TextField("Amount", text: $balanceInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140)
#if os(iOS) || os(visionOS)
                    .keyboardType(.decimalPad)
#endif
                    .focused($focusedField, equals: .endingBalance)
                    .simultaneousGesture(TapGesture().onEnded {
                        focusedField = .endingBalance
                        selectAll(.endingBalance)
                    })
            }

            // Recalculate
            HStack {
                Button("Recalculate") {
                    computePayoff(using: account)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Spacer()
            }
            .padding(.top, 4)

            // Message
            let paymentDecimal: Decimal? = parseDecimalInput(monthlyPaymentInput) ?? account.loanTerms?.paymentAmount
            if let p = paymentDecimal, let date = computedPayoffDate {
                Text("If you pay \(formatCurrency(p)) each month, this will be paid off on \(date.formatted(date: .abbreviated, time: .omitted)).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let p = paymentDecimal, nonReducingPayment {
                Text("A monthly payment of \(formatCurrency(p)) won’t reduce this balance. Increase the payment to cover interest.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Enter amounts and tap Recalculate to see the estimated payoff date.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Actions
    private func saveAction() {
        var det = detection
        det.type = selectedType
        det.institution = editedInstitution.trimmingCharacters(in: .whitespacesAndNewlines)
        onSave(det, url)
    }

    private func prefillAndCompute() {
        guard let acct = account else { return }

        // Monthly payment from terms
        if monthlyPaymentInput.isEmpty, let p = acct.loanTerms?.paymentAmount {
            let nf = currencyFormatter()
            let num = NSDecimalNumber(decimal: p)
            if let s = nf.string(from: num) { monthlyPaymentInput = s }
        }

        // APR % from terms
        if aprPercentInput.isEmpty {
            let aprNormalized = normalizedAPR(from: acct.loanTerms?.apr)
            if let apr = aprNormalized {
                let nf = NumberFormatter()
                nf.numberStyle = .decimal
                nf.minimumFractionDigits = 2
                nf.maximumFractionDigits = 2
                let percent = apr * 100
                let num = NSDecimalNumber(decimal: percent)
                if let s = nf.string(from: num) { aprPercentInput = s }
            }
        }

        // Balance from latestBalance
        if balanceInput.isEmpty {
            if let bal = latestBalance {
                let nf = currencyFormatter()
                let absBal = abs(NSDecimalNumber(decimal: bal).doubleValue)
                let num = NSNumber(value: absBal)
                if let s = nf.string(from: num) { balanceInput = s }
            }
        }

        computePayoff(using: acct)
    }

    // MARK: - Helpers
    private func shouldShowPayoff(for account: Account) -> Bool {
        switch account.type {
        case .creditCard, .loan:
            return true
        default:
            return false
        }
    }

    private func displayName(for type: StatementType) -> String {
        switch type {
        case .creditCard: return "Credit Card"
        case .bank:       return "Bank"
        case .brokerage:  return "Brokerage"
        case .loan:       return "Loan"
        }
    }

    private func currencyCodeFromSettings() -> String? {
        return AppFormatters.currencyCodeFromSettings()
    }

    private func currencyFormatter() -> NumberFormatter {
        return AppFormatters.currencyFormatter()
    }

    private func formatCurrency(_ amount: Decimal) -> String {
        return AppFormatters.formatCurrency(amount)
    }

    private func parseDecimalInput(_ raw: String) -> Decimal? {
        return MoneyParsing.parseDecimalInput(raw)
    }

    private func parsePercentInput(_ raw: String) -> Decimal? {
        return MoneyParsing.parsePercentInput(raw)
    }

    private func formatCurrencyInput(_ text: inout String) {
        AppFormatters.formatCurrencyInput(&text)
    }

    private func formatPercentInput(_ text: inout String) {
        AppFormatters.formatPercentInput(&text)
    }

    private func normalizedAPR(from storedAPR: Decimal?) -> Decimal? {
        return MoneyParsing.normalizedAPR(from: storedAPR)
    }

    private func payoffDate(balance: Decimal, apr: Decimal, monthlyPayment: Decimal, from start: Date = Date()) -> Date? {
        return PayoffCalculator.payoffDate(balance: balance, apr: apr, monthlyPayment: monthlyPayment, from: start)
    }

    private func computePayoff(using account: Account) {
        let bal = parseDecimalInput(balanceInput) ?? latestBalance
        let apr = parsePercentInput(aprPercentInput) ?? normalizedAPR(from: account.loanTerms?.apr)
        let pmt = parseDecimalInput(monthlyPaymentInput) ?? account.loanTerms?.paymentAmount

        guard let bal, let apr, let pmt else {
            computedPayoffDate = nil
            nonReducingPayment = false
            return
        }

        if let date = payoffDate(balance: bal, apr: apr, monthlyPayment: pmt) {
            computedPayoffDate = date
            nonReducingPayment = false
        } else {
            computedPayoffDate = nil
            nonReducingPayment = true
        }
    }

    private func handleFocusChange(from oldValue: FocusedField?, to newValue: FocusedField?) {
        if oldValue == .monthlyPayment && newValue != .monthlyPayment { formatCurrencyInput(&monthlyPaymentInput) }
        if oldValue == .endingBalance && newValue != .endingBalance { formatCurrencyInput(&balanceInput) }
        if oldValue == .aprPercent && newValue != .aprPercent { formatPercentInput(&aprPercentInput) }

        if newValue == .monthlyPayment {
            selectAll(.monthlyPayment)
        } else if newValue == .endingBalance {
            selectAll(.endingBalance)
        } else if newValue == .aprPercent {
            selectAll(.aprPercent)
        }
    }

    private func selectAll(_ field: FocusedField) {
        focusedField = field
#if canImport(UIKit)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
        }
#elseif canImport(AppKit)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        }
#endif
    }
}

#if DEBUG
#Preview {
    struct DummySettings: View {
        @State var selectedType: StatementType? = .creditCard
        @State var editedInstitution: String = "BankCo"
        @State var bankSubtype: QuickIngestAccountType? = nil
        @State var monthlyPayment: String = "150.00"
        @State var aprPercent: String = "19.99"
        @State var balance: String = "1,200.00"
        @State var isIngesting: Bool = false

        var body: some View {
            DetectionReviewSheet(
                detection: IntakeDetection(type: .creditCard, institution: "BankCo", confidence: 0.85),
                url: URL(fileURLWithPath: "/dev/null"),
                selectedType: $selectedType,
                editedInstitution: $editedInstitution,
                bankSubtype: $bankSubtype,
                monthlyPaymentInput: $monthlyPayment,
                aprPercentInput: $aprPercent,
                balanceInput: $balance,
                account: nil,
                latestBalance: nil,
                isQuickIngesting: $isIngesting,
                onSave: { _, _ in },
                onDiscard: {}
            )
            .frame(minWidth: 800, minHeight: 600)
        }
    }
    return DummySettings()
}
#endif

