import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Combine

struct ImportFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var vm = ImportViewModel(parsers: ImportViewModel.defaultParsers())

    @State private var batches: [ImportBatch] = []
    @State private var isFileImporterPresented = false
    @State private var pickerKind: PickerKind? = nil

    private enum PickerKind { case csv, pdf }

    private func allowedTypesForCurrentPicker() -> [UTType] {
        switch pickerKind {
        case .csv:
            var types: [UTType] = [.commaSeparatedText]
            if let byExt = UTType(filenameExtension: "csv") { types.append(byExt) }
            return types
        case .pdf:
            return [.pdf]
        default:
            // Default to CSV to avoid overly broad file types
            var types: [UTType] = [.commaSeparatedText]
            if let byExt = UTType(filenameExtension: "csv") { types.append(byExt) }
            return types
        }
    }

    private var emptyStateView: some View {
        ContentUnavailableView(
            "No Imports Yet",
            systemImage: "tray",
            description: Text("Import a CSV or PDF statement to get started.")
        )
        .listRowInsets(EdgeInsets())
    }

    private struct BatchRowContent: View {
        let batch: ImportBatch
        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(batch.label)
                    .font(.body)
                HStack(spacing: 8) {
                    if let pid = batch.parserId, !pid.isEmpty {
                        Text(pid)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(batch.createdAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(batch.createdAt, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func importsSection() -> some View {
        if batches.isEmpty {
            emptyStateView
        } else {
            ForEach(batches, id: \.id) { batch in
                NavigationLink(destination: ImportBatchDetailView(batchID: batch.id)) {
                    BatchRowContent(batch: batch)
                }
            }
        }
    }

    @ViewBuilder
    private func sheetContent() -> some View {
        if let staged = vm.staged {
            ReviewImportView(staged: staged, vm: vm)
                .environment(\.modelContext, modelContext)
        } else if vm.mappingSession != nil {
            NavigationStack { MappingView(vm: vm) }
        } else {
            EmptyView()
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Imports") {
                    importsSection()
                }
            }
            .navigationTitle("Import")
            .task { await loadBatches() }
            .refreshable { await loadBatches() }
            .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in
                Task { await loadBatches() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { _ in
                Task { await loadBatches() }
            }
            .onChange(of: pickerKind) { kind in
                AMLogging.always("ImportFlowView: pickerKind changed to \(String(describing: kind))", component: "Import")
            }
            .onReceive(vm.$staged) { staged in
                if let staged {
                    AMLogging.always("ImportFlowView: staged import ready — parser=\(staged.parserId), balances=\(staged.balances.count), tx=\(staged.transactions.count)", component: "Import")
                } else {
                    AMLogging.always("ImportFlowView: staged import cleared", component: "Import")
                }
            }
            .onReceive(vm.$mappingSession) { session in
                if let session {
                    AMLogging.always("ImportFlowView: mapping session started — headers=\(session.headers.count)", component: "Import")
                } else {
                    AMLogging.always("ImportFlowView: mapping session cleared", component: "Import")
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: allowedTypesForCurrentPicker(),
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        AMLogging.always("ImportFlowView: picked file \(url.lastPathComponent) (ext=\(url.pathExtension))", component: "Import")
                        vm.handlePickedURL(url)
                    }
                case .failure:
                    break
                }
            }
            .sheet(isPresented: .constant(vm.staged != nil || vm.mappingSession != nil)) {
                sheetContent()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu("Import PDF") {
                        Button("Loan Statement") {
                            pickerKind = .pdf
                            AMLogging.always("ImportFlowView: presenting PDF picker (Loan Statement)", component: "Import")
                            isFileImporterPresented = true
                        }
                        Button("Bank Statement") {
                            pickerKind = .pdf
                            AMLogging.always("ImportFlowView: presenting PDF picker (Bank Statement)", component: "Import")
                            isFileImporterPresented = true
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        pickerKind = .csv
                        AMLogging.always("ImportFlowView: presenting CSV picker", component: "Import")
                        isFileImporterPresented = true
                    } label: {
                        Text("Import CSV")
                    }
                }
            }
        }
    }

    @Sendable private func loadBatches() async {
        do {
            var desc = FetchDescriptor<ImportBatch>()
            desc.sortBy = [SortDescriptor(\ImportBatch.createdAt, order: .reverse)]
            let fetched = try modelContext.fetch(desc)
            await MainActor.run { self.batches = fetched }
        } catch {
            await MainActor.run { self.batches = [] }
        }
    }
}

#Preview {
    ImportFlowView()
}

