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
        BankCSVParser(),
        BrokerageCSVParser()
    ])

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let error = vm.errorMessage {
                    Text(error).foregroundColor(.red)
                }

                Button {
                    vm.presentImporter()
                } label: {
                    Label("Import CSV", systemImage: "tray.and.arrow.down")
                }

                if let staged = vm.staged {
                    ReviewImportView(staged: staged, vm: vm)
                        .environment(\.modelContext, modelContext)
                } else {
                    Text("Import a CSV statement to begin.")
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Import")
        }
        .fileImporter(
            isPresented: $vm.isImporterPresented,
            allowedContentTypes: [UTType.commaSeparatedText, .text, .data],
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
    }
}
