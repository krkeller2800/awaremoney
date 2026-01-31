#if DEBUG
import SwiftUI
import SwiftData

struct DebugSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var verboseEnabled: Bool = AMLogConfig.verbose
    @State private var categoryStates: [String: Bool] = [:]
    private let categoryKeys: [String] = [
        "ImportViewModel",
        "PDFStatementExtractor",
        "PDFSummaryParser",
        "PDFBankTransactionsParser",
        "BrokerageCSVParser",
        "FidelityStatementCSVParser",
        "TransactionsListView",
        "NetWorthView",
        "AccountsListView"
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("Logging") {
                    Toggle(isOn: $verboseEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Verbose Logging (Global)")
                            Text("Controls AMLogging.log (debug-level) globally. Category overrides take precedence.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: verboseEnabled) { _, newValue in
                        AMLogConfig.verbose = newValue
                    }

                    Button("Reset to Default") {
                        UserDefaults.standard.removeObject(forKey: "verbose_logging")
                        AMLogConfig.resetCategoryOverrides()
                        verboseEnabled = AMLogConfig.verbose
                        // Refresh local state for category toggles
                        for key in categoryKeys {
                            categoryStates[key] = AMLogConfig.isVerboseEnabled(for: key)
                        }
                    }
                }

                Section("Categories") {
                    ForEach(categoryKeys, id: \.self) { key in
                        Toggle(isOn: Binding(get: {
                            categoryStates[key, default: AMLogConfig.isVerboseEnabled(for: key)]
                        }, set: { newValue in
                            categoryStates[key] = newValue
                            AMLogConfig.setVerbose(newValue, for: key)
                        })) {
                            Text(key)
                        }
                    }
                }

                Section("Info") {
                    LabeledContent("Subsystem", value: AMLogConfig.subsystem)
                    Text("Filter logs in Console by subsystem/category. Category overrides affect AMLogging.log only.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                #if DEBUG
                Section("Danger Zone") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Hard Delete All Import Batches")
                            .font(.headline)
                        Text("Irreversibly deletes all imported batches, transactions, balances, and holdings. You can re-import files afterward.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            Task { @MainActor in
                                do {
                                    try ImportViewModel.hardDeleteAllBatches(context: modelContext)
                                } catch {
                                    // Intentionally swallow in debug UI; primary flows will surface errors
                                    AMLogging.error("Hard delete all batches failed: \(error.localizedDescription)", component: "DebugSettingsView")
                                }
                            }
                        } label: {
                            Text("Delete All Imported Data")
                        }
                    }
                }
                #endif
            }
            .navigationTitle("Debug Settings")
            .task {
                verboseEnabled = AMLogConfig.verbose
                var dict: [String: Bool] = [:]
                for key in categoryKeys {
                    dict[key] = AMLogConfig.isVerboseEnabled(for: key)
                }
                categoryStates = dict
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
// What comes next: Hook this button up to a dedicated Import History screen where users can view batches, delete one, or replace it with a new file. This view will also surface conflicts and user-modified items.
#endif
