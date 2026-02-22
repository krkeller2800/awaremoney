//
//  RootView.swift
//  awaremoney
//
//  Created by Karl Keller on 1/23/26.
//

import SwiftUI

struct RootView: View {
    @State private var selectedTab: Int = 0
    @State private var lastNonSettingsTab: Int = 0
    @State private var showSettings: Bool = false
    @EnvironmentObject private var importRouter: ImportOpenRouter
    
    var body: some View {
        TabView(selection: $selectedTab) {
            AccountsListView()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(0)
            
            NetWorthView()
                .tabItem { Label("Net Worth", systemImage: "chart.pie") }
                .tag(1)
            
            DebtDashboardView()
                .tabItem { Label("Debt", systemImage: "creditcard") }
                .tag(2)
            
            ImportFlowView()
                .tabItem { Label("Import", systemImage: "tray.and.arrow.down") }
                .tag(3)
            
            Color.clear
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(999)
        }
        .onChange(of: selectedTab) { oldValue, newValue in
            if newValue == 999 {
                selectedTab = lastNonSettingsTab
                showSettings = true
            } else {
                lastNonSettingsTab = newValue
            }
        }
        .onReceive(importRouter.$pendingURL) { url in
            if let url = url {
                selectedTab = 3
                lastNonSettingsTab = 3
                AMLogging.always("RootView", component: "Received import URL: \(url.lastPathComponent)")
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

