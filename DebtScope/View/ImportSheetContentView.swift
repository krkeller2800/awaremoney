import SwiftUI
import SwiftData

struct ImportSheetContentView: View {
    @ObservedObject var vm: ImportViewModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            if let staged = vm.staged {
                ReviewImportView(staged: staged, vm: vm)
                    .environment(\.modelContext, modelContext)
            } else if let session = vm.mappingSession {
                NavigationStack {
                    CSVMappingEditorView(
                        mapping: CSVColumnMapping(label: "New Mapping", mappings: [:]),
                        headers: session.headers,
                        sampleRows: session.sampleRows,
                        onSaveWithOptions: { mapping, _ in
                            modelContext.insert(mapping)
                            try? modelContext.save()
                            do {
                                let parser = GenericCSVParser(
                                    mapping: mapping,
                                    sourceFileName: vm.lastPickedLocalURL?.lastPathComponent ?? "Mapped CSV"
                                )
                                let staged = try parser.parse(rows: session.sampleRows, headers: session.headers)
                                vm.staged = staged
                                vm.mappingSession = nil
                            } catch {
                                AMLogging.error("QuickStartView: CSV mapping parse failed: \(error.localizedDescription)", component: "QuickStart")
                            }
                        },
                        onCancel: { vm.mappingSession = nil },
                        visibleFields: nil,
                        autoSaveWhenReady: false
                    )
                }
            } else {
                EmptyView()
            }
        }
    }
}

#Preview {
    // This preview uses a placeholder ImportViewModel. Replace with a proper mock if available.
    ImportSheetContentView(vm: ImportViewModel(parsers: ImportViewModel.defaultParsers()))
}
