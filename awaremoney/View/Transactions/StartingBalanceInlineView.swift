import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// Public, non-generic wrapper that can be used with or without focus integration
struct StartingBalanceInlineView: View {
    private let content: AnyView

    init(
        asOfDate: Date,
        onSet: @escaping (Decimal, Date) -> Void,
        title: String = "Starting Balance",
        messageOverride: String? = nil,
        onNext: (() -> Void)? = nil,
        onAmountChange: ((Decimal?) -> Void)? = nil
    ) {
        let impl = StartingBalanceInlineViewImpl<Int>(
            asOfDate: asOfDate,
            onSet: onSet,
            focusedField: nil,
            focusedCase: nil,
            onNext: onNext,
            title: title,
            messageOverride: messageOverride,
            onAmountChange: onAmountChange
        )
        self.content = AnyView(impl)
    }

    init<FocusKey: Hashable>(
        asOfDate: Date,
        onSet: @escaping (Decimal, Date) -> Void,
        focusedField: FocusState<FocusKey?>.Binding,
        focusedCase: FocusKey,
        onNext: (() -> Void)? = nil,
        title: String = "Starting Balance",
        messageOverride: String? = nil,
        onAmountChange: ((Decimal?) -> Void)? = nil
    ) {
        let impl = StartingBalanceInlineViewImpl<FocusKey>(
            asOfDate: asOfDate,
            onSet: onSet,
            focusedField: focusedField,
            focusedCase: focusedCase,
            onNext: onNext,
            title: title,
            messageOverride: messageOverride,
            onAmountChange: onAmountChange
        )
        self.content = AnyView(impl)
    }

    var body: some View { content }
}

// Internal generic implementation that actually renders the UI
private struct StartingBalanceInlineViewImpl<FocusKey: Hashable>: View {
    let title: String
    let messageOverride: String?
    let onSet: (Decimal, Date) -> Void
    let onNext: (() -> Void)?
    let onAmountChange: ((Decimal?) -> Void)?

    @State private var amountText: String = ""
    @State private var date: Date

    private var focusedField: FocusState<FocusKey?>.Binding?
    private var focusedCase: FocusKey?

    init(
        asOfDate: Date,
        onSet: @escaping (Decimal, Date) -> Void,
        focusedField: FocusState<FocusKey?>.Binding?,
        focusedCase: FocusKey?,
        onNext: (() -> Void)?,
        title: String,
        messageOverride: String?,
        onAmountChange: ((Decimal?) -> Void)?
    ) {
        self._date = State(initialValue: asOfDate)
        self.onSet = onSet
        self.title = title
        self.messageOverride = messageOverride
        self.onNext = onNext
        self.focusedField = focusedField
        self.focusedCase = focusedCase
        self.onAmountChange = onAmountChange
    }

    var body: some View {
        Section(title) {
            HStack(spacing: 12) {
                DatePicker("As of", selection: $date, displayedComponents: .date)
                    .labelsHidden()
                Spacer()
                amountField()
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
                    .submitLabel(.next)
                    .onSubmit { submit() }
                    .onChange(of: amountText, initial: false) { _, newValue in
                        onAmountChange?(parseCurrencyInput(newValue))
                    }
#if canImport(UIKit)
                    .onTapGesture { selectAllInFirstResponder(after: 0.05) }
#endif
            }
            if let msg = messageOverride {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Enter the starting balance and choose the statement date.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                submit()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle")
                    Text("Add Balance")
                }
            }
            .disabled(parseCurrencyInput(amountText) == nil)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func amountField() -> some View {
        if let binding = focusedField, let fcase = focusedCase {
            TextField("0.00", text: $amountText)
                .focused(binding, equals: fcase)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } else {
            TextField("0.00", text: $amountText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    private func submit() {
        guard let dec = parseCurrencyInput(amountText) else { return }
        onSet(dec, date)
        onAmountChange?(nil)
        // Defer focus move until the UI updates to include the newly added balance field
        DispatchQueue.main.async {
            onNext?()
        }
    }

    private func parseCurrencyInput(_ s: String) -> Decimal? {
        let cleaned = s.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Decimal(string: cleaned)
    }

#if canImport(UIKit)
    private func selectAllInFirstResponder(after delay: TimeInterval = 0.05) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
        }
    }
    private func selectAllInFirstResponder() {
        selectAllInFirstResponder(after: 0.05)
    }
#endif
}
