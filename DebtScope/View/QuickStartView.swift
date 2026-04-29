import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Combine
#if canImport(UIKit)
import UIKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif

private enum EnvironmentObjectAccessor<T: ObservableObject> {
    static func access() throws -> T {
        // This is a lightweight shim for this file; in practice, QuickStartView is embedded in RootView with .environmentObject
        // We bridge through the UIApplication to find a SwiftUI Environment when possible.
        #if canImport(UIKit)
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let hosting = scene.windows.first?.rootViewController as? UIHostingController<AnyView> {
            if let obj = hosting.rootView.environmentObject(T.self) as? T {
                return obj
            }
        }
        #endif
        throw NSError(domain: "EnvAccessor", code: -1)
    }
}

private enum QuickStartTopic: String, CaseIterable, Identifiable {
    case debtPayoff = "Debt Payoff"
    case netWorth = "Net Worth"
    case cashFlow = "Cash Flow"

    var id: String { rawValue }
    var title: String { rawValue }
}

struct QuickStartView: View {
    @State private var selection: QuickStartTopic? = .debtPayoff

    var body: some View {
        NavigationSplitView {
            List(QuickStartTopic.allCases, selection: $selection) { topic in
                Text(topic.title)
                    .tag(topic)
            }
            .navigationTitle("Quick Start")
        } detail: {
            Group {
                switch selection {
                case .debtPayoff:
                    DebtPayoffDetailView(
                        importAction: { /* Placeholder for import action */ },
                        manualEntryAction: { /* Placeholder for manual entry action */ }
                    )
                case .netWorth:
                    VStack(spacing: 16) {
                        Text("Net Worth")
                            .font(.largeTitle)
                            .fontWeight(.semibold)
                        Text("Detail coming soon")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                case .cashFlow:
                    VStack(spacing: 16) {
                        Text("Cash Flow")
                            .font(.largeTitle)
                            .fontWeight(.semibold)
                        Text("Detail coming soon")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                case .none:
                    VStack {
                        Text("Select an item from the sidebar")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.background)
                }
            }
            .navigationTitle(selection?.title ?? "Quick Start")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct DebtPayoffDetailView: View {
    var importAction: () -> Void = {}
    var manualEntryAction: () -> Void = {}

    @Query(sort: [SortDescriptor(\Account.name, order: .forward)]) private var accounts: [Account]
    @EnvironmentObject private var importRouter: ImportOpenRouter
    @State private var showImporter = false
    @State private var lastDetection: IntakeDetection?
    @State private var importError: Error?
    @State private var editedInstitution: String = ""
    @State private var selectedType: StatementType? = nil

    // Item-based sheet model to avoid timing issues with boolean presentation
    private struct DetectionSheetModel: Identifiable {
        let id = UUID()
        var detection: IntakeDetection
        var url: URL
    }
    @State private var detectionSheetModel: DetectionSheetModel? = nil
    @FocusState private var focusedField: FocusedField?
    private enum FocusedField: Hashable { case institution }

    private static let importTypes: [UTType] = {
        var types: [UTType] = [.pdf, .commaSeparatedText, .tabSeparatedText, .text, .data]
        let exts = ["qfx","ofx","qbo","qif","xlsx","xls","csv","tsv","txt","zip"]
        types.append(contentsOf: exts.compactMap { UTType(filenameExtension: $0) })
        return types
    }()

    @ViewBuilder
    private var columnsView: some View {
        HStack(alignment: .top, spacing: 0) {
            accountsColumn
            Divider()
                .frame(maxHeight: .infinity)
                .padding(.vertical, 8)
            toolsColumn
        }
    }

    private var accountsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Accounts")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
            List {
                if accounts.isEmpty {
                    ContentUnavailableView(
                        "No Accounts Yet",
                        systemImage: "creditcard",
                        description: Text("Use Import or Add Manually to get started.")
                    )
                    .listRowInsets(EdgeInsets())
                } else {
                    ForEach(accounts) { account in
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayInstitution(for: account))
                                Text(account.type.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(formattedBalance(for: account))
                                .monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator, lineWidth: 0.5)
        )
        .padding(8)
    }

    private var toolsColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TBD")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)
            ContentUnavailableView("Coming Soon", systemImage: "hourglass", description: Text("More tools will appear here."))
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator, lineWidth: 0.5)
        )
        .padding(8)
    }

    // PDF Preview support
    @ViewBuilder
    private func pdfPreview(for url: URL) -> some View {
        #if canImport(PDFKit)
        if url.pathExtension.lowercased() == "pdf" {
            PDFKitRepresentedView(url: url)
                .background(Color.clear)
        } else {
            ContentUnavailableView("No PDF Preview", systemImage: "doc.text", description: Text("Selected file is not a PDF."))
        }
        #else
        ContentUnavailableView("Preview Unavailable", systemImage: "doc", description: Text("PDF preview isn't supported on this platform."))
        #endif
    }

    #if canImport(PDFKit)
    private struct PDFKitRepresentedView: View {
        let url: URL
        var body: some View {
            #if canImport(UIKit)
            PDFKitUIView(url: url)
            #else
            PDFKitNSView(url: url)
            #endif
        }
    }

    #if canImport(UIKit)
    private struct PDFKitUIView: UIViewRepresentable {
        let url: URL
        func makeUIView(context: Context) -> PDFView {
            let view = PDFView()
            view.autoScales = true
            view.displayMode = .singlePageContinuous
            view.displaysAsBook = false
            view.backgroundColor = .clear
            view.document = PDFDocument(url: url)
            return view
        }
        func updateUIView(_ uiView: PDFView, context: Context) {
            uiView.document = PDFDocument(url: url)
        }
    }
    #else
    private struct PDFKitNSView: NSViewRepresentable {
        let url: URL
        func makeNSView(context: Context) -> PDFView {
            let view = PDFView()
            view.autoScales = true
            view.displayMode = .singlePageContinuous
            view.displaysAsBook = false
            view.backgroundColor = .clear
            view.document = PDFDocument(url: url)
            return view
        }
        func updateNSView(_ nsView: PDFView, context: Context) {
            nsView.document = PDFDocument(url: url)
        }
    }
    #endif
    #endif

    var body: some View {
        VStack(spacing: 16) {
//            Text("Debt Payoff")
//                .font(.largeTitle)
//                .fontWeight(.semibold)
            Text("Get started by adding your credit accounts")
                .foregroundStyle(.secondary)

            // Two-column content area
            columnsView

            Divider().padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 32)
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Import") { showImporter = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Manually") { manualEntryAction() }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: Self.importTypes, allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    handleImport(url: url)
                } else {
                    importError = NSError(domain: "Import", code: -1, userInfo: [NSLocalizedDescriptionKey: "No file selected"]) as Error
                }
            case .failure(let error):
                importError = error
            }
        }
#if os(iOS) || os(visionOS)
        .sheet(item: $detectionSheetModel) { model in
            NavigationStack {
                HStack(spacing: 0) {
                    // Left column: existing controls
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Review detected details and make changes if needed.")
                            .foregroundStyle(.secondary)

                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("Type")
                            Spacer()
                            Picker("Type", selection: $selectedType) {
                                Text("Choose…").tag(nil as StatementType?)
                                ForEach(Array(StatementType.allCases.enumerated()), id: \.offset) { _, t in
                                    Text(displayName(for: t)).tag(StatementType?.some(t))
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        HStack {
                            Text("Confidence")
                            Spacer()
                            Text("\(Int(model.detection.confidence * 100))%")
                                .fontWeight(.semibold)
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("Institution")
                            Spacer()
                            HStack(spacing: 6) {
                                TextField("Institution", text: $editedInstitution)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedField, equals: .institution)
                                    .frame(minWidth: 200)
                                Button {
                                    focusedField = .institution
                                    #if canImport(UIKit)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                                    }
                                    #endif
                                } label: {
                                    Image(systemName: "pencil")
                                        .imageScale(.small)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Edit institution")
                            }
                        }

                        Spacer()
                    }
                    .frame(minWidth: 320, maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)
                    .padding()

                    Divider()

                    // Right column: PDF preview
                    pdfPreview(for: model.url)
                        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
                        .background(.quaternary.opacity(0.1))
                }
                .frame(minWidth: 800, minHeight: 600)
                .navigationTitle("Import Ready")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { detectionSheetModel = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Continue") {
                            var det = model.detection
                            det.type = selectedType
                            det.institution = editedInstitution.trimmingCharacters(in: .whitespacesAndNewlines)
                            lastDetection = det

                            // Stage the picked file into the app's caches directory to ensure readable access across contexts
                            let sourceURL = model.url
                            var routedURL = sourceURL
                            do {
                                #if os(iOS) || os(visionOS)
                                let granted = sourceURL.startAccessingSecurityScopedResource()
                                defer { if granted { sourceURL.stopAccessingSecurityScopedResource() } }
                                #endif
                                let fm = FileManager.default
                                if let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
                                    let dest = caches.appendingPathComponent(sourceURL.lastPathComponent)
                                    try? fm.removeItem(at: dest)
                                    try fm.copyItem(at: sourceURL, to: dest)
                                    routedURL = dest
                                }
                            } catch {
                                routedURL = sourceURL
                            }

                            // Route via shared environment router
                            importRouter.pendingURL = routedURL
                            importRouter.pendingType = det.type
                            importRouter.pendingInstitution = det.institution

                            detectionSheetModel = nil
                        }
                    }
                }
            }
            .presentationSizing(.page)
        }
#else
        .sheet(item: $detectionSheetModel) { model in
            NavigationStack {
                HStack(spacing: 0) {
                    // Left column: existing controls
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Review detected details and make changes if needed.")
                            .foregroundStyle(.secondary)

                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("Type")
                            Spacer()
                            Picker("Type", selection: $selectedType) {
                                Text("Choose…").tag(nil as StatementType?)
                                ForEach(Array(StatementType.allCases.enumerated()), id: \.offset) { _, t in
                                    Text(displayName(for: t)).tag(StatementType?.some(t))
                                }
                            }
                            .pickerStyle(.menu)
                        }

                        HStack {
                            Text("Confidence")
                            Spacer()
                            Text("\(Int(model.detection.confidence * 100))%")
                                .fontWeight(.semibold)
                        }

                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("Institution")
                            Spacer()
                            HStack(spacing: 6) {
                                TextField("Institution", text: $editedInstitution)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedField, equals: .institution)
                                    .frame(minWidth: 200)
                                Button {
                                    focusedField = .institution
                                    #if canImport(UIKit)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                        UIApplication.shared.sendAction(#selector(UIResponder.selectAll(_:)), to: nil, from: nil, for: nil)
                                    }
                                    #endif
                                } label: {
                                    Image(systemName: "pencil")
                                        .imageScale(.small)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Edit institution")
                            }
                        }

                        Spacer()
                    }
                    .frame(minWidth: 320, maxWidth: 420, maxHeight: .infinity, alignment: .topLeading)
                    .padding()

                    Divider()

                    // Right column: PDF preview
                    pdfPreview(for: model.url)
                        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
                        .background(.quaternary.opacity(0.1))
                }
                .frame(minWidth: 800, minHeight: 600)
                .navigationTitle("Import Ready")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { detectionSheetModel = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Continue") {
                            var det = model.detection
                            det.type = selectedType
                            det.institution = editedInstitution.trimmingCharacters(in: .whitespacesAndNewlines)
                            lastDetection = det

                            // Route to ImportFlow with explicit hints so parsing starts immediately
                            // Stage the picked file into the app's caches directory to ensure readable access across contexts
                            let sourceURL = model.url
                            var routedURL = sourceURL
                            do {
                                let fm = FileManager.default
                                if let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
                                    let dest = caches.appendingPathComponent(sourceURL.lastPathComponent)
                                    try? fm.removeItem(at: dest)
                                    try fm.copyItem(at: sourceURL, to: dest)
                                    routedURL = dest
                                }
                            } catch {
                                routedURL = sourceURL
                            }
                            importRouter.pendingURL = routedURL
                            importRouter.pendingType = det.type
                            importRouter.pendingInstitution = det.institution
                            detectionSheetModel = nil
                        }
                    }
                }
            }
        }
#endif
    }

    private func handleImport(url: URL) {
        Task {
            var accessGranted = false
            #if os(iOS) || os(visionOS)
            accessGranted = url.startAccessingSecurityScopedResource()
            defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }
            #endif
            let classifier = StatementIntakeClassifier()
            let detection = await classifier.classify(url: url)
            await MainActor.run {
                self.lastDetection = detection
                self.editedInstitution = detection.institution ?? ""
                self.selectedType = detection.type
                self.detectionSheetModel = DetectionSheetModel(detection: detection, url: url)
            }
        }
    }

    private func latestBalance(for account: Account) -> Decimal? {
        return account.balanceSnapshots.sorted { $0.asOfDate > $1.asOfDate }.first?.balance
    }

    private func formattedBalance(for account: Account) -> String {
        guard let bal = latestBalance(for: account) else { return "—" }
        let nf = NumberFormatter()
        nf.numberStyle = .currency
        return nf.string(from: NSDecimalNumber(decimal: bal)) ?? "\(bal)"
    }

    private func displayInstitution(for account: Account) -> String {
        let inst = (account.institutionName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !inst.isEmpty { return inst }
        let name = account.name
        return name.isEmpty ? "Unnamed" : name
    }

    private func displayName(for type: StatementType) -> String {
        switch type {
        case .creditCard: return "Credit Card"
        case .bank:       return "Bank"
        case .brokerage:  return "Brokerage"
        case .loan:       return "Loan"
        }
    }
}

extension Notification.Name {
    static let quickStartImportRequested = Notification.Name("QuickStartImportRequested")
}

#Preview {
    QuickStartView()
}

