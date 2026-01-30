//
//  ImportsListView.swift
//  awaremoney
//
//  Created by Assistant on 1/23/26.
//

import SwiftUI
import SwiftData

struct ImportsListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ImportBatch.createdAt, order: .reverse)
    private var batches: [ImportBatch]

    var body: some View {
        List {
            ForEach(batches) { batch in
                NavigationLink(destination: ImportBatchDetailView(batchID: batch.id)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(batch.label)
                            .font(.headline)
                        if let pid = batch.parserId {
                            HStack(spacing: 6) {
                                Image(systemName: "tag")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(parserDisplayName(for: pid))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        HStack(spacing: 8) {
                            Text(batch.createdAt, style: .date)
                            Text(batch.createdAt, style: .time)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Imports")
    }
}

fileprivate func parserDisplayName(for id: String) -> String {
    switch id {
    case PDFSummaryParser.id:
        return "PDF Statement"
    case PDFBankTransactionsParser.id:
        return "PDF Transactions"
    case "csv.bank":
        return "CSV (Bank)"
    case "csv.brokerage":
        return "CSV (Brokerage)"
    default:
        // Fallbacks based on prefixes
        if id.hasPrefix("pdf") { return "PDF" }
        if id.hasPrefix("csv") { return "CSV" }
        return id
    }
}
