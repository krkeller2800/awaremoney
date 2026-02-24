import SwiftUI
import SwiftData

public struct CashFlowItemEditorView: View {
    let item: CashFlowItem
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    // Editable state
    @State private var name: String = ""
    @State private var amountText: String = ""
    @State private var frequency: PaymentFrequency = .monthly
    @State private var dayOfMonth: Int? = nil
    @State private var firstPaymentDate: Date? = nil
    @State private var notes: String = ""
    @State private var ssaWednesday: Int? = nil

    @State private var initialized = false

    @FocusState private var focusedField: FocusField?
    @State private var amountIsFirstResponder: Bool = false

    private enum FocusField: Hashable {
        case name, amount, notes
    }

    private let focusOrder: [FocusField] = [.name, .amount, .notes]

    private func moveFocus(_ direction: Int) {
        guard !focusOrder.isEmpty else { return }
        func activate(_ field: FocusField) {
            switch field {
            case .name:
                amountIsFirstResponder = false
                focusedField = .name
            case .amount:
                focusedField = .amount
                amountIsFirstResponder = true
            case .notes:
                amountIsFirstResponder = false
                focusedField = .notes
            }
        }
        guard let current = focusedField else {
            activate(focusOrder.first!)
            return
        }
        if let idx = focusOrder.firstIndex(of: current) {
            let newIdx = max(focusOrder.startIndex, min(focusOrder.index(before: focusOrder.endIndex), idx + direction))
            activate(focusOrder[newIdx])
        }
    }

    private func commitAndDismiss() {
        applyChanges()
        amountIsFirstResponder = false
        focusedField = nil
    }

    public var body: some View {
        Form {
            Section("Details") {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    TextField("Name", text: $name)
                        .submitLabel(.next)
                        .onSubmit {
                            amountIsFirstResponder = true
                            focusedField = .amount
                        }
                        .onChange(of: name) { applyChanges() }
                        .focused($focusedField, equals: .name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SelectAllAmountField(
                        text: $amountText,
                        placeholder: "Amount",
                        isFirstResponder: $amountIsFirstResponder,
                        onBeginEditing: { focusedField = .amount },
                        onEndEditing: { }
                    )
                    .frame(minWidth: 100, idealWidth: 120, maxWidth: 160, alignment: .trailing)
                }
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
                    if item.kind == .income {
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

                if item.kind == .income && frequency == .monthly {
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
                    .onChange(of: notes) { applyChanges() }
                    .focused($focusedField, equals: .notes)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button {
                    moveFocus(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(focusedField == focusOrder.first)

                Button {
                    moveFocus(1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(focusedField == focusOrder.last)

                Spacer()

                Button {
                    commitAndDismiss()
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                }
                .accessibilityLabel("Done")
            }
        }
        .navigationTitle("Edit \(item.kind == .income ? "Income" : "Bill")")
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
        // item.kind = kind  // Removed as per instructions
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

#if os(iOS)
import UIKit

private struct SelectAllAmountField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    @Binding var isFirstResponder: Bool
    var onBeginEditing: (() -> Void)? = nil
    var onEndEditing: (() -> Void)? = nil

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(frame: .zero)
        tf.keyboardType = .decimalPad
        tf.textAlignment = .right
        tf.placeholder = placeholder
        tf.delegate = context.coordinator
        tf.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        tf.text = text
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        uiView.placeholder = placeholder
        uiView.textAlignment = .right
        uiView.keyboardType = .decimalPad
        if uiView.text != text && !uiView.isFirstResponder {
            uiView.text = text
        }
        if isFirstResponder && !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        } else if !isFirstResponder && uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UITextFieldDelegate {
        var parent: SelectAllAmountField
        init(_ parent: SelectAllAmountField) { self.parent = parent }

        @objc func editingChanged(_ textField: UITextField) {
            parent.text = textField.text ?? ""
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async { textField.selectAll(nil) }
            parent.isFirstResponder = true
            parent.onBeginEditing?()
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            parent.isFirstResponder = false
            parent.onEndEditing?()
        }
    }
}
#endif

#Preview {
    Text("Editor preview requires a CashFlowItem instance")
}
