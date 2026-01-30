#if DEBUG
import SwiftUI

struct DebugSettingsView: View {
    @Environment(\.dismiss) private var dismiss
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
#endif
