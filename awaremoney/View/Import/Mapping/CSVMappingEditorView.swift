import SwiftUI
import SwiftData

struct CSVMappingEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @Bindable var mapping: CSVColumnMapping

    @State private var availableHeaders: [String] = []
    @State private var autoHandled: Bool = false
    
    private enum FocusedField: Hashable { case label, delimiter }
    @FocusState private var focusedField: FocusedField?

    struct CSVMappingOptions {
        var delimiter: Character = ","
        var hasHeaderRow: Bool = true
        var skipEmptyLines: Bool = true
    }

    @State private var options = CSVMappingOptions()
    private var onSaveWithOptionsAction: ((CSVColumnMapping, CSVMappingOptions) -> Void)? = nil
    private var sampleRows: [[String]] = []

    private var onSaveAction: ((CSVColumnMapping) -> Void)? = nil
    private var onCancelAction: (() -> Void)? = nil
    private var visibleFields: [CSVColumnMapping.Field]? = nil
    private var autoSaveWhenReady: Bool = true

    private var isImportFallback: Bool { !availableHeaders.isEmpty }

    private var fieldsToDisplay: [CSVColumnMapping.Field] {
        visibleFields ?? CSVColumnMapping.Field.allCases
    }

    private var unmatchedFields: [CSVColumnMapping.Field] {
        fieldsToDisplay.filter { field in
            if let mapped = mapping.mappings[field], !mapped.isEmpty {
                return !headerExists(mapped)
            }
            return false
        }
    }

    private var matchedFieldsCount: Int {
        fieldsToDisplay.reduce(0) { partialResult, field in
            if let mapped = mapping.mappings[field], !mapped.isEmpty, headerExists(mapped) {
                return partialResult + 1
            }
            return partialResult
        }
    }

    private var needsUserInput: Bool {
        guard isImportFallback else { return false }
        return !unmatchedFields.isEmpty || matchedFieldsCount == 0
    }

    private var unmatchedFieldNames: String {
        let names = unmatchedFields.map { missingDisplayName($0) }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return names.joined(separator: " and ")
        default:
            let head = names.dropLast().joined(separator: ", ")
            return head + ", and " + (names.last ?? "")
        }
    }

    // Normalize available headers for case/whitespace-insensitive comparisons
    private var normalizedHeaders: [String] {
        availableHeaders.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private var delimiterBinding: Binding<String> {
        Binding(
            get: { String(options.delimiter) },
            set: { value in
                if let char = value.first {
                    options.delimiter = char
                }
            }
        )
    }

    private func headerExists(_ name: String) -> Bool {
        let target = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedHeaders.contains { $0.compare(target, options: [.caseInsensitive]) == .orderedSame }
    }

    private func missingDisplayName(_ field: CSVColumnMapping.Field) -> String {
        switch field {
        case .date: return "Post/Transaction Date"
        case .amount: return "Amount"
        default: return fieldDisplayName(field)
        }
    }

    init(mapping: CSVColumnMapping) {
        self._mapping = Bindable(wrappedValue: mapping)
        self.autoSaveWhenReady = true
    }

    init(mapping: CSVColumnMapping, headers: [String], onSave: ((CSVColumnMapping) -> Void)? = nil, onCancel: (() -> Void)? = nil, visibleFields: [CSVColumnMapping.Field]? = nil, autoSaveWhenReady: Bool = true) {
        self._mapping = Bindable(wrappedValue: mapping)
        self._availableHeaders = State(initialValue: headers)
        self.onSaveAction = onSave
        self.onCancelAction = onCancel
        self.visibleFields = visibleFields
        self.autoSaveWhenReady = autoSaveWhenReady
    }

    init(mapping: CSVColumnMapping, headers: [String], sampleRows: [[String]], onSaveWithOptions: ((CSVColumnMapping, CSVMappingOptions) -> Void)? = nil, onCancel: (() -> Void)? = nil, visibleFields: [CSVColumnMapping.Field]? = nil, autoSaveWhenReady: Bool = true) {
        self._mapping = Bindable(wrappedValue: mapping)
        self._availableHeaders = State(initialValue: headers)
        self.onSaveWithOptionsAction = onSaveWithOptions
        self.onSaveAction = nil
        self.onCancelAction = onCancel
        self.visibleFields = visibleFields
        self.autoSaveWhenReady = autoSaveWhenReady
        self.sampleRows = sampleRows
    }

    var body: some View {
        Form {
            if isImportFallback {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 4) {
                            if needsUserInput {
                                if !unmatchedFields.isEmpty {
                                    Text("We couldn't match some columns in your CSV.")
                                        .font(.subheadline)
                                    Text("Missing: \(unmatchedFieldNames). Select the matching column names below to continue.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("We couldn't detect any column mappings in your CSV. Select the matching column names below to continue.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text("Review or confirm how your CSV columns map to fields.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Details") {
                TextField("Label", text: Binding(
                    get: { mapping.label ?? "" },
                    set: { mapping.label = $0 }
                ))
                .textInputAutocapitalization(.words)
                .focused($focusedField, equals: .label)
            }

            if isImportFallback {
                Section("Options") {
                    Toggle("Has Header Row", isOn: $options.hasHeaderRow)
                    Toggle("Skip Empty Lines", isOn: $options.skipEmptyLines)
                    HStack {
                        Text("Delimiter")
                        Spacer()
                        TextField("Delimiter", text: delimiterBinding)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 40)
                            .focused($focusedField, equals: .delimiter)
                    }
                }
            }

            if !availableHeaders.isEmpty && !unmatchedFields.isEmpty {
                Section("Fix Mappings") {
                    Text("We couldn't match these columns in your CSV. Select the matching column name from your file.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    ForEach(unmatchedFields, id: \.self) { field in
                        HStack {
                            Text(missingDisplayName(field))
                            Spacer()
                            Picker("", selection: Binding(
                                get: { mapping.mappings[field] ?? "" },
                                set: { newVal in mapping.mappings[field] = newVal.isEmpty ? nil : newVal }
                            )) {
                                Text("Select…").tag("")
                                ForEach(availableHeaders, id: \.self) { header in
                                    Text(header).tag(header)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(minWidth: 160)
                        }
                    }
                }
            }

            Section("Field Mappings") {
                ForEach(fieldsToDisplay, id: \.self) { field in
                    HStack {
                        Text(fieldDisplayName(field))
                        Spacer()
                        Picker("", selection: Binding(
                            get: { mapping.mappings[field] ?? "" },
                            set: { newVal in mapping.mappings[field] = newVal.isEmpty ? nil : newVal }
                        )) {
                            Text("Select…").tag("")
                            ForEach(availableHeaders, id: \.self) { header in
                                Text(header).tag(header)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(minWidth: 160)
                    }
                }
            }

            if isImportFallback && !sampleRows.isEmpty {
                Section("Sample Data") {
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading) {
                            ForEach(sampleRows.prefix(5), id: \.self) { row in
                                HStack {
                                    ForEach(row.indices, id: \.self) { idx in
                                        Text(row[idx])
                                            .frame(minWidth: 80, alignment: .leading)
                                            .border(Color.gray.opacity(0.3))
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 130)
                }
            }
        }
        .onAppear {
            AMLogging.log("CSVMappingEditorView: modelContext id=\(ObjectIdentifier(modelContext))", component: "Import")
            guard !autoHandled else { return }
            if autoSaveWhenReady && isImportFallback && !needsUserInput {
                autoHandled = true
                if let onSaveWithOptionsAction {
                    onSaveWithOptionsAction(mapping, options)
                    dismiss()
                } else if let onSaveAction {
                    onSaveAction(mapping)
                    dismiss()
                } else {
                    saveAndDismiss()
                }
            }
        }
        .navigationTitle(isImportFallback ? "Map Columns" : "Edit Mapping")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if let onCancelAction { onCancelAction() }
                    else { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    if let onSaveWithOptionsAction {
                        onSaveWithOptionsAction(mapping, options)
                        dismiss()
                    } else if let onSaveAction {
                        onSaveAction(mapping)
                        dismiss()
                    } else {
                        saveAndDismiss()
                    }
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Button {
                    moveToPreviousField()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(previousField() == nil)

                Button {
                    moveToNextField()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(nextField() == nil)

                Spacer()

                Button {
                    commitAndDismissKeyboard()
                } label: {
                    Image(systemName: "checkmark.circle.fill")
                }
            }
        }
    }

    private func fieldDisplayName(_ field: CSVColumnMapping.Field) -> String {
        switch field {
        case .name: return "Name"
        case .email: return "Email"
        case .phone: return "Phone"
        case .address: return "Address"
        case .company: return "Company"
        case .title: return "Title"
        case .notes: return "Notes"
        case .date: return "Date"
        case .kind: return "Kind"
        case .amount: return "Amount"
        case .payee: return "Payee"
        case .memo: return "Memo"
        case .category: return "Category"
        case .account: return "Account"
        case .symbol: return "Symbol"
        case .quantity: return "Quantity"
        case .price: return "Price"
        case .marketValue: return "Market Value"
        case .balance: return "Balance"
        case .runningBalance: return "Running Balance"
        case .interestRateAPR: return "Interest Rate (APR)"
        }
    }

    private func saveAndDismiss() {
        do {
            try modelContext.save()
            AMLogging.log("CSVMappingEditorView: save succeeded", component: "Import")
        } catch {
            AMLogging.error("CSVMappingEditorView: failed to save mapping — \(error.localizedDescription)", component: "Import")
        }
        dismiss()
    }
    
    private func availableFieldOrder() -> [FocusedField] {
        var order: [FocusedField] = [.label]
        if isImportFallback {
            order.append(.delimiter)
        }
        return order
    }

    private func previousField() -> FocusedField? {
        guard let current = focusedField else { return nil }
        let order = availableFieldOrder()
        guard let idx = order.firstIndex(of: current), idx > 0 else { return nil }
        return order[order.index(before: idx)]
    }

    private func nextField() -> FocusedField? {
        guard let current = focusedField else { return nil }
        let order = availableFieldOrder()
        guard let idx = order.firstIndex(of: current), idx < order.count - 1 else { return nil }
        return order[order.index(after: idx)]
    }

    private func moveToPreviousField() {
        if let prev = previousField() {
            focusedField = prev
        }
    }

    private func moveToNextField() {
        if let next = nextField() {
            focusedField = next
        }
    }

    private func commitAndDismissKeyboard() {
        focusedField = nil
    }
}

#Preview {
    let m = CSVColumnMapping(label: "Sample", mappings: [.date: "Date", .amount: "Amount", .symbol: "Ticker"])
    return NavigationStack {
        CSVMappingEditorView(mapping: m)
    }
    .modelContainer(for: [CSVColumnMapping.self], inMemory: true)
}

