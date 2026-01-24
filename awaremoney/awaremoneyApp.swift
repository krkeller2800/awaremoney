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
            ImportBatch.self
        ])

        // Ensure Application Support directory exists and build a file URL for the store
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        do {
            try fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        } catch {
            AMLogging.log("Failed to create Application Support directory: \(error)", component: "App")  // DEBUG LOG
        }
        let storeURL = appSupport.appendingPathComponent("awaremoney.store")

        do {
            let configuration = ModelConfiguration(url: storeURL)
            container = try ModelContainer(for: schema, configurations: configuration)
            AMLogging.log("SwiftData store URL: \(storeURL.path)", component: "App")  // DEBUG LOG
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}

