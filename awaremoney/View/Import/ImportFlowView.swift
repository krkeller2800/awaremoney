import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Combine
import UIKit

struct ImportFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var vm = ImportViewModel(parsers: ImportViewModel.defaultParsers())

    @State private var batches: [ImportBatch] = []
    @State private var isFileImporterPresented = false
    @State private var pickerKind: PickerKind? = nil
    @State private var selectedBatchID: PersistentIdentifier? = nil

    private enum PickerKind { case csv, pdf }

    private var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

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
            description: Text("Import CSV account activity or a PDF statement to get started.")
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

    private var hintBar: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
            Text("Tip: For best results, import PDFs of current statements and add CSV activity for mid-month updates.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.systemGroupedBackground))
    }

    private var hintListFooter: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lightbulb")
                .imageScale(.medium)
                .foregroundStyle(.secondary)
            Text("Tip: For best results, import PDFs of current statements and add CSV activity for mid-month updates.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
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

    private var phoneBody: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    Section {
                        importsSection()
                    } header: {
                        Text("Imports")
                    }
                }

                hintBar
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
            .onChange(of: pickerKind) {
                AMLogging.always("ImportFlowView: pickerKind changed to \(String(describing: pickerKind))", component: "Import")
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
                            vm.userSelectedDocHint = .loan
                            AMLogging.always("ImportFlowView: presenting PDF picker (Loan Statement)", component: "Import")
                            isFileImporterPresented = true
                        }
                        Button("Bank Statement") {
                            pickerKind = .pdf
                            vm.userSelectedDocHint = .checking
                            AMLogging.always("ImportFlowView: presenting PDF picker (Bank Statement)", component: "Import")
                            isFileImporterPresented = true
                        }
                        Button("Brokerage Statement") {
                            pickerKind = .pdf
                            vm.userSelectedDocHint = .brokerage
                            AMLogging.always("ImportFlowView: presenting PDF picker (Brokerage Statement)", component: "Import")
                            isFileImporterPresented = true
                        }
                        Button("Credit Card Statement") {
                            pickerKind = .pdf
                            vm.userSelectedDocHint = .creditCard
                            vm.newAccountType = .creditCard
                            AMLogging.always("ImportFlowView: presenting PDF picker (Credit Card Statement)", component: "Import")
                            isFileImporterPresented = true
                        }
                        Divider()
                        Button("User-defined…") {
                            vm.startManualImport(kind: .creditCard)
                            AMLogging.always("ImportFlowView: started manual user-defined import (credit card)", component: "Import")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu("Import CSV") {
                        Button("Loan CSV") {
                            pickerKind = .csv
                            vm.userSelectedDocHint = .loan
                            AMLogging.always("ImportFlowView: presenting CSV picker (Loan CSV)", component: "Import")
                            isFileImporterPresented = true
                        }
                        Button("Bank CSV") {
                            pickerKind = .csv
                            vm.userSelectedDocHint = .checking
                            AMLogging.always("ImportFlowView: presenting CSV picker (Bank CSV)", component: "Import")
                            isFileImporterPresented = true
                        }
                        Button("Brokerage CSV") {
                            pickerKind = .csv
                            vm.userSelectedDocHint = .brokerage
                            AMLogging.always("ImportFlowView: presenting CSV picker (Brokerage CSV)", component: "Import")
                            isFileImporterPresented = true
                        }
                        Button("Credit Card CSV") {
                            pickerKind = .csv
                            vm.userSelectedDocHint = .creditCard
                            AMLogging.always("ImportFlowView: presenting CSV picker (Credit Card CSV)", component: "Import")
                            isFileImporterPresented = true
                        }
                    }
                }
            }
        }
    }

    private var ipadBody: some View {
        HStack(spacing: 0) {
            // LEFT: Sidebar NavigationStack with toolbar and title
            NavigationStack {
                List(selection: $selectedBatchID) {
                    Section {
                        if batches.isEmpty {
                            emptyStateView
                        } else {
                            ForEach(batches, id: \.persistentModelID) { batch in
                                BatchRowContent(batch: batch)
                                    .tag(batch.persistentModelID)
                            }
                        }
                    } header: {
                        Text("Imports")
                    } footer: {
                        hintListFooter
                    }
                }
                .refreshable { await loadBatches() }
                .listStyle(.sidebar)
                .navigationTitle("Import")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Menu("PDF") {
                            Button("Loan Statement") {
                                pickerKind = .pdf
                                vm.userSelectedDocHint = .loan
                                AMLogging.always("ImportFlowView: presenting PDF picker (Loan Statement)", component: "Import")
                                isFileImporterPresented = true
                            }
                            Button("Bank Statement") {
                                pickerKind = .pdf
                                vm.userSelectedDocHint = .checking
                                AMLogging.always("ImportFlowView: presenting PDF picker (Bank Statement)", component: "Import")
                                isFileImporterPresented = true
                            }
                            Button("Brokerage Statement") {
                                pickerKind = .pdf
                                vm.userSelectedDocHint = .brokerage
                                AMLogging.always("ImportFlowView: presenting PDF picker (Brokerage Statement)", component: "Import")
                                isFileImporterPresented = true
                            }
                            Button("Credit Card Statement") {
                                pickerKind = .pdf
                                vm.userSelectedDocHint = .creditCard
                                vm.newAccountType = .creditCard
                                AMLogging.always("ImportFlowView: presenting PDF picker (Credit Card Statement)", component: "Import")
                                isFileImporterPresented = true
                            }
                            Divider()
                            Button("User-defined…") {
                                vm.startManualImport(kind: .creditCard)
                                AMLogging.always("ImportFlowView: started manual user-defined import (credit card)", component: "Import")
                            }
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu("CSV") {
                            Button("Loan CSV") {
                                pickerKind = .csv
                                vm.userSelectedDocHint = .loan
                                AMLogging.always("ImportFlowView: presenting CSV picker (Loan CSV)", component: "Import")
                                isFileImporterPresented = true
                            }
                            Button("Bank CSV") {
                                pickerKind = .csv
                                vm.userSelectedDocHint = .checking
                                AMLogging.always("ImportFlowView: presenting CSV picker (Bank CSV)", component: "Import")
                                isFileImporterPresented = true
                            }
                            Button("Brokerage CSV") {
                                pickerKind = .csv
                                vm.userSelectedDocHint = .brokerage
                                AMLogging.always("ImportFlowView: presenting CSV picker (Brokerage CSV)", component: "Import")
                                isFileImporterPresented = true
                            }
                            Button("Credit Card CSV") {
                                pickerKind = .csv
                                vm.userSelectedDocHint = .creditCard
                                AMLogging.always("ImportFlowView: presenting CSV picker (Credit Card CSV)", component: "Import")
                                isFileImporterPresented = true
                            }
                        }
                    }
                }
            }
            .frame(minWidth: 300, idealWidth: 340, maxWidth: 400)

            Divider()

            // RIGHT: Detail NavigationStack so it has its own title
            NavigationStack {
                Group {
                    if let pid = selectedBatchID, let batch = batches.first(where: { $0.persistentModelID == pid }) {
                        ImportBatchDetailView(batch: batch)
                            .environment(\.modelContext, modelContext)
                            .id(batch.persistentModelID)
                            .onAppear {
                                AMLogging.always("ImportFlowView: presenting detail for label=\(batch.label) id=\(batch.id) pid=\(batch.persistentModelID)", component: "Import")
                            }
                    } else {
                        ContentUnavailableView(
                            "Select an Import",
                            systemImage: "tray",
                            description: Text("Choose an import from the sidebar.")
                        )
                    }
                }
                .navigationTitle(selectedBatchID == nil ? "" : "Update Transactions")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Attach shared modifiers to the outer container so behavior remains the same
        .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in
            Task { await loadBatches() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { _ in
            Task { await loadBatches() }
        }
        .onChange(of: pickerKind) {
            AMLogging.always("ImportFlowView: pickerKind changed to \(String(describing: pickerKind))", component: "Import")
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
        .onChange(of: batches) {
            if isPad {
                if let sel = selectedBatchID, !batches.contains(where: { $0.persistentModelID == sel }) {
                    selectedBatchID = batches.first?.persistentModelID
                } else if selectedBatchID == nil {
                    selectedBatchID = batches.first?.persistentModelID
                }
            }
        }
        .onChange(of: selectedBatchID) {
            if let pid = selectedBatchID {
                let resolved = batches.first(where: { $0.persistentModelID == pid })
                AMLogging.always("ImportFlowView: selectedBatchID changed pid=\(pid) resolved=\(resolved != nil ? "yes" : "no")", component: "Import")
            } else {
                AMLogging.always("ImportFlowView: selectedBatchID cleared", component: "Import")
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
        .task { await loadBatches() }
    }

    var body: some View {
        if isPad {
            ipadBody
        } else {
            phoneBody
        }
    }

    @Sendable private func loadBatches() async {
        do {
            var desc = FetchDescriptor<ImportBatch>()
            desc.sortBy = [SortDescriptor(\ImportBatch.createdAt, order: .reverse)]
            let fetched = try modelContext.fetch(desc)
            await MainActor.run {
                self.batches = fetched
                let summary = fetched.map { batch in
                    "[label=\(batch.label), id=\(batch.id), pid=\(batch.persistentModelID)]"
                }.joined(separator: ", ")
                AMLogging.always("ImportFlowView: loaded batches count=\(fetched.count) details=\(summary)", component: "Import")
            }
        } catch {
            await MainActor.run { self.batches = [] }
        }
    }
}

#Preview {
    ImportFlowView()
}

