//
//  DebtScopeApp.swift
//  DebtScope
//
//  Updated by Assistant on 1/23/26
//

import SwiftUI
import SwiftData
import UIKit
import UniformTypeIdentifiers

@main
struct DebtScopeApp: App {
    let container: ModelContainer
    let settings = SettingsStore()
    let importRouter = ImportOpenRouter()
    @StateObject private var backupCoordinator = BackupOpenCoordinator()
    @Environment(\.scenePhase) private var scenePhase

    @MainActor
    private func runReserveUpdate(asOf date: Date = Date()) {
        let context = ModelContext(container)
        let service = ReserveUpdateService(context: context, settings: settings)
        service.updateReserves(asOf: date)
    }

    @MainActor
    private static func repairAccountIDsIfNeeded(context: ModelContext) {
        do {
            let accounts = try context.fetch(FetchDescriptor<Account>())
            var seen: Set<UUID> = []
            var fixes = 0
            for acct in accounts {
                var needsNew = false
                // Guard against all-zero UUIDs (in case of legacy/migration artifacts)
                if acct.id.uuidString == "00000000-0000-0000-0000-000000000000" {
                    needsNew = true
                }
                // Deduplicate
                if seen.contains(acct.id) {
                    needsNew = true
                }
                if needsNew {
                    let old = acct.id
                    acct.id = UUID()
                    AMLogging.log("Repaired Account id duplicate/invalid: old=\(old) new=\(acct.id)", component: "App")
                    fixes += 1
                }
                seen.insert(acct.id)
            }
            if fixes > 0 {
                try context.save()
                AMLogging.always("Account ID repair completed — fixes=\(fixes)", component: "App")
            } else {
                AMLogging.log("Account ID repair not needed — all IDs valid/unique", component: "App")
            }
        } catch {
            AMLogging.error("Account ID repair failed: \(error.localizedDescription)", component: "App")
        }
    }

    init() {
        let schema = Schema(DebtScopeSchemaV2.models)

        // Ensure Application Support directory exists and build a file URL for the store
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        do {
            try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        } catch {
            AMLogging.log("Failed to create Application Support directory: \(error)", component: "App")
        }
        AMLogging.log("Application Support directory path: \(appSupport.path)", component: "App")
        if let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            AMLogging.always("Documents directory path: \(documents.path)", component: "App")
        }
        let storeURL = appSupport.appendingPathComponent("DebtScope.sqlite")
        Self.verifyStoreLocationWritable(storeURL: storeURL)

        container = Self.buildModelContainer(schema: schema, storeURL: storeURL)
        AMLogging.log("SwiftData store URL: \(storeURL.path)", component: "App")

        let ctx = container.mainContext
        Task { @MainActor in
            DebtScopeApp.repairAccountIDsIfNeeded(context: ctx)
        }

        runInstitutionMigrationIfNeeded()
        ReserveMigrationService.initializeReserveAnchorsIfNeeded(container: container, settings: settings)
        BillFundingAllocationMigrationService.migrateLegacyFundingIfNeeded(container: container, settings: settings)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(PurchaseManager.shared)
                .environmentObject(settings)
                .environmentObject(importRouter)
                .environmentObject(backupCoordinator)
                .onAppear {
                    // Kick off a reserve update at app launch; guarded internally to once per month
                    Task { @MainActor in
                        runReserveUpdate()
                    }
                }
                .onOpenURL { url in
                    // Prefer UTType match first
                    if let rv = try? url.resourceValues(forKeys: [.contentTypeKey]),
                       let type = rv.contentType,
                       type.conforms(to: .debtScopeBackup) {
                        Task { await backupCoordinator.handleOpen(url: url, context: container.mainContext, settings: settings) }
                        AMLogging.always("App opened with backup (UTType): \(url.lastPathComponent)", component: "App")
                        return
                    }

                    // Fallback: extension checks (accept legacy too)
                    let ext = url.pathExtension.lowercased()
                    if ["dsbackup", "debtscopebackup", "json"].contains(ext) {
                        Task { await backupCoordinator.handleOpen(url: url, context: container.mainContext, settings: settings) }
                        AMLogging.always("App opened with backup (ext): \(url.lastPathComponent)", component: "App")
                    } else {
                        importRouter.pendingURL = url
                        AMLogging.always("App opened with non-backup file: \(url.lastPathComponent)", component: "App")
                    }
                }
                .onChange(of: scenePhase) { _, newPhase in
                    AMLogging.log("Scene phase changed to: \(newPhase)", component: "App")
                    if newPhase == .active {
                        Task { @MainActor in
                            runReserveUpdate()
                        }
                    }
                }
        }
        .modelContainer(container)
    }

    // Build the SwiftData container without ever deleting the user's store on failure.
    private static func buildModelContainer(schema: Schema, storeURL: URL) -> ModelContainer {
        do {
            let configuration = ModelConfiguration(url: storeURL)
            return try ModelContainer(
                for: schema,
                migrationPlan: DebtScopeMigrationPlan.self,
                configurations: configuration
            )
        } catch {
            AMLogging.error("ModelContainer creation failed: \(error)", component: "App")
            Self.preserveStoreSnapshotIfPossible(at: storeURL)
            Self.diagnoseModelContainerFailure(schema: schema, storeURL: storeURL, firstError: error, secondError: error)
            fatalError("Failed to create ModelContainer without modifying the existing store: \(error)")
        }
    }

    // Verify the parent directory for the store is writable; logs detailed diagnostics
    private static func verifyStoreLocationWritable(storeURL: URL) {
        let fm = FileManager.default
        let dir = storeURL.deletingLastPathComponent()
        var isDir: ObjCBool = false
        let dirExists = fm.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
        AMLogging.always("SwiftData diagnostics — parent dir exists=\(dirExists) path=\(dir.path)", component: "App")
        // Probe writability by attempting to write a tiny temp file in the parent directory
        let probe = dir.appendingPathComponent(".ds_writability_probe")
        do {
            try "ok".data(using: .utf8)!.write(to: probe, options: .atomic)
            AMLogging.always("SwiftData diagnostics — write probe succeeded at \(probe.lastPathComponent)", component: "App")
            try? fm.removeItem(at: probe)
        } catch {
            AMLogging.error("SwiftData diagnostics — write probe FAILED in parent dir: \(error)", component: "App")
        }
    }

    // Detailed diagnostics to pinpoint SwiftData container failures
    private static func diagnoseModelContainerFailure(schema: Schema, storeURL: URL, firstError: Error, secondError: Error) {
        // Log store URL details
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: storeURL.path)
        AMLogging.always("SwiftData diagnostics — storeURL=\(storeURL.path) exists=\(exists)", component: "App")
        AMLogging.always("SwiftData diagnostics — firstError=\(firstError)", component: "App")
        AMLogging.always("SwiftData diagnostics — secondError=\(secondError)", component: "App")

        // Try building an in-memory container with the full schema to distinguish file vs schema issues
        do {
            let memoryConfig = ModelConfiguration(isStoredInMemoryOnly: true)
            _ = try ModelContainer(for: schema, configurations: memoryConfig)
            AMLogging.always("In-memory ModelContainer succeeded — issue likely with on-disk configuration or path", component: "App")
        } catch {
            AMLogging.error("In-memory ModelContainer failed as well — schema issue likely: \(error)", component: "App")
        }

        // Smoke-test each model type individually to locate the failing type
        // Add your app's model types here
        let modelTypes: [any PersistentModel.Type] = [
            Account.self,
            Transaction.self,
            Security.self,
            HoldingSnapshot.self,
            BalanceSnapshot.self,
            ImportBatch.self,
            CSVColumnMapping.self,
            CashFlowItem.self,
            AssetLiabilityLink.self,
            AccountImportMapping.self,
            BillFundingAllocation.self
        ]

        for model in modelTypes {
            do {
                let testSchema = Schema([model])
                let cfg = ModelConfiguration(isStoredInMemoryOnly: true)
                _ = try ModelContainer(for: testSchema, configurations: cfg)
                AMLogging.log("Schema OK (single model): \(model)", component: "App")
            } catch {
                AMLogging.error("Schema FAIL (single model=\(model)): \(error)", component: "App")
            }
        }
    }

    // Preserve a timestamped copy of the store and sidecars before surfacing a startup failure.
    // This is intentionally non-destructive: if migration fails, user data remains in place.
    private static func preserveStoreSnapshotIfPossible(at url: URL) {
        let fm = FileManager.default
        let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let recoveryDirectory = url.deletingLastPathComponent().appendingPathComponent("Recovery", isDirectory: true)
        do {
            try fm.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        } catch {
            AMLogging.error("Failed to create recovery directory: \(error)", component: "App")
            return
        }

        let candidates = [
            url,
            URL(fileURLWithPath: url.path + "-wal"),
            URL(fileURLWithPath: url.path + "-shm")
        ]

        for source in candidates where fm.fileExists(atPath: source.path) {
            let destination = recoveryDirectory.appendingPathComponent("\(source.lastPathComponent).\(timestamp).bak")
            do {
                if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
                try fm.copyItem(at: source, to: destination)
                AMLogging.always("Preserved recovery copy: \(destination.lastPathComponent)", component: "App")
            } catch {
                AMLogging.error("Failed to preserve recovery copy for \(source.lastPathComponent): \(error)", component: "App")
            }
        }
    }

    // Remove the SQLite store and its sidecar files if present.
    // Kept only as a private utility for deliberate future recovery tooling; normal startup never calls this.
    private static func removeStoreFiles(at url: URL) {
        let fm = FileManager.default
        let base = url
        let wal = URL(fileURLWithPath: base.path + "-wal")
        let shm = URL(fileURLWithPath: base.path + "-shm")
        for candidate in [base, wal, shm] {
            if fm.fileExists(atPath: candidate.path) {
                do {
                    try fm.removeItem(at: candidate)
                    AMLogging.log("Removed store file: \(candidate.path)", component: "App")
                } catch {
                    AMLogging.log("Failed to remove store file: \(candidate.path) — \(error)", component: "App")
                }
            }
        }
    }

    // One-time migration to populate missing institutionName values from the most recent import file name
    private func runInstitutionMigrationIfNeeded() {
        let defaultsKey = "didRunInstitutionMigrationV1"
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: defaultsKey) == false else {
            return
        }
        AMLogging.log("Running institution migration V1", component: "App")

        let context = ModelContext(container)
        do {
            // Fetch accounts missing institutionName
            let predicate = #Predicate<Account> { acct in
                (acct.institutionName == nil) || (acct.institutionName == "")
            }
            var acctDesc = FetchDescriptor<Account>(predicate: predicate)
            acctDesc.sortBy = [SortDescriptor(\Account.createdAt)]
            let accounts = try context.fetch(acctDesc)

            var updatedCount = 0
            for acct in accounts {
                let acctID = acct.id

                // Find most recent BalanceSnapshot for this account
                let balPred = #Predicate<BalanceSnapshot> { snap in
                    snap.account?.id == acctID
                }
                var balDesc = FetchDescriptor<BalanceSnapshot>(predicate: balPred)
                balDesc.sortBy = [SortDescriptor(\BalanceSnapshot.asOfDate, order: .reverse)]
                balDesc.fetchLimit = 1
                let latestBal = try context.fetch(balDesc).first

                // Find most recent HoldingSnapshot for this account
                let holdPred = #Predicate<HoldingSnapshot> { snap in
                    snap.account?.id == acctID
                }
                var holdDesc = FetchDescriptor<HoldingSnapshot>(predicate: holdPred)
                holdDesc.sortBy = [SortDescriptor(\HoldingSnapshot.asOfDate, order: .reverse)]
                holdDesc.fetchLimit = 1
                let latestHold = try context.fetch(holdDesc).first

                // Choose the newer snapshot between balance and holding
                let chosenFileName: String? = {
                    switch (latestBal?.asOfDate, latestHold?.asOfDate) {
                    case let (b?, h?) where b >= h:
                        return latestBal?.importBatch?.sourceFileName
                    case let (b?, h?) where h > b:
                        return latestHold?.importBatch?.sourceFileName
                    case ( _?, nil):
                        return latestBal?.importBatch?.sourceFileName
                    case (nil, _?):
                        return latestHold?.importBatch?.sourceFileName
                    default:
                        return nil
                    }
                }()

                if let fileName = chosenFileName, let guess = guessInstitutionName(from: fileName), !guess.isEmpty {
                    acct.institutionName = guess
                    updatedCount += 1
                }
            }

            if updatedCount > 0 {
                try context.save()
                AMLogging.log("Institution migration updated \(updatedCount) account(s)", component: "App")
            } else {
                AMLogging.log("Institution migration found no accounts to update", component: "App")
            }

            defaults.set(true, forKey: defaultsKey)
        } catch {
            AMLogging.log("Institution migration failed: \(error)", component: "App")
        }
    }

    // Best-effort institution inference from a file name
    private func guessInstitutionName(from fileName: String) -> String? {
        let base = (fileName as NSString).deletingPathExtension
        let lower = base.lowercased()
        let normalized = lower
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")

        let known: [(pattern: String, display: String)] = [
            ("americanexpress", "American Express"),
            ("amex", "American Express"),
            ("bankofamerica", "Bank of America"),
            ("boa", "Bank of America"),
            ("wellsfargo", "Wells Fargo"),
            ("capitalone", "Capital One"),
            ("capone", "Capital One"),
            ("charlesschwab", "Charles Schwab"),
            ("schwab", "Charles Schwab"),
            ("fidelity", "Fidelity"),
            ("vanguard", "Vanguard"),
            ("robinhood", "Robinhood"),
            ("discover", "Discover"),
            ("citibank", "Citi"),
            ("citi", "Citi"),
            ("chase", "Chase"),
            ("sofi", "SoFi")
        ]
        if let match = known.first(where: { normalized.contains($0.pattern) }) {
            return match.display
        }

        // No fallback to tokens from filename — require explicit user input if no known match
        return nil
    }
}
