import SwiftUI
import StoreKit
import UIKit

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    // A small curated list of common currencies; can expand later.
    private let supportedCurrencies: [(code: String, name: String)] = [
        ("USD", "US Dollar"),
        ("EUR", "Euro"),
        ("GBP", "British Pound"),
        ("CAD", "Canadian Dollar"),
        ("AUD", "Australian Dollar"),
        ("JPY", "Japanese Yen")
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("General") {
                    Picker("Currency", selection: $settings.currencyCode) {
                        ForEach(supportedCurrencies, id: \.code) { c in
                            Text("\(c.name) (\(c.code))").tag(c.code)
                        }
                    }
                }

                Section("Import behavior") {
                    Toggle("Auto-apply saved CSV mappings", isOn: $settings.importAutoApplyMappings)
                    Toggle("Flip credit card amounts by default", isOn: $settings.creditCardFlipDefault)
                }

                Section("Debt planning defaults") {
                    Picker("Default strategy", selection: $settings.defaultPayoffStrategyRaw) {
                        Text("Minimums Only").tag("minimumsOnly")
                        Text("Snowball").tag("snowball")
                        Text("Avalanche").tag("avalanche")
                    }
                    Toggle("Use Net for Debt as default budget", isOn: $settings.useNetForDebtBudgetDefault)
                }

                Section("Purchases") {
                    Button("Manage Subscription") {
                        if let scene = UIApplication.shared.connectedScenes
                            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
                            Task {
                                try? await AppStore.showManageSubscriptions(in: scene)
                            }
                        } else if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                            UIApplication.shared.open(url)
                        }
                    }
                    Button("Restore Purchases") {
                        NotificationCenter.default.post(name: .restorePurchasesRequested, object: nil)
                    }
                }

                Section("Data & Privacy") {
                    Button("Export Data Backup") {
                        // TODO: implement export
                    }
                    Button("Import Data Backup") {
                        // TODO: implement import
                    }
                    Button(role: .destructive) {
                        // TODO: implement reset (danger zone)
                    } label: {
                        Text("Reset App Data")
                    }
                }

                Section("Appearance & UX") {
                    Toggle("Show hint bars", isOn: $settings.showHintBars)
                    Toggle("Haptics", isOn: $settings.hapticsEnabled)
                    Text("Provides subtle vibration feedback for actions like imports, approvals, and deletes. Turn off if you prefer a quieter experience.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private extension Notification.Name {
    static let restorePurchasesRequested = Notification.Name("RestorePurchasesRequested")
}

#Preview {
    SettingsView()
        .environmentObject(SettingsStore())
}
