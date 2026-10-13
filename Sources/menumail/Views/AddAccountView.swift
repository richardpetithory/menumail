import SwiftUI

/// Connects a Gmail account through the browser. The first time, it also collects the OAuth
/// client (from the user's own Google Cloud project) that every account signs in with.
struct AddAccountView: View {
    enum Style {
        /// The popup's first screen, before any account exists.
        case welcome
        /// A sheet in the Settings window.
        case sheet(dismiss: () -> Void)
    }

    @Environment(MailStore.self) private var store
    let style: Style
    @State private var editsClient = false
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var browser: BrowserProfile?
    @State private var profiles: [BrowserProfile] = []

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    Text(needsClient
                         ? "MenuMail reads your inbox through Gmail's official API. That needs a one-time setup in Google Cloud (about 5 minutes). After it, adding an account is a single sign-in."
                         : "Sign in with Google in your browser. MenuMail never sees your password.")
                        .fixedSize(horizontal: false, vertical: true)

                    if !profiles.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            BrowserPicker(title: "Browser profile", selection: $browser, profiles: profiles)
                            Text("\(needsClient ? "Setup pages and Google sign-in open" : "Google sign-in opens") here, and so will this account's messages. Pick the profile that's signed in to the account you're adding.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if needsClient {
                        setupSteps
                    } else if let client = store.defaultClient, !client.isBuiltIn {
                        HStack {
                            LabeledContent("Your OAuth client") {
                                Text(client.id).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            }
                            Button("Change…") {
                                clientID = client.id
                                clientSecret = client.secret
                                editsClient = true
                            }
                            .buttonStyle(.link)
                            if OAuthClient.builtIn != nil {
                                Button("Use MenuMail's") { store.useBuiltInClient() }
                                    .buttonStyle(.link)
                            }
                        }
                        .font(.caption)
                    }

                    signInHelp
                    if !needsClient, store.defaultClient?.isBuiltIn == true { ownClientButton }

                    if store.isSigningIn {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Waiting for you to finish in the browser…")
                            Spacer()
                            Button("Cancel") { store.cancelSignIn() }
                        }
                    }
                    if let error = store.signInError {
                        ErrorBanner(message: error, onDismiss: { store.signInError = nil })
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                if case .sheet(let dismiss) = style {
                    Spacer()
                    Button("Cancel") {
                        store.cancelSignIn()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    signInButton
                } else {
                    signInButton.frame(maxWidth: .infinity)
                }
            }
            .padding(16)
        }
        .onAppear { profiles = Browsers.installedProfiles() }
        .onChange(of: store.accounts.count) { old, new in
            if new > old, case .sheet(let dismiss) = style { dismiss() }
        }
    }

    @ViewBuilder
    private var header: some View {
        switch style {
        case .welcome:
            HStack(spacing: 10) {
                Image(nsImage: MenuMailIcon.appIcon(size: NSSize(width: 40, height: 40)))
                Text("Welcome to MenuMail").font(.title3.bold())
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.borderless)
                    .help("Quit MenuMail")
            }
        case .sheet:
            Text("Add a Gmail Account").font(.title3.bold())
        }
    }

    private var signInButton: some View {
        Button(action: signIn) {
            Text("Sign In with Google…").frame(maxWidth: style.isWelcome ? .infinity : nil)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(style.isWelcome ? .large : .regular)
        .keyboardShortcut(.defaultAction)
        .disabled(!canSignIn)
    }

    private var needsClient: Bool { editsClient || store.defaultClient == nil }

    /// Console pages for each setup step. Google keeps the last-used project selected.
    private enum Console {
        static let createProject = URL(string: "https://console.cloud.google.com/projectcreate")!
        static let gmailAPI = URL(string: "https://console.cloud.google.com/apis/library/gmail.googleapis.com")!
        static let branding = URL(string: "https://console.cloud.google.com/auth/overview")!
        static let audience = URL(string: "https://console.cloud.google.com/auth/audience")!
        static let createClient = URL(string: "https://console.cloud.google.com/auth/clients/create")!
    }

    private var setupSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(OAuthClient.builtIn == nil ? "One-time setup" : "Your own OAuth client").font(.headline)
                Spacer()
                if editsClient {
                    Button(OAuthClient.builtIn == nil ? "Cancel" : "Use MenuMail's instead") { editsClient = false }
                        .buttonStyle(.link)
                }
            }
            SetupStep(number: 1, title: "Create a project", url: Console.createProject, browser: browser) {
                Text("Name it **MenuMail** and click **Create**. Wait for it to finish, and keep it selected in the project menu at the top of the page.")
            }
            SetupStep(number: 2, title: "Turn on the Gmail API", url: Console.gmailAPI, browser: browser) {
                Text("Click **Enable**.")
            }
            SetupStep(number: 3, title: "Describe the app", url: Console.branding, browser: browser) {
                Text("Click **Get started**. App name: **MenuMail**, and pick your email for the support and contact emails. Audience: **External**. Agree to the policy and click **Create**.")
            }
            SetupStep(number: 4, title: "Publish it", url: Console.audience, browser: browser) {
                Text("Click **Publish app**, then **Confirm**. Skipping this signs you out of MenuMail every 7 days.")
            }
            SetupStep(number: 5, title: "Create the client", url: Console.createClient, browser: browser) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Application type: **Desktop app**. Name: **MenuMail**. Click **Create**, then copy the two values from the dialog that appears into these boxes:")
                    TextField("Client ID", text: $clientID, prompt: Text("Client ID (ends in .apps.googleusercontent.com)"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(signIn)
                    SecureField("Client secret", text: $clientSecret, prompt: Text("Client secret (starts with GOCSPX-)"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(signIn)
                }
            }
        }
    }

    private var signInHelp: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("When you click Sign In").font(.headline)
            Text("Google opens in \(browser?.label ?? "your default browser"). Choose the account. If Google says **Google hasn't verified this app**, click **Advanced**, then **Go to MenuMail (unsafe)**. \(needsClient || store.defaultClient?.isBuiltIn != true ? "That warning is about your own project, which Google hasn't reviewed." : "That means Google hasn't reviewed MenuMail, which is normal for small apps.") Then click **Continue** to allow reading your mail.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("Adding a work (Google Workspace) account?") {
                Text("If sign-in says your organization blocks the app, the OAuth client has to come from a Google Cloud project inside that organization. Click **Use your own OAuth client** and follow the setup signed in to the work account, choosing **Internal** as the audience (no publishing needed).")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .font(.callout)
    }

    private var ownClientButton: some View {
        Button("Use your own OAuth client…") {
            clientID = ""
            clientSecret = ""
            editsClient = true
        }
        .buttonStyle(.link)
        .font(.callout)
    }

    private var enteredClient: OAuthClient? {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.hasSuffix(".apps.googleusercontent.com"), !secret.isEmpty else { return nil }
        return OAuthClient(id: id, secret: secret)
    }

    private var canSignIn: Bool {
        !store.isSigningIn && (needsClient ? enteredClient != nil : store.defaultClient != nil)
    }

    private func signIn() {
        guard canSignIn, let client = needsClient ? enteredClient : store.defaultClient else { return }
        Task {
            await store.addAccount(using: client, browser: browser)
            if store.signInError == nil { editsClient = false }
        }
    }
}

extension AddAccountView.Style {
    var isWelcome: Bool {
        if case .welcome = self { true } else { false }
    }
}

/// A numbered setup step with a button that opens its console page.
private struct SetupStep<Detail: View>: View {
    let number: Int
    let title: String
    let url: URL
    let browser: BrowserProfile?
    @ViewBuilder let detail: Detail

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.callout.bold().monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.accentColor, in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.callout.weight(.semibold))
                    Spacer()
                    Button("Open ↗") { Browsers.open(url, in: browser) }
                        .controlSize(.small)
                }
                detail
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Default browser or a specific Chromium browser profile.
struct BrowserPicker: View {
    let title: String
    @Binding var selection: BrowserProfile?
    let profiles: [BrowserProfile]

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Default browser").tag(BrowserProfile?.none)
            // Keep a saved profile selectable even if its browser was removed.
            if let selection, !profiles.contains(selection) {
                Text(selection.label).tag(Optional(selection))
            }
            ForEach(profiles) { Text($0.label).tag(Optional($0)) }
        }
    }
}
