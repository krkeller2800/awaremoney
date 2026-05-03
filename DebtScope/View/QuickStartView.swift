import SwiftUI
import Combine

private enum QuickStartTopic: String, CaseIterable, Identifiable {
    case debtPayoff = "Debt Payoff"
    case netWorth = "Net Worth"
    case cashFlow = "Cash Flow"

    var id: String { rawValue }
    var title: String { rawValue }
}

struct QuickStartView: View {
    @StateObject private var vm: ImportViewModel
    @State private var coordinator: StatementImportCoordinator

    @State private var selection: QuickStartTopic? = .debtPayoff
    @State private var quickStartPending: (url: URL, type: StatementType?, institution: String?)? = nil

    init() {
        let vm = ImportViewModel(parsers: ImportViewModel.defaultParsers())
        _vm = StateObject(wrappedValue: vm)
        _coordinator = State(initialValue: StatementImportCoordinator(vm: vm))
    }

    private func topicFor(statementType: StatementType?) -> QuickStartTopic? {
        switch statementType {
        case .creditCard, .loan:
            return .debtPayoff
        case .bank:
            return .cashFlow
        case .brokerage:
            return .netWorth
        default:
            return .debtPayoff
        }
    }

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
                        vm: vm,
                        coordinator: coordinator,
                        pendingExternal: $quickStartPending
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
        .onReceive(NotificationCenter.default.publisher(for: .quickStartImportRequested)) { notification in
            guard let userInfo = notification.userInfo,
                  let url = userInfo["url"] as? URL else {
                return
            }
            let type = userInfo["type"] as? StatementType
            let institution = userInfo["institution"] as? String
            
            self.selection = topicFor(statementType: type) ?? .debtPayoff
            
            if type == nil {
                Task {
                    let classifier = StatementIntakeClassifier()
                    let detection = await classifier.classify(url: url)
                    await MainActor.run {
                        self.selection = topicFor(statementType: detection.type) ?? .debtPayoff
                    }
                }
            }
            
            self.quickStartPending = (url: url, type: type, institution: institution)
        }
    }
}

extension Notification.Name {
    static let quickStartImportRequested = Notification.Name("QuickStartImportRequested")
}

#Preview {
    QuickStartView()
}
