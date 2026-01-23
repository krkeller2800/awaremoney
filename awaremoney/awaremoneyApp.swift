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
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: [
            Account.self,
            Transaction.self,
            Security.self,
            HoldingSnapshot.self,
            BalanceSnapshot.self,
            ImportBatch.self
        ])
    }
}

