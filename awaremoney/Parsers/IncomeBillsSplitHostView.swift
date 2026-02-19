import SwiftUI
import SwiftData

struct IncomeBillsSplitHostView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \CashFlowItem.createdAt, order: .reverse) private var items: [CashFlowItem]
    
    enum SidebarItem: Hashable {
        case incomeBills
        case summary
    }
    
    @State private var selection: SidebarItem? = .incomeBills
    
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
                    Button { dismiss()
                    } label: {
                        Text("Done")
                      }
                    .buttonStyle(Toolbarbutton())
                }
            }
        } detail: {
            Group {
                switch selection {
                case .summary:
                    List {
                        IncomeBillsSummarySections(items: items)
                    }
                    .listStyle(.insetGrouped)
                    .navigationTitle("Summary")
                default:
                    IncomeAndBillsView()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

