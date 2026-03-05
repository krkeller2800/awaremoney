import SwiftUI
import StoreKit
import UIKit
import SwiftData
import UniformTypeIdentifiers
import LinkPresentation

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var backupDoc: BackupDocument? = nil
    @State private var showExporter = false

    @State private var showImporter = false
    @State private var importSummaryMessage: String? = nil

    @State private var showShareSheet = false
    @State private var shareURL: URL? = nil
    @State private var shareItemSource: BackupActivityItemSource? = nil

    @State private var showResetAlert = false
    @State private var showResetResultAlert = false
    @State private var resetResultMessage: String? = nil

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
                        do {
                            let (data, _) = try BackupExporter.makeBackup(context: modelContext, settings: settings)
                            self.backupDoc = BackupDocument(data: data)
                            self.showExporter = true
                            // Store suggested filename using environment if supported by fileExporter; otherwise ignored here
                            // We'll rely on the system prompt to allow renaming.
                        } catch {
                            AMLogging.error("Backup export failed: \(error.localizedDescription)", component: "SettingsView")
                        }
                    }
                    Button("Share Data Backup") {
                        do {
                            let (data, _) = try BackupExporter.makeBackup(context: modelContext, settings: settings)
                            let df = DateFormatter()
                            df.dateFormat = "yyyy-MM-dd_HHmmss"
                            let name = "AwareMoney-Backup-\(df.string(from: Date())).ambackup"
                            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                            try? FileManager.default.removeItem(at: tmp)
                            try data.write(to: tmp, options: .atomic)
                            presentShare(url: tmp)
                        } catch {
                            AMLogging.error("Backup share build failed: \(error.localizedDescription)", component: "SettingsView")
                        }
                    }
                    Button("Import Data Backup") {
                        showImporter = true
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
            }
            .navigationTitle("Settings")
            .fileExporter(
                isPresented: $showExporter,
                document: backupDoc,
                contentType: .awareMoneyBackup,
                defaultFilename: "AwareMoney-Backup"
            ) { result in
                switch result {
                case .success:
                    AMLogging.always("Backup exported successfully", component: "SettingsView")
                case .failure(let err):
                    AMLogging.error("Backup export error: \(err.localizedDescription)", component: "SettingsView")
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: { var arr: [UTType] = []; if let ext = UTType.awareMoneyBackupByExtension { arr.append(ext) }; if let byExt = UTType(filenameExtension: "ambackup") { arr.append(byExt) }; arr.append(.awareMoneyBackup); arr.append(.json); arr.append(.data); return arr }(),
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let ext = url.pathExtension.lowercased()
                    if ext != "ambackup" && ext != "json" {
                        importSummaryMessage = "Unsupported file. Please choose a .ambackup or .json backup file."
                        return
                    }
                    let started = url.startAccessingSecurityScopedResource()
                    defer { if started { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let data = try Data(contentsOf: url)
                        let summary = try BackupImporter.importBackup(data: data, context: modelContext, settings: settings)
                        importSummaryMessage = makeSummaryText(from: summary)
                    } catch {
                        importSummaryMessage = "Import failed: \(error.localizedDescription)"
                    }
                case .failure(let err):
                    importSummaryMessage = "Import canceled: \(err.localizedDescription)"
                }
            }
            .alert("Import Backup", isPresented: Binding(get: { importSummaryMessage != nil }, set: { if !$0 { importSummaryMessage = nil } })) {
                Button("OK", role: .cancel) { importSummaryMessage = nil }
            } message: {
                Text(importSummaryMessage ?? "")
            }
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
            .sheet(isPresented: $showShareSheet, onDismiss: {
                shareItemSource?.cleanup()
                shareItemSource = nil
                if let url = shareURL {
                    try? FileManager.default.removeItem(at: url)
                    shareURL = nil
                }
            }) {
                if let item = shareItemSource {
                    ActivityView(activityItems: [item])
                        .ignoresSafeArea()
                } else if let url = shareURL {
                    ActivityView(activityItems: [url])
                        .ignoresSafeArea()
                } else {
                    Text("Preparing backup…")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    fileprivate func makeSummaryText(from s: BackupImportSummary) -> String {
        var parts: [String] = []
        if s.settingsUpdated { parts.append("Settings updated") }
        parts.append("Accounts: +\(s.accountsInserted), \(s.accountsUpdated) updated")
        parts.append("Batches: +\(s.batchesInserted), \(s.batchesUpdated) updated")
        parts.append("Balances: +\(s.balanceSnapsInserted), \(s.balanceSnapsUpdated) updated")
        parts.append("CSV Mappings: +\(s.csvMappingsInserted), \(s.csvMappingsUpdated) updated")
        parts.append("Cash Flow Items: +\(s.cashFlowsInserted), \(s.cashFlowsUpdated) updated")
        parts.append("Links: +\(s.linksInserted), \(s.linksUpdated) updated")
        if s.transactionsSkipped > 0 { parts.append("Transactions skipped: \(s.transactionsSkipped)") }
        if s.holdingsSkipped > 0 { parts.append("Holdings skipped: \(s.holdingsSkipped)") }
        return parts.joined(separator: "\n")
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

    fileprivate func presentShare(url: URL) {
        DispatchQueue.main.async {
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.completionWithItemsHandler = { _, _, _, _ in
                try? FileManager.default.removeItem(at: url)
            }
            if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
               let window = scene.windows.first(where: { $0.isKeyWindow }),
               var top = window.rootViewController {
                while let presented = top.presentedViewController { top = presented }
                if let pop = activity.popoverPresentationController {
                    pop.sourceView = top.view
                    pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
                    pop.permittedArrowDirections = []
                }
                top.present(activity, animated: true)
            } else {
                // Fallback to SwiftUI sheet if we can't find a presenting controller
                self.shareURL = url
                self.showShareSheet = true
            }
        }
    }
}

private final class BackupActivityItemSource: NSObject, UIActivityItemSource {
    private let data: Data
    private let filename: String
    private var tempURL: URL? = nil

    init(data: Data, filename: String) {
        self.data = data
        self.filename = filename
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
        if tempURL == nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
            do { try data.write(to: url, options: .atomic) } catch { return data }
            tempURL = url
        }
        return tempURL!
    }

    func activityViewController(_ activityViewController: UIActivityViewController, itemForActivityType activityType: UIActivity.ActivityType?) -> Any? {
        // Provide a file URL for maximum compatibility
        if tempURL == nil {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
            do { try data.write(to: url, options: .atomic) } catch { return data }
            tempURL = url
        }
        return tempURL!
    }

    func activityViewController(_ activityViewController: UIActivityViewController, dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        return UTType.json.identifier
    }

    func activityViewController(_ activityViewController: UIActivityViewController, subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        return "AwareMoney Backup"
    }

    @available(iOS 13.0, *)
    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let meta = LPLinkMetadata()
        meta.title = "AwareMoney Backup"
        return meta
    }

    func cleanup() {
        if let url = tempURL { try? FileManager.default.removeItem(at: url) }
        tempURL = nil
    }
}

private extension Notification.Name {
    static let restorePurchasesRequested = Notification.Name("RestorePurchasesRequested")
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    var excludedActivityTypes: [UIActivity.ActivityType]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let vc = UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
        vc.excludedActivityTypes = excludedActivityTypes
        return vc
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // no-op
    }
}

#Preview {
    SettingsView()
        .environmentObject(SettingsStore())
}

