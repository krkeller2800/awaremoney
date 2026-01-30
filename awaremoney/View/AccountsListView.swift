import SwiftUI
import SwiftData

struct AccountsListView: View {
    @Query(sort: \Account.name) private var accounts: [Account]
    @State private var refreshTick: Int = 0
#if DEBUG
    @State private var isDebugSettingsPresented: Bool = false
#endif

    var body: some View {
        NavigationStack {
            List {
                ForEach(accounts) { account in
                    NavigationLink(destination: AccountDetailView(accountID: account.id)) {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(!account.name.isEmpty ? account.name : ((account.institutionName?.isEmpty == false) ? account.institutionName! : "Unnamed"))
                                Text(account.type.rawValue.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Accounts")
            .id(refreshTick)
            .onReceive(NotificationCenter.default.publisher(for: .transactionsDidChange)) { _ in
                refreshTick &+= 1
            }
            .onReceive(NotificationCenter.default.publisher(for: .accountsDidChange)) { _ in
                refreshTick &+= 1
            }
#if DEBUG
            .sheet(isPresented: $isDebugSettingsPresented) {
                DebugSettingsView()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isDebugSettingsPresented = true
                    } label: {
                        Label("Debug", systemImage: "ladybug")
                    }
                }
            }
#endif
        }
    }
}

#Preview {
    NavigationStack { AccountsListView() }
}
