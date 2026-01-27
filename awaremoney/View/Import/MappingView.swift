import SwiftUI

struct MappingView: View {
    @ObservedObject var vm: ImportViewModel

    var body: some View {
        VStack(alignment: .leading) {
            Text("Map Columns")
                .font(.title2)
                .padding(.bottom, 8)

            if let session = vm.mappingSession {
                // Headers row
                ScrollView(.horizontal) {
                    HStack(spacing: 16) {
                        ForEach(session.headers.indices, id: \.self) { idx in
                            let header = session.headers[idx]
                            VStack(alignment: .leading, spacing: 4) {
                                Text(header)
                                    .font(.headline)
                                Text("Index: \(idx)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .background(.thinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.vertical, 4)
                }

                // Minimal controls for bank-style mapping
                GroupBox("Required Fields") {
                    VStack(alignment: .leading) {
                        Picker("Date", selection: Binding(get: { vm.mappingSession?.dateIndex ?? -1 }, set: { vm.mappingSession?.dateIndex = $0 == -1 ? nil : $0 })) {
                            Text("Select").tag(-1)
                            ForEach(session.headers.indices, id: \.self) { idx in
                                let h = session.headers[idx]
                                Text(h).tag(idx)
                            }
                        }
                        Picker("Description", selection: Binding(get: { vm.mappingSession?.descriptionIndex ?? -1 }, set: { vm.mappingSession?.descriptionIndex = $0 == -1 ? nil : $0 })) {
                            Text("Optional").tag(-1)
                            ForEach(session.headers.indices, id: \.self) { idx in
                                let h = session.headers[idx]
                                Text(h).tag(idx)
                            }
                        }
                        Picker("Amount", selection: Binding(get: { vm.mappingSession?.amountIndex ?? -1 }, set: { vm.mappingSession?.amountIndex = $0 == -1 ? nil : $0 })) {
                            Text("Use Debit/Credit").tag(-1)
                            ForEach(session.headers.indices, id: \.self) { idx in
                                let h = session.headers[idx]
                                Text(h).tag(idx)
                            }
                        }
                        HStack {
                            Picker("Debit", selection: Binding(get: { vm.mappingSession?.debitIndex ?? -1 }, set: { vm.mappingSession?.debitIndex = $0 == -1 ? nil : $0 })) {
                                Text("None").tag(-1)
                                ForEach(session.headers.indices, id: \.self) { idx in
                                    let h = session.headers[idx]
                                    Text(h).tag(idx)
                                }
                            }
                            Picker("Credit", selection: Binding(get: { vm.mappingSession?.creditIndex ?? -1 }, set: { vm.mappingSession?.creditIndex = $0 == -1 ? nil : $0 })) {
                                Text("None").tag(-1)
                                ForEach(session.headers.indices, id: \.self) { idx in
                                    let h = session.headers[idx]
                                    Text(h).tag(idx)
                                }
                            }
                        }
                    }
                }

                GroupBox("Optional") {
                    VStack(alignment: .leading) {
                        Picker("Balance", selection: Binding(get: { vm.mappingSession?.balanceIndex ?? -1 }, set: { vm.mappingSession?.balanceIndex = $0 == -1 ? nil : $0 })) {
                            Text("None").tag(-1)
                            ForEach(session.headers.indices, id: \.self) { idx in
                                let h = session.headers[idx]
                                Text(h).tag(idx)
                            }
                        }
                        TextField("Date Format (e.g. MM/dd/yyyy)", text: Binding(get: { vm.mappingSession?.dateFormat ?? "" }, set: { vm.mappingSession?.dateFormat = $0.isEmpty ? nil : $0 }))
                            .textFieldStyle(.roundedBorder)
                    }
                }

                Spacer()

                HStack {
                    Button("Cancel") { vm.mappingSession = nil }
                    Spacer()
                    Button("Continue") { vm.applyBankMapping() }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.mappingSession?.dateIndex == nil || ((vm.mappingSession?.amountIndex == nil) && (vm.mappingSession?.debitIndex == nil && vm.mappingSession?.creditIndex == nil)))
                }
            } else {
                Text("No mapping session.")
            }
        }
        .padding()
        .navigationTitle("Map Columns")
    }
}

