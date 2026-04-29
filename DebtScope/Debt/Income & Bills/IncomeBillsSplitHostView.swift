import SwiftUI
import SwiftData

struct IncomeBillsSplitHostView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CashFlowItem.createdAt, order: .reverse) private var items: [CashFlowItem]
    @EnvironmentObject private var settings: SettingsStore
    
    enum SidebarItem: Hashable {
        case incomeBills
        case summary
    }
    
    @State private var selection: SidebarItem? = .incomeBills
    
    @MainActor
    private func runReserveUpdate() {
        let service = ReserveUpdateService(context: modelContext, settings: settings)
        service.updateReserves()
    }
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                NavigationLink(value: SidebarItem.incomeBills) {
                    Label("Income & Bills", systemImage: "list.bullet.rectangle")
                }
                NavigationLink(value: SidebarItem.summary) {
                    Label("Summary", systemImage: "chart.pie")
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Debt Budget")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                    }
                    .buttonStyle(Toolbarbutton())
                }
            }
        } detail: {
            VStack(spacing: 0) {
                switch selection {
                case .summary:
                    DebtSummaryView()
                        .environmentObject(settings)
                        .navigationTitle("Summary")
                default:
                    IncomeAndBillsView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .task {
                // Trigger reserve update when opening Income & Bills or Summary; guarded internally per month
                await MainActor.run {
                    runReserveUpdate()
                }
            }
        }
    }
}

