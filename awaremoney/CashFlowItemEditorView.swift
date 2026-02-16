import SwiftUI
import SwiftData

public struct CashFlowItemEditorView: View {
    let item: CashFlowItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // Editable state
    @State private var kind: CashFlowItem.Kind = .bill
    @State private var name: String = ""
    @State private var amountText: String = ""
    @State private var frequency: PaymentFrequency = .monthly
    @State private var dayOfMonth: Int? = nil
    @State private var firstPaymentDate: Date? = nil
    @State private var notes: String = ""
    @State private var ssaWednesday: Int? = nil

    @State private var initialized = false

    public var body: some View {
        Form {
            Section("Type") {
                Picker("Kind", selection: $kind) {
                    Text("Income").tag(CashFlowItem.Kind.income)
                    Text("Bill").tag(CashFlowItem.Kind.bill)
                }
                .pickerStyle(.segmented)
                .onChange(of: kind) { _, newKind in
                    if newKind == .income {
                        switch frequency.normalized {
                        case .monthly, .semimonthly, .biweekly, .weekly, .socialSecurity:
                            if dayOfMonth == nil { dayOfMonth = 1 }
                            firstPaymentDate = nil
                        default:
                            break
                        }
                    }
                    applyChanges()
                }
            }
            Section("Details") {
                TextField("Name", text: $name)
                    .onChange(of: name) { _ in applyChanges() }
                TextField("Amount", text: $amountText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: amountText) { _ in applyChanges() }
                Picker("Frequency", selection: $frequency) {
                    Text("Monthly").tag(PaymentFrequency.monthly)
                    Text("Twice per month").tag(PaymentFrequency.semimonthly)
                    Text("Every 2 weeks").tag(PaymentFrequency.biweekly)
                    Text("Weekly").tag(PaymentFrequency.weekly)
                    Text("Yearly").tag(PaymentFrequency.yearly)
                    Text("Quarterly").tag(PaymentFrequency.quarterly)
                    Text("Semiannual").tag(PaymentFrequency.semiAnnual)
                    Text("One-time").tag(PaymentFrequency.oneTime)
                }
                .onChange(of: frequency) { _, newValue in
                    if kind == .income {
                        switch newValue.normalized {
                        case .monthly, .semimonthly, .biweekly, .weekly, .socialSecurity:
                            if dayOfMonth == nil { dayOfMonth = 1 }
                            firstPaymentDate = nil
                        default:
                            break
                        }
                    }
                    applyChanges()
                }

                if kind == .income && frequency == .monthly {
                    Picker("SSA Wednesday", selection: Binding<Int?>(
                        get: { ssaWednesday },
                        set: { ssaWednesday = $0; applyChanges() }
                    )) {
                        Text("None").tag(nil as Int?)
                        Text("2nd Wednesday").tag(Optional(2))
                        Text("3rd Wednesday").tag(Optional(3))
                        Text("4th Wednesday").tag(Optional(4))
                    }
                    Text("For Social Security income paid on a specific Wednesday of the month.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if ssaWednesday == nil {
                    switch frequency.normalized {
                    case .monthly, .semimonthly, .biweekly, .weekly, .socialSecurity:
                        Picker("Day of Month", selection: Binding<Int?>(
                            get: { dayOfMonth },
                            set: { dayOfMonth = $0; applyChanges() }
                        )) {
                            Text("None").tag(nil as Int?)
                            ForEach(1...31, id: \.self) { d in Text("\(d)").tag(Optional(d)) }
                        }
                    default:
                        DatePicker("First Payment Date", selection: Binding<Date>(
                            get: { firstPaymentDate ?? Date() },
                            set: { firstPaymentDate = $0; applyChanges() }
                        ), displayedComponents: .date)
                    }
                }
                TextField("Notes", text: $notes)
                    .onChange(of: notes) { _ in applyChanges() }
            }
        }
        .navigationTitle("Edit \(kind == .income ? "Income" : "Bill")")
        .onAppear { initializeFromItemIfNeeded() }
        .toolbar {
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) {
                    modelContext.delete(item)
                    try? modelContext.save()
                    dismiss()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private func initializeFromItemIfNeeded() {
        guard !initialized else { return }
        self.kind = item.kind
        self.name = item.name
        self.amountText = formatAmountForInput(item.amount)
        self.frequency = item.frequency
        self.dayOfMonth = item.dayOfMonth
        self.firstPaymentDate = item.firstPaymentDate
        self.notes = item.notes ?? ""
        self.ssaWednesday = extractSSAWednesday(from: item.notes)
        self.initialized = true
    }

    private func applyChanges() {
        item.kind = kind
        item.name = name
        if let amt = parseCurrency(amountText) {
            item.amount = amt
        }
        item.frequency = frequency
        item.dayOfMonth = dayOfMonth
        item.firstPaymentDate = firstPaymentDate
        let cleanedNotes = removeSSAToken(from: notes)
        if let n = ssaWednesday {
            let token = "[SSA_WED]=\(n)"
            item.notes = cleanedNotes.isEmpty ? token : (cleanedNotes + " " + token)
        } else {
            item.notes = cleanedNotes.isEmpty ? nil : cleanedNotes
        }
        try? modelContext.save()
    }

    // MARK: - Helpers

    private func parseCurrency(_ s: String) -> Decimal? {
        let cleaned = s.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: cleaned)
    }

    private func formatAmountForInput(_ amount: Decimal) -> String {
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 0
        nf.maximumFractionDigits = 2
        return nf.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount)"
    }

    private func removeSSAToken(from s: String) -> String {
        if s.isEmpty { return s }
        var parts = s.split(separator: " ").map(String.init)
        parts.removeAll { $0.hasPrefix("[SSA_WED]=") }
        return parts.joined(separator: " ")
    }

    private func extractSSAWednesday(from notes: String?) -> Int? {
        guard let notes = notes, !notes.isEmpty else { return nil }
        for tok in notes.split(separator: " ") {
            if tok.hasPrefix("[SSA_WED]=") {
                let val = tok.replacingOccurrences(of: "[SSA_WED]=", with: "")
                if let n = Int(val), (2...4).contains(n) { return n }
            }
        }
        return nil
    }
}

#Preview {
    Text("Editor preview requires a CashFlowItem instance")
}
