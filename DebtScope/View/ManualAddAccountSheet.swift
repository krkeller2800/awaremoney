import SwiftUI
import SwiftData

struct ManualAddAccountSheet: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore

    @Binding var selectedType: StatementType?
    @Binding var editedInstitution: String
    @Binding var bankSubtype: QuickIngestAccountType?
    @Binding var monthlyPaymentInput: String
    @Binding var aprPercentInput: String
    @Binding var balanceInput: String
    @State private var balanceDate: Date = Date()

    var onCancel: () -> Void
    var onSaved: (Account) -> Void

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                // Left column: mirrors Import Ready controls
                VStack(alignment: .leading, spacing: 16) {
                    Text("Enter the details for your account.")
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Type")
                        Spacer()
                        Picker("Type", selection: $selectedType) {
                            Text("Choose…").tag(nil as StatementType?)
                            ForEach(StatementType.allCases, id: \.self) { t in
                                Text(displayName(for: t)).tag(StatementType?.some(t))
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Institution")
                        Spacer()
                        TextField("Institution", text: $editedInstitution)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 200)
                    }

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

                    Divider().padding(.top, 4)
                    Text("Optional").font(.headline)

                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Monthly payment")
                        Spacer()
                        TextField("Amount", text: $monthlyPaymentInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 140)
#if os(iOS) || os(visionOS)
                            .keyboardType(.decimalPad)
#endif
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("APR (%)")
                        Spacer()
                        TextField("e.g., 19.99", text: $aprPercentInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 140)
#if os(iOS) || os(visionOS)
                            .keyboardType(.decimalPad)
#endif
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("Ending balance")
                        Spacer()
                        TextField("Amount", text: $balanceInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(minWidth: 140)
#if os(iOS) || os(visionOS)
                            .keyboardType(.decimalPad)
#endif
                    }
                    DatePicker("As of", selection: $balanceDate, displayedComponents: .date)
                        .datePickerStyle(.compact)

                    Spacer()
                }
                .frame(minWidth: 320, maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)
                .padding()

                Divider()

                // Right column: placeholder instead of PDF
                ContentUnavailableView(
                    "Statement Preview",
                    systemImage: "doc.richtext",
                    description: Text("PDF not provided")
                )
                .frame(minWidth: 400, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
                .background(.quaternary.opacity(0.1))
            }
            .navigationTitle("Add Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let account = createAccount() {
                            onSaved(account)
                        }
                    }
                    .disabled(selectedType == nil || editedInstitution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
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
