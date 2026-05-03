//
//  RootView.swift
//  DebtScope
//
//  Created by Karl Keller on 1/23/26.
//

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import Combine

struct RootView: View {
    @State private var selectedTab: Int = 0
    @State private var lastNonSettingsTab: Int = 0
    @State private var showSettings: Bool = false
    @State private var isShowingBackupAlert: Bool = false
    @State private var showImportFlow: Bool = false
    @EnvironmentObject private var importRouter: ImportOpenRouter
    @EnvironmentObject private var backupCoordinator: BackupOpenCoordinator

    #if canImport(UIKit)
    private func configureTabBarAppearance() {
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground() // opaque background
        appearance.shadowColor = UIColor.separator   // visible top border
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }
    #endif
    
    var body: some View {
        TabView(selection: $selectedTab) {
            QuickStartView()
                .tabItem { Label("Quick Start", systemImage: "sparkles") }
                .tag(0)

            AccountsListView()
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(1)
            
            NetWorthView()
                .tabItem { Label("Net Worth", systemImage: "chart.pie") }
                .tag(2)
            
            DebtDashboardView()
                .tabItem { Label("Debt", systemImage: "creditcard") }
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
                selectedTab = 0
                lastNonSettingsTab = 0
                AMLogging.always("Received import URL: \(url.lastPathComponent)", component: "RootView")
                let ext = url.pathExtension.lowercased()
                if ext == "pdf" {
                    // Route to Quick Start; classify and notify
                    Task {
                        let classifier = StatementIntakeClassifier()
                        let detection = await classifier.classify(url: url)
                        NotificationCenter.default.post(name: .quickStartImportRequested, object: nil, userInfo: [
                            "url": url,
                            "type": detection.type as Any,
                            "institution": detection.institution as Any
                        ])
                        await MainActor.run { importRouter.pendingURL = nil }
                    }
                    showImportFlow = false
                } else {
                    showImportFlow = true
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showImportFlow) {
            ImportFlowView()
        }
        .alert("Import Backup", isPresented: $isShowingBackupAlert) {
            Button("OK", role: .cancel) {
                // Clear the coordinator message when the alert is dismissed
                backupCoordinator.alertMessage = nil
            }
        } message: {
            Text(backupCoordinator.alertMessage ?? "")
        }
        .onChange(of: backupCoordinator.alertMessage) { oldValue, newValue in
            // Present the alert whenever a new message appears
            isShowingBackupAlert = (newValue != nil)
        }
        .onAppear {
            #if canImport(UIKit)
            configureTabBarAppearance()
            #endif
        }
    }
}

