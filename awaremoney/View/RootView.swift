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
            TransactionsListView()
                .tabItem { Label("Transactions", systemImage: "list.bullet") }

            NetWorthView()
                .tabItem { Label("Net Worth", systemImage: "chart.pie") }

            ImportFlowView()
                .tabItem { Label("Import", systemImage: "tray.and.arrow.down") }
        }
    }
}