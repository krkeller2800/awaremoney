import SwiftUI
import StoreKit
import UIKit
import SwiftData

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var showResetAlert = false
    @State private var showResetResultAlert = false
    @State private var resetResultMessage: String? = nil
    @State private var showBackupSheet = false

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
                    Button("Backup & Restore…") {
                        showBackupSheet = true
                    }
                    Button(role: .destructive) {
                        showResetAlert = true
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

                #if DEBUG
                Section("Developer") {
                    Toggle("Show Debug Tools", isOn: $settings.showDebugTools)
                    Text("Hides the in-app Debug toolbar button and related developer UI.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                #endif
            }
            .navigationTitle("Settings")
            .alert(
                "Reset App Data?",
                isPresented: $showResetAlert
            ) {
                Button("Delete All Data", role: .destructive) { performAppDataReset() }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will permanently delete all accounts, transactions, balances, holdings, imports, mappings, and cash flow items. This action cannot be undone.")
            }
            .alert(
                "Reset Complete",
                isPresented: $showResetResultAlert
            ) {
                Button("OK", role: .cancel) { resetResultMessage = nil }
            } message: {
                Text(resetResultMessage ?? "All app data has been reset.")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showBackupSheet) {
                BackupRestoreView().environmentObject(settings)
            }
        }
    }

    fileprivate func performAppDataReset() {
        do {
            // Remove cached statement previews
            removeStatementPreviewCache()

            // Delete in dependency-safe order
            try deleteAll(AssetLiabilityLink.self)
            try deleteAll(BalanceSnapshot.self)
            try deleteAll(HoldingSnapshot.self)
            try deleteAll(Transaction.self)
            try deleteAll(ImportBatch.self)
            try deleteAll(CSVColumnMapping.self)
            try deleteAll(CashFlowItem.self)
            try deleteAll(Account.self)

            try modelContext.save()

            // Reset settings to defaults
            resetSettingsToDefaults()

            // Notify interested views
            NotificationCenter.default.post(name: .transactionsDidChange, object: nil)
            NotificationCenter.default.post(name: .accountsDidChange, object: nil)

            resetResultMessage = "All data has been removed and settings were reset to defaults."
            showResetResultAlert = true
        } catch {
            resetResultMessage = "Reset failed: \(error.localizedDescription)"
            showResetResultAlert = true
            AMLogging.error("Reset failed: \(error.localizedDescription)", component: "SettingsView")
        }
    }

    fileprivate func deleteAll<T: PersistentModel>(_ type: T.Type) throws {
        let all = try modelContext.fetch(FetchDescriptor<T>())
        for obj in all { modelContext.delete(obj) }
    }

    fileprivate func resetSettingsToDefaults() {
        if let id = Locale.current.currency?.identifier, !id.isEmpty {
            settings.currencyCode = id
        } else {
            settings.currencyCode = "USD"
        }
        settings.importAutoApplyMappings = true
        settings.creditCardFlipDefault = false
        settings.defaultPayoffStrategyRaw = "minimumsOnly"
        settings.useNetForDebtBudgetDefault = false
        settings.showHintBars = true
        settings.hapticsEnabled = true
    }

    fileprivate func removeStatementPreviewCache() {
        let fm = FileManager.default
        if let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            let dir = caches.appendingPathComponent("StatementPreviews", isDirectory: true)
            try? fm.removeItem(at: dir)
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

