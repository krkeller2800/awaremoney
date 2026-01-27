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
    @State private var isPDFTxImporterPresented = false

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
                    NavigationLink {
                        ImportsListView()
                    } label: {
                        Text("View Imports")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        vm.errorMessage = nil
                        isPDFTxImporterPresented = true
                    } label: {
                        Text("Import PDF Transactions")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        vm.errorMessage = nil
                        isImporterPresented = true
                    } label: {
                        Text("Import")
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [UTType.commaSeparatedText, .text, .data, .pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    vm.handlePickedURL(url)
                }
            case .failure(let error):
                vm.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $isPDFTxImporterPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    vm.handlePickedPDFTransactionsURL(url)
                }
            case .failure(let error):
                vm.errorMessage = error.localizedDescription
            }
        }
    }
}

