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
                VStack(alignment: .leading, spacing: 4) {
                    Text(batch.label)
                        .font(.headline)
                    HStack(spacing: 8) {
                        Text(batch.createdAt, style: .date)
                        Text(batch.createdAt, style: .time)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("Imports")
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let batch = batches[index]
            context.delete(batch)
        }
        try? context.save()
    }
}
