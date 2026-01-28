//
//  ImportFlowView.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ImportFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var vm = ImportViewModel(parsers: [
        PDFSummaryParser(),
        BankCSVParser(),
        BrokerageCSVParser(),
        GenericHoldingsStatementCSVParser()
    ])
    @State private var isImporterPresented = false
    private enum ImportMode { case general, pdfSummary, pdfTransactions }
    @State private var importMode: ImportMode = .general

    var body: some View {
        NavigationStack {
            ZStack {
                if let staged = vm.staged {
                    ReviewImportView(staged: staged, vm: vm)
                        .environment(\.modelContext, modelContext)
                } else if vm.mappingSession != nil {
                    VStack(spacing: 8) {
                        if let info = vm.infoMessage, !info.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.yellow)
                                Text(info)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                        }
                        MappingView(vm: vm)
                    }
                } else {
                    VStack(spacing: 0) {
                        ImportsListView()
                        Text("Hint: Swipe left on an import to delete it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
                }

                if vm.isImporting {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .progressViewStyle(.circular)
                        Text("Importing…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(20)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemBackground))
                    )
                    .shadow(radius: 10)
                    .zIndex(1)
                }
            }
            .navigationTitle("Import")
            .onAppear {
                AMLogging.always(String(describing: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!), component: "ImportFlowView")  // DEBUG LOG
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button {
                            vm.errorMessage = nil
                            importMode = .pdfSummary
                            isImporterPresented = true
                        } label: {
                            Text("Import PDF (Summary)")
                        }
                        Button {
                            vm.errorMessage = nil
                            importMode = .pdfTransactions
                            isImporterPresented = true
                        } label: {
                            Text("Import PDF (Transactions)")
                        }
                    } label: {
                        Text("More")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        vm.errorMessage = nil
                        importMode = .general
                        isImporterPresented = true
                    } label: {
                        Text("Import CSV")
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: importMode == .pdfTransactions || importMode == .pdfSummary ? [.pdf] : [UTType.commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    vm.isImporting = true
                    switch importMode {
                    case .general:
                        DispatchQueue.main.async { vm.handlePickedURL(url) }
                    case .pdfSummary:
                        DispatchQueue.main.async { vm.handlePickedURL(url) }
                    case .pdfTransactions:
                        DispatchQueue.main.async { vm.handlePickedPDFTransactionsURL(url) }
                    }
                }
            case .failure(let error):
                vm.errorMessage = error.localizedDescription
            }
        }
        .alert("Import failed", isPresented: Binding(get: {
            vm.errorMessage != nil
        }, set: { newValue in
            if newValue == false { vm.errorMessage = nil }
        })) {
            Button("OK", role: .cancel) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }
}

