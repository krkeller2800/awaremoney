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
    private enum ImportMode { case general, pdfTransactions }
    @State private var importMode: ImportMode = .general

    var body: some View {
        NavigationStack {
            Group {
                if let staged = vm.staged {
                    ReviewImportView(staged: staged, vm: vm)
                        .environment(\.modelContext, modelContext)
                } else if vm.mappingSession != nil {
                    MappingView(vm: vm)
                } else {
                    VStack(spacing: 0) {
                        ImportsListView()
                        Text("Hint: Swipe left on an import to delete it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    }
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
                            importMode = .pdfTransactions
                            isImporterPresented = true
                        } label: {
                            Text("Import PDF Transactions")
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
                        Text("Import")
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: importMode == .pdfTransactions ? [.pdf] : [UTType.commaSeparatedText, .text, .data, .pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    switch importMode {
                    case .general:
                        vm.handlePickedURL(url)
                    case .pdfTransactions:
                        vm.handlePickedPDFTransactionsURL(url)
                    }
                }
            case .failure(let error):
                vm.errorMessage = error.localizedDescription
            }
        }
    }
}

