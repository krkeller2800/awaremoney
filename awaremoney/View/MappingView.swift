import SwiftUI

// MappingView is temporarily disabled while we finalize CSVMappingEditorView-based mapping flows.
// If referenced, present CSVMappingEditorView instead.
struct MappingView_Placeholder: View {
    var body: some View {
        Text("MappingView is disabled.")
            .foregroundStyle(.secondary)
    }
}

struct MappingView: View {
    @ObservedObject var vm: ImportViewModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "square.grid.3x3")
                .imageScale(.large)
                .foregroundStyle(.secondary)
            Text("Column mapping is temporarily unavailable in this build.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Done") {
                vm.mappingSession = nil
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .navigationTitle("Map Columns")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    vm.mappingSession = nil
                }
            }
        }
    }
}

