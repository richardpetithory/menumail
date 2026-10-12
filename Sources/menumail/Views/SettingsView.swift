import SwiftUI

/// The Settings window (⌘,): Accounts and General tabs.
struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = SettingsTab.accounts

    var body: some View {
        TabView(selection: $tab) {
            AccountsSettings()
                .tabItem { Label("Accounts", systemImage: "at") }
                .tag(SettingsTab.accounts)
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
        .frame(width: 640, height: 420)
    }
}

enum SettingsTab: String {
    case accounts
    case general
}

// MARK: - Accounts

private struct AccountsSettings: View {
    @Environment(MailStore.self) private var store
    @State private var selection: String?
    @State private var addsAccount = false
    @State private var pendingRemoval: Account?
    @State private var profiles: [BrowserProfile] = []

    var body: some View {
        HStack(spacing: 0) {
            accountList
                .frame(width: 210)
            Divider()
            Group {
                if let account = store.accounts.first(where: { $0.email == selection }) {
                    AccountDetail(account: account, profiles: profiles).id(account.email)
                } else {
                    ContentUnavailableView("No Accounts", systemImage: "envelope",
                                           description: Text("Click + to add a Gmail account."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            profiles = Browsers.installedProfiles()
            if selection == nil { selection = store.selectedAccount?.email ?? store.accounts.first?.email }
        }
        .onChange(of: store.accounts.map(\.email)) { old, new in
            // Select a newly added account, or a neighbor after removing one.
            if let added = new.first(where: { !old.contains($0) }) { selection = added }
            if let selection, !new.contains(selection) { self.selection = new.first }
        }
        .sheet(isPresented: $addsAccount) {
            AddAccountView(style: .sheet { addsAccount = false })
                .frame(width: 480, height: 640)
        }
        .confirmationDialog("Remove \(pendingRemoval?.email ?? "")?", isPresented: .init(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("Remove Account", role: .destructive) {
                if let pendingRemoval { store.remove(pendingRemoval) }
            }
        } message: {
            Text("MenuMail signs out of this account and forgets which desktops show it.")
        }
    }

    private var accountList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.accounts) { account in
                    AccountListRow(account: account).tag(account.email)
                }
                .onMove { source, destination in store.moveAccounts(fromOffsets: source, toOffset: destination) }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 0) {
                Button { addsAccount = true } label: {
                    Image(systemName: "plus").frame(width: 26, height: 22)
                }
                .help("Add an account")
                Divider().frame(height: 16)
                Button {
                    pendingRemoval = store.accounts.first { $0.email == selection }
                } label: {
                    Image(systemName: "minus").frame(width: 26, height: 22)
                }
                .disabled(selection == nil)
                .help("Remove the selected account")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .background(.background)
    }
}

private struct AccountListRow: View {
    @Environment(MailStore.self) private var store
    let account: Account

    var body: some View {
        HStack(spacing: 8) {
            AccountAvatar(account: account, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.nickname).lineLimit(1)
                Text(account.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if store.inboxes[account.email]?.needsReconnect == true {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .help("Needs to be reconnected")
            }
        }
        .padding(.vertical, 3)
    }
}

/// A colored circle with the account name's initial.
struct AccountAvatar: View {
    let account: Account
    let size: CGFloat

    private static let colors: [Color] = [.blue, .red, .green, .orange, .purple, .teal, .pink]

    var body: some View {
        // FNV-1a: stable across launches, unlike Hasher.
        let hash = account.email.lowercased().utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        Circle()
            .fill(Self.colors[Int(hash % UInt32(Self.colors.count))].gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(account.nickname.prefix(1).uppercased())
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

private struct AccountDetail: View {
    @Environment(MailStore.self) private var store
    let account: Account
    let profiles: [BrowserProfile]
    @State private var nickname = ""

    private var needsReconnect: Bool { store.inboxes[account.email]?.needsReconnect == true }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AccountAvatar(account: account, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.nickname).font(.headline)
                        Text(account.email).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }

            Section {
                TextField("Tab name", text: $nickname)
                    .onChange(of: nickname) { _, new in store.rename(account, to: new) }
                BrowserPicker(title: "Open links in", selection: Binding(
                    get: { account.browser }, set: { store.setBrowser($0, for: account) }
                ), profiles: profiles)
            } footer: {
                Text("Messages and sign-in open in this browser profile. Choose the one that's signed in to \(account.email).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Status") {
                    HStack {
                        if needsReconnect {
                            Label("Signed out", systemImage: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        } else {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                        Button(needsReconnect ? "Reconnect…" : "Sign In Again…") {
                            Task { await store.reconnect(account) }
                        }
                        .disabled(store.isSigningIn)
                    }
                }
                LabeledContent("OAuth client") {
                    Text(account.clientID).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                if store.isSigningIn {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser…")
                        Spacer()
                        Button("Cancel") { store.cancelSignIn() }
                    }
                }
                if let error = store.signInError {
                    ErrorBanner(message: error, onDismiss: { store.signInError = nil })
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { nickname = account.nickname }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                LaunchAtLoginToggle()
            } header: {
                Text("Startup")
            }

            Section {
                Picker("Show new-mail count for", selection: $store.menuBarCountMode) {
                    ForEach(MenuBarCountMode.allCases) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Menu Bar")
            } footer: {
                Text("Each account counts the messages that arrived since you last viewed its tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if let desktop = store.currentDesktop {
                    LabeledContent("Current desktop", value: desktop.label)
                    LabeledContent("Shows account", value: store.desktopAccount.map { "\($0.nickname) (\($0.email))" } ?? "None")
                } else {
                    Text("MenuMail can't tell desktops apart on this Mac, so they all share one selection.")
                }
            } header: {
                Text("Desktops")
            } footer: {
                Text("Each desktop remembers the account tab you last chose on it. Desktops you haven't chosen on show the most recently chosen account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
