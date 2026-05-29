//
//  RootView.swift
//  DebtScope
//
//  Created by Karl Keller on 1/23/26.
//

import SwiftUI
import Combine

struct RootView: View {
    @State private var isShowingBackupAlert: Bool = false
    @State private var showImportFlow: Bool = false
    @EnvironmentObject private var importRouter: ImportOpenRouter
    @EnvironmentObject private var backupCoordinator: BackupOpenCoordinator
    
    var body: some View {
        QuickStartView()
        .onReceive(importRouter.$pendingURL) { url in
            if let url = url {
                AMLogging.always("Received import URL: \(url.lastPathComponent)", component: "RootView")
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
    }
}
