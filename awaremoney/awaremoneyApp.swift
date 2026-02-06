//
//  AwareMoneyApp.swift
//  Aware Money
//
//  Updated by Assistant on 1/23/26
//

import SwiftUI
import SwiftData

@main
struct awaremoneyApp: App {
    let container: ModelContainer

    init() {
        let schema = Schema([
            Account.self,
            Transaction.self,
            Security.self,
            HoldingSnapshot.self,
            BalanceSnapshot.self,
            ImportBatch.self,
            CSVColumnMapping.self
        ])

        // Ensure Application Support directory exists and build a file URL for the store
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        do {
            try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        } catch {
            AMLogging.always("Failed to create Application Support directory: \(error)", component: "App")
        }
        AMLogging.always("Application Support directory path: \(appSupport.path)", component: "App")
        if let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            AMLogging.always("Documents directory path: \(documents.path)", component: "App")
        }
        let storeURL = appSupport.appendingPathComponent("awaremoney.store")

        container = Self.buildModelContainer(schema: schema, storeURL: storeURL)
        AMLogging.always("SwiftData store URL: \(storeURL.path)", component: "App")
        runInstitutionMigrationIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }

    // Build the SwiftData container with a retry after deleting an incompatible store
    private static func buildModelContainer(schema: Schema, storeURL: URL) -> ModelContainer {
        do {
            let configuration = ModelConfiguration(url: storeURL)
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            AMLogging.always("Initial ModelContainer creation failed: \(error). Removing store and retrying.", component: "App")
            Self.removeStoreFiles(at: storeURL)
            do {
                let configuration = ModelConfiguration(url: storeURL)
                return try ModelContainer(for: schema, configurations: configuration)
            } catch {
                fatalError("Failed to create ModelContainer after deleting store: \(error)")
            }
        }
    }

    // Remove the SQLite store and its sidecar files if present
    private static func removeStoreFiles(at url: URL) {
        let fm = FileManager.default
        let base = url
        let wal = URL(fileURLWithPath: base.path + "-wal")
        let shm = URL(fileURLWithPath: base.path + "-shm")
        for candidate in [base, wal, shm] {
            if fm.fileExists(atPath: candidate.path) {
                do {
                    try fm.removeItem(at: candidate)
                    AMLogging.always("Removed store file: \(candidate.path)", component: "App")
                } catch {
                    AMLogging.always("Failed to remove store file: \(candidate.path) — \(error)", component: "App")
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
        AMLogging.always("Running institution migration V1", component: "App")

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
                AMLogging.always("Institution migration updated \(updatedCount) account(s)", component: "App")
            } else {
                AMLogging.always("Institution migration found no accounts to update", component: "App")
            }

            defaults.set(true, forKey: defaultsKey)
        } catch {
            AMLogging.always("Institution migration failed: \(error)", component: "App")
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

