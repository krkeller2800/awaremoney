import SwiftUI
import SwiftData

struct AccountsListView: View {
    @Query(sort: \Account.name) private var accounts: [Account]
#if DEBUG
    @State private var isDebugSettingsPresented: Bool = false
#endif
    @State private var isAboutPresented: Bool = false
    @State private var selection: Account.ID? = nil

    var body: some View {
        Group {
            if UIDevice.current.userInterfaceIdiom == .pad {
                NavigationSplitView {
                    List(selection: $selection) {
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
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(!account.name.isEmpty ? account.name : ((account.institutionName?.isEmpty == false) ? account.institutionName! : "Unnamed"))
                                        Text(account.type.rawValue.capitalized)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .tag(account.id)
                            }
                        }
                    }
                    .navigationTitle("Accounts")
                    .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 420)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                isAboutPresented = true
                            } label: {
                                Label("About", systemImage: "info.circle")
                            }
                        }
#if DEBUG
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                isDebugSettingsPresented = true
                            } label: {
                                Label("Debug", systemImage: "ladybug")
                            }
                        }
#endif
                    }
                } detail: {
                    if let sel = selection, let account = accounts.first(where: { $0.id == sel }) {
                        HStack {
                            Spacer(minLength: 0)
                            AccountDetailView(accountID: account.id)
                                .frame(maxWidth: 640)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 16)
                        .safeAreaPadding()
                        .toolbar {
                            ToolbarItem(placement: .principal) {
                                Text(!account.name.isEmpty ? account.name : ((account.institutionName?.isEmpty == false) ? account.institutionName! : "Unnamed"))
                                    .font(.largeTitle).bold()
                            }
                        }
                        .navigationBarTitleDisplayMode(.inline)
                    } else if accounts.isEmpty {
                        ContentUnavailableView("No accounts yet", systemImage: "creditcard")
                    } else {
                        ContentUnavailableView("Select an account", systemImage: "creditcard")
                    }
                }
                .onAppear {
                    if selection == nil {
                        selection = accounts.first?.id
                    }
                }
            } else {
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
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                isAboutPresented = true
                            } label: {
                                Label("About", systemImage: "info.circle")
                            }
                        }
#if DEBUG
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                isDebugSettingsPresented = true
                            } label: {
                                Label("Debug", systemImage: "ladybug")
                            }
                        }
#endif
                    }
                }
            }
        }
        .sheet(isPresented: $isAboutPresented) {
            AboutView()
        }
#if DEBUG
        .sheet(isPresented: $isDebugSettingsPresented) {
            DebugSettingsView()
        }
#endif
    }
}

#Preview {
    AccountsListView()
}
