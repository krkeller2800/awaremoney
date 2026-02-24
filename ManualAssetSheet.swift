import SwiftUI
import SwiftData
import Foundation

struct ManualAssetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: SettingsStore

    @State private var name: String = ""
    @State private var valueText: String = ""
    @State private var asOfDate: Date = Date()
    @State private var institution: String = ""

    // Liability linking support
    @Query(filter: #Predicate<Account> { $0.typeRaw == "loan" }) private var liabilityAccounts: [Account]
    @State private var selectedLiability: Account? = nil

    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let decimalValue = parseDecimal(from: valueText), decimalValue > 0 else { return false }
        return true
    }

    private var enteredAssetValue: Decimal? { parseDecimal(from: valueText) }

    private func latestBalance(for account: Account) -> Decimal {
        // Use the most recent BalanceSnapshot by asOfDate; if none, return 0
        let snaps = account.balanceSnapshots
        let latest = snaps.max(by: { $0.asOfDate < $1.asOfDate })
        return latest?.balance ?? 0
    }

    private var selectedLiabilityBalance: Decimal {
        guard let acct = selectedLiability else { return 0 }
        return latestBalance(for: acct)
    }

    private var selectedLiabilityDebtMagnitude: Decimal {
        let bal = selectedLiabilityBalance
        return bal < 0 ? -bal : bal
    }

    private var computedEquity: Decimal? {
        guard let assetValue = enteredAssetValue else { return nil }
        return assetValue - selectedLiabilityDebtMagnitude
    }

    private var computedLTV: Decimal? {
        guard let assetValue = enteredAssetValue, assetValue > 0 else { return nil }
        return selectedLiabilityDebtMagnitude / assetValue
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    TextField("Name", text: $name)
                    TextField("Description (optional)", text: $institution)
                    Label("Use this to add assets like a home, car, or other property you track manually.", systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .labelStyle(.titleAndIcon)
                }

                Section("Valuation") {
                    LabeledContent("As of") {
                        HStack(spacing: 12) {
                            DatePicker("", selection: $asOfDate, displayedComponents: .date)
                                .labelsHidden()
                                .datePickerStyle(.compact)
                                .fixedSize()
                            TextField("Value", text: $valueText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(minWidth: 110, idealWidth: 130, maxWidth: 160, alignment: .trailing)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    Picker("Financing Used (optional)", selection: $selectedLiability) {
                        Text("None").tag(Optional<Account>.none)
                        ForEach(liabilityAccounts, id: \.self) { acct in
                            Text(acct.name).tag(Optional(acct))
                        }
                    }

                    if let equity = computedEquity {
                        LabeledContent("Equity") {
                            Text(equity as NSNumber, formatter: currencyFormatter)
                        }
                    }

                    if let ltv = computedLTV {
                        LabeledContent("LTV") {
                            Text(percentFormatter.string(from: (ltv as NSNumber)) ?? "–")
                        }
                    }
                }

                Section(footer:
                    Text("This will create a Property asset and a single balance snapshot.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                ) { EmptyView() }
            }
            .navigationTitle("Add Property Asset")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    PlanToolbarButton("Cancel",fixedWidth: 70) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }

    // MARK: - Formatters
    private var currencyFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = settings.currencyCode
        return f
    }

    private var percentFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .percent
        f.maximumFractionDigits = 2
        return f
    }

    private func parseDecimal(from string: String) -> Decimal? {
        let filtered = string
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: filtered)
    }

    private func save() {
        guard let value = parseDecimal(from: valueText) else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInstitution = institution.trimmingCharacters(in: .whitespacesAndNewlines)
        let acct = Account(
            name: trimmedName,
            type: .property,
            institutionName: trimmedInstitution.isEmpty ? nil : trimmedInstitution,
            currencyCode: settings.currencyCode
        )
        modelContext.insert(acct)

        let snap = BalanceSnapshot(
            asOfDate: asOfDate,
            balance: value,
            account: acct,
            importBatch: nil,
            isUserCreated: true
        )
        modelContext.insert(snap)

        if let liability = selectedLiability {
            let link = AssetLiabilityLink(asset: acct, liability: liability, startDate: asOfDate)
            modelContext.insert(link)
        }

        try? modelContext.save()

        NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
        NotificationCenter.default.post(name: .accountsDidChange, object: nil)

        dismiss()
    }
}

#Preview {
    Text("ManualAssetSheet requires a model container and environment object for preview.")
}
