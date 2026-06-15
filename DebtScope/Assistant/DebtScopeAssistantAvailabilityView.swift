import SwiftUI

struct DebtScopeAssistantAvailabilityView: View {
    @EnvironmentObject private var settings: SettingsStore

    private var availability: DebtScopeAssistantAvailability {
        DebtScopeAssistantAvailability.current(assistantEnabled: settings.assistantEnabled)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Label {
                        Text(availability.title)
                            .font(.title3.weight(.semibold))
                    } icon: {
                        Image(systemName: availability.systemImage)
                            .foregroundStyle(availability.isAvailable ? .green : .orange)
                    }

                    Text(availability.message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            }

            Section("Privacy") {
                Label("Uses on-device Apple Intelligence only", systemImage: "lock.shield")
                Label("Receives scoped DebtScope summaries", systemImage: "doc.text.magnifyingglass")
                Label("Transaction details stay off unless allowed", systemImage: settings.assistantIncludeTransactions ? "checkmark.circle" : "xmark.circle")
            }

            if availability == .disabledInSettings {
                Section {
                    Toggle("DebtScope Assistant", isOn: $settings.assistantEnabled)
                }
            }
        }
        .navigationTitle("Assistant")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        DebtScopeAssistantAvailabilityView()
            .environmentObject(SettingsStore())
    }
}
