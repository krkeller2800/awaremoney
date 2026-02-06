import SwiftUI

struct CSVMappingSheet: View {
    let headers: [String]
    let sampleRows: [[String]]
    var onCancel: () -> Void
    var onSave: (_ mapping: CSVColumnMapping, _ options: CSVMappingOptions) -> Void
    
    // Known fields to map CSV columns to
    enum KnownField: String, CaseIterable, Identifiable {
        case date = "Date"
        case kind = "Kind"
        case amount = "Amount"
        case payee = "Payee"
        case memo = "Memo"
        case category = "Category"
        case account = "Account"
        case symbol = "Symbol"
        case quantity = "Quantity"
        case price = "Price"
        case marketValue = "Market Value"
        case balance = "Balance"
        case runningBalance = "Running Balance"
        case interestRateAPR = "Interest Rate (APR)"
        case none = "None"
        
        var id: String { rawValue }
    }
    
    private func toModelField(_ field: KnownField) -> CSVColumnMapping.Field? {
        switch field {
        case .date: return .date
        case .kind: return .kind
        case .amount: return .amount
        case .payee: return .payee
        case .memo: return .memo
        case .category: return .category
        case .account: return .account
        case .symbol: return .symbol
        case .quantity: return .quantity
        case .price: return .price
        case .marketValue: return .marketValue
        case .balance: return .balance
        case .runningBalance: return .runningBalance
        case .interestRateAPR: return .interestRateAPR
        case .none: return nil
        }
    }
    
    @State private var mappings: [KnownField: String] = [:]
    
    // Parsing options example
    struct CSVMappingOptions {
        var delimiter: Character = ","
        var hasHeaderRow: Bool = true
        var skipEmptyLines: Bool = true
    }
    
    @State private var options = CSVMappingOptions()
    
    init(headers: [String], onSave: @escaping (_ mapping: CSVColumnMapping) -> Void, onCancel: @escaping () -> Void) {
        self.headers = headers
        self.sampleRows = []
        self.onCancel = onCancel
        self.onSave = { mapping, _ in onSave(mapping) }
    }
    
    init(headers: [String], sampleRows: [[String]], onCancel: @escaping () -> Void, onSave: @escaping (_ mapping: CSVColumnMapping, _ options: CSVMappingOptions) -> Void) {
        self.headers = headers
        self.sampleRows = sampleRows
        self.onCancel = onCancel
        self.onSave = onSave
    }
    
    // Precompute the list of fields to map (excluding .none) to help the type-checker
    private var mappableFields: [KnownField] {
        KnownField.allCases.filter { $0 != .none }
    }
    
    // Binding helper for a specific field's selected header
    private func selectionBinding(for field: KnownField) -> Binding<String> {
        Binding(
            get: { mappings[field] ?? Self.noneOption },
            set: { newValue in
                if newValue == Self.noneOption {
                    mappings[field] = nil
                } else {
                    mappings[field] = newValue
                }
            }
        )
    }
    
    // Binding helper for the delimiter text field
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
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Map Columns")) {
                    ForEach(mappableFields) { field in
                        Picker(selection: selectionBinding(for: field),
                               label: Text(field.rawValue)) {
                            Text(CSVMappingSheet.noneOption).tag(CSVMappingSheet.noneOption)
                            ForEach(headers, id: \.self) { header in
                                Text(header).tag(header)
                            }
                        }
                        .pickerStyle(MenuPickerStyle())
                    }
                }
                
                Section(header: Text("Options")) {
                    Toggle("Has Header Row", isOn: $options.hasHeaderRow)
                    Toggle("Skip Empty Lines", isOn: $options.skipEmptyLines)
                    HStack {
                        Text("Delimiter")
                        Spacer()
                        TextField("Delimiter", text: delimiterBinding)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 40)
                    }
                }
                
                Section(header: Text("Sample Data")) {
                    if sampleRows.isEmpty {
                        Text("No sample data available")
                            .foregroundColor(.secondary)
                    } else {
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
            .navigationBarTitle("Edit Mapping", displayMode: .inline)
            .navigationBarItems(leading: Button("Cancel") {
                onCancel()
            }, trailing: Button("Save") {
                let modelMappings: [CSVColumnMapping.Field: String] = Dictionary(uniqueKeysWithValues: mappings.compactMap { (k, v) in
                    guard let mf = toModelField(k) else { return nil }
                    return (mf, v)
                })
                let mapping = CSVColumnMapping(mappings: modelMappings)
                onSave(mapping, options)
            })
        }
    }
    
    private static let noneOption = "None"
}

// Minimal CSVColumnMapping stub for standalone usage
#if !canImport(SwiftData)
struct CSVColumnMapping {
    enum Field {
        case date, kind, amount, payee, memo, category, account
        case symbol, quantity, price, marketValue, balance, runningBalance, interestRateAPR
    }
    let mappings: [CSVColumnMapping.Field: String]
    
    init(mappings: [CSVColumnMapping.Field: String]) {
        self.mappings = mappings
    }
}
#endif

struct CSVMappingSheet_Previews: PreviewProvider {
    static var previews: some View {
        CSVMappingSheet(
            headers: ["Full Name", "Email Address", "Phone Number", "Street Address", "Symbol", "Quantity", "Price", "Market Value", "Balance", "APR"],
            sampleRows: [
                ["John Doe", "john@example.com", "123-456-7890", "123 Apple St."],
                ["Jane Smith", "jane@example.com", "987-654-3210", "456 Orange Ave."]
            ],
            onCancel: {},
            onSave: { mapping, options in
                print("Saved mapping: \(mapping.mappings), options: \(options)")
            }
        )
    }
}
