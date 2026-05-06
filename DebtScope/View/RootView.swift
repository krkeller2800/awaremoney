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
                let ext = url.pathExtension.lowercased()
                if ext == "pdf" {
                    // Route to Quick Start; classify and notify
                    Task {
                        let stagedURL = ImportFileStaging.stageToCaches(url)
                        let classifier = StatementIntakeClassifier()
                        let detection = await classifier.classify(url: stagedURL)
                        NotificationCenter.default.post(name: .quickStartImportRequested, object: nil, userInfo: [
                            "url": stagedURL,
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
