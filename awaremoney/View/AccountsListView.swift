import SwiftUI
import SwiftData

struct AccountsListView: View {
    @Query(sort: \Account.name) private var accounts: [Account]
#if DEBUG
    @State private var isDebugSettingsPresented: Bool = false
#endif
    @State private var isAboutPresented: Bool = false

    var body: some View {
        NavigationStack {
            List {
                if accounts.isEmpty {
                    ContentUnavailableView(
                        label: {
                            VStack(spacing: 8) {
                                Image("aware")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 64, height: 64)
                                    .foregroundStyle(.secondary)
                                Text("No Accounts Yet")
                                    .font(.title3)
                            }
                        },
                        description: {
                            Text("Go to the Import tab to add statements and activity.")
                        }
                    )
                    .listRowInsets(EdgeInsets())
                } else {
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
            }
            .navigationTitle("Accounts")
            .sheet(isPresented: $isAboutPresented) {
                AboutView()
            }
#if DEBUG
            .sheet(isPresented: $isDebugSettingsPresented) {
                DebugSettingsView()
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        isAboutPresented = true
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                }
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
#if !DEBUG
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    isAboutPresented = true
                } label: {
                    Label("About", systemImage: "info.circle")
                }
            }
        }
#endif
    }
}

#Preview {
    NavigationStack { AccountsListView() }
}
