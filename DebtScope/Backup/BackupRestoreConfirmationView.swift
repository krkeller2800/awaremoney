import SwiftUI

struct BackupRestoreConfirmationView: View {
    let summary: BackupRestorePreflight.RestoreSummary
    let onCancel: () -> Void
    let onRestore: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showDetails = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("This app already has data.")
                        .font(.headline)
                    Text(BackupRestorePreflight.warningLead)
                    Text(BackupRestorePreflight.warningClose)
                        .font(.subheadline.weight(.semibold))
                }

                Section {
                    DisclosureGroup("Review data counts", isExpanded: $showDetails) {
                        countRows(
                            title: "Current app",
                            rows: BackupRestorePreflight.appSummaryRows(for: summary.appCounts)
                        )

                        countRows(
                            title: "Backup from \(BackupRestorePreflight.formattedBackupDate(summary.backupCounts.generatedAt))",
                            rows: BackupRestorePreflight.backupSummaryRows(for: summary.backupCounts)
                        )
                    }
                }

                Section {
                    Button("Restore Anyway", role: .destructive) {
                        dismiss()
                        onRestore()
                    }
                }
            }
            .navigationTitle("Restore Backup?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        onCancel()
                    }
                }
            }
        }
    }

    private func countRows(title: String, rows: [(String, Int)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.top, 6)

            if rows.isEmpty {
                Text("No saved data")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows, id: \.0) { label, count in
                    HStack {
                        Text(label)
                        Spacer()
                        Text(count.formatted())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.subheadline)
    }
}
