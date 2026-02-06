//
//  RootView.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            AccountsListView()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }

            NetWorthView()
                .tabItem { Label("Net Worth", systemImage: "chart.pie") }

            DebtDashboardView()
                .tabItem { Label("Debt", systemImage: "creditcard") }

            ImportFlowView()
                .tabItem { Label("Import", systemImage: "tray.and.arrow.down") }
        }
    }
}

