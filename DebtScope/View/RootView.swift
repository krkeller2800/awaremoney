//
//  RootView.swift
//  DebtScope
//
//  Created by Karl Keller on 1/23/26.
//

import SwiftUI
import Combine
import SwiftData

struct RootView: View {
    @State private var isShowingBackupAlert: Bool = false
    @State private var showImportFlow: Bool = false
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var importRouter: ImportOpenRouter
    @EnvironmentObject private var backupCoordinator: BackupOpenCoordinator
    @EnvironmentObject private var settings: SettingsStore
    
    var body: some View {
        QuickStartView()
        .onReceive(importRouter.$pendingURL) { url in
            if let url = url {
                AMLogging.log("Received import URL: \(url.lastPathComponent)", component: "RootView")
                let stagedURL = ImportFileStaging.stageToCaches(url)
                importRouter.quickStartPendingImport = .init(
                    url: stagedURL,
                    type: nil,
                    institution: nil
                )
                importRouter.pendingURL = nil
                showImportFlow = false
            }
        }
        .sheet(isPresented: $showImportFlow) {
            ImportFlowView()
        }
        .alert("Import Backup", isPresented: $isShowingBackupAlert) {
            Button("OK", role: .cancel) {
                backupCoordinator.alertMessage = nil
            }
        } message: {
            Text(backupCoordinator.alertMessage ?? "")
        }
        .sheet(item: Binding(
            get: { backupCoordinator.pendingRestoreSummary },
            set: { newValue in
                if newValue == nil {
                    backupCoordinator.cancelPendingRestore()
                }
            }
        )) { summary in
            BackupRestoreConfirmationView(summary: summary) {
                backupCoordinator.cancelPendingRestore()
            } onRestore: {
                backupCoordinator.performPendingRestore(context: modelContext, settings: settings)
            }
        }
        .onChange(of: backupCoordinator.alertMessage) { _, newValue in
            isShowingBackupAlert = (newValue != nil)
        }
    }
}
