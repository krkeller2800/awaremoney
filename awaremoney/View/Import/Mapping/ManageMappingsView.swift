import SwiftUI
import SwiftData

struct ManageMappingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\CSVColumnMapping.label)]) private var mappings: [CSVColumnMapping]

    @State private var editingMapping: CSVColumnMapping? = nil

    var body: some View {
        NavigationStack {
            List {
                if mappings.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No mappings yet")
                            .foregroundStyle(.secondary)
                        Text("Tap + to add your first mapping.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                } else {
                    ForEach(mappings) { mapping in
                        NavigationLink {
                            CSVMappingEditorView(mapping: mapping)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName(for: mapping))
                                    .font(.headline)
                                let summaryText = summary(for: mapping)
                                if !summaryText.isEmpty {
                                    Text(summaryText)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
            .navigationTitle("Manage Mappings")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: add) { Label("Add", systemImage: "plus") }
                }
            }
            .sheet(isPresented: Binding(
                get: { editingMapping != nil },
                set: { if !$0 { editingMapping = nil } }
            )) {
                if let mapping = editingMapping {
                    NavigationStack { CSVMappingEditorView(mapping: mapping) }
                }
            }
        }
    }

    private func add() {
        let m = CSVColumnMapping(label: "New Mapping", mappings: [:])
        modelContext.insert(m)
        editingMapping = m
    }

    private func delete(at offsets: IndexSet) {
        for i in offsets { modelContext.delete(mappings[i]) }
        try? modelContext.save()
    }

    private func displayName(for mapping: CSVColumnMapping) -> String {
        if let label = mapping.label, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return label }
        return "Untitled"
    }

    private func summary(for mapping: CSVColumnMapping) -> String {
        if mapping.mappings.isEmpty { return "" }
        let keys = mapping.mappings.keys.map { $0.rawValue.capitalized }.sorted()
        return keys.joined(separator: ", ")
    }
}

#Preview {
    NavigationStack { ManageMappingsView() }
        .modelContainer(for: [CSVColumnMapping.self], inMemory: true)
}
