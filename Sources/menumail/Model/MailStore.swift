import AppKit
import Observation

/// App state: connected accounts, their inboxes, which account each desktop shows, and the
/// per-account "new since you last looked" counters.
///
/// An account's messages are "seen" while its tab is visible in the open popup: opening the
/// popup (or switching to a tab) clears that account's count, and messages that were new at
/// that moment stay highlighted until the popup closes.
@Observable
final class MailStore {
    nonisolated struct Inbox {
        var page: InboxPage?
        var isLoading = false
        var error: String?
        var needsReconnect = false
        var lastRefresh = Date.distantPast
        /// While the account is being viewed: its `lastSeen` before the view started, so the
        /// messages that were new stay marked.
        var highlightCutoff: Date?
    }

    static let pageSize = 50
    private static let pollInterval: Duration = .seconds(60)

    private(set) var accounts: [Account]
    private(set) var inboxes: [String: Inbox] = [:]
    private(set) var selectedEmail: String?
    private(set) var currentDesktop: Desktops.Desktop?
    private(set) var isPopupOpen = false
    private(set) var isSigningIn = false
    /// Errors from adding or reconnecting accounts.
    var signInError: String?
    var menuBarCountMode: MenuBarCountMode {
        didSet { if persists { Preferences.menuBarCountMode = menuBarCountMode } }
    }

    private var services: [String: MailService] = [:]
    private var desktopSelections: [String: String]
    private var lastSelection: String?
    private var pendingOAuth: GoogleOAuth?
    private let persists: Bool
    private var observers: [NSObjectProtocol] = []

    init() {
        persists = true
        accounts = Preferences.accounts
        desktopSelections = Preferences.desktopSelections
        lastSelection = Preferences.lastSelection
        menuBarCountMode = Preferences.menuBarCountMode
        for account in accounts {
            guard let client = OAuthClient.load(id: account.clientID) else { continue }
            let auth = GoogleOAuth(client: client, refreshToken: Keychain.get(SecretKey.refreshToken(email: account.email)))
            services[account.email] = GmailClient(auth: auth)
        }
        currentDesktop = Desktops.current()
        observeSystem()
        startPolling()
    }

    #if DEBUG
    init(preview accounts: [Account], services: [String: MailService]) {
        persists = false
        self.accounts = accounts
        self.services = services
        desktopSelections = [:]
        lastSelection = accounts.first?.email
        menuBarCountMode = .allAccounts
        currentDesktop = Desktops.current()
        selectedEmail = accounts.first?.email
    }
    #endif

    // MARK: Selection and counts

    var selectedAccount: Account? { accounts.first { $0.email == selectedEmail } ?? accounts.first }

    /// The account the current desktop shows when the popup opens.
    var desktopAccount: Account? {
        let remembered = currentDesktop.flatMap { desktopSelections[$0.key] } ?? lastSelection
        return accounts.first { $0.email == remembered } ?? accounts.first
    }

    func newCount(for account: Account) -> NewCount {
        if isViewing(account.email) { return .zero }
        guard let page = inboxes[account.email]?.page else { return .zero }
        return NewCount.of(page, since: account.lastSeen)
    }

    var menuBarCount: NewCount {
        switch menuBarCountMode {
        case .allAccounts: accounts.map(newCount).reduce(.zero, +)
        case .currentDesktop: desktopAccount.map(newCount) ?? .zero
        }
    }

    /// Whether to highlight `message` as new in the account's list.
    func isNew(_ message: MailMessage, in account: Account) -> Bool {
        message.date > (inboxes[account.email]?.highlightCutoff ?? account.lastSeen)
    }

    func select(_ email: String) {
        guard email != selectedEmail else { return }
        if let previous = selectedEmail { endViewing(previous) }
        selectedEmail = email
        lastSelection = email
        if let desktop = currentDesktop { desktopSelections[desktop.key] = email }
        if persists {
            Preferences.lastSelection = email
            Preferences.desktopSelections = desktopSelections
        }
        if isPopupOpen { beginViewing(email) }
    }

    // MARK: Popup lifecycle

    func popupDidOpen() {
        guard !isPopupOpen else { return }
        isPopupOpen = true
        currentDesktop = Desktops.current()
        selectedEmail = desktopAccount?.email
        if let selectedEmail { beginViewing(selectedEmail) }
        Task { await refreshAll(olderThan: 15) }
    }

    func popupDidClose() {
        guard isPopupOpen else { return }
        if let selectedEmail { endViewing(selectedEmail) }
        isPopupOpen = false
    }

    private func isViewing(_ email: String) -> Bool {
        isPopupOpen && selectedEmail == email
    }

    private func beginViewing(_ email: String) {
        guard let account = accounts.first(where: { $0.email == email }) else { return }
        inboxes[email, default: Inbox()].highlightCutoff = account.lastSeen
        markSeen(email)
    }

    private func endViewing(_ email: String) {
        markSeen(email)
        inboxes[email]?.highlightCutoff = nil
    }

    private func markSeen(_ email: String) {
        guard let index = accounts.firstIndex(where: { $0.email == email }) else { return }
        // A message's date comes from Google's clock; don't let a little skew make it "new".
        let newest = inboxes[email]?.page?.messages.first?.date ?? .distantPast
        accounts[index].lastSeen = max(.now, newest)
        saveAccounts()
    }

    // MARK: Refreshing

    func refreshAll(olderThan age: TimeInterval = 0) async {
        await withTaskGroup(of: Void.self) { group in
            for account in accounts where Date.now.timeIntervalSince(inboxes[account.email]?.lastRefresh ?? .distantPast) >= age {
                group.addTask { await self.refresh(account.email) }
            }
        }
    }

    func refresh(_ email: String) async {
        guard let service = services[email], inboxes[email]?.isLoading != true else { return }
        inboxes[email, default: Inbox()].isLoading = true
        defer { inboxes[email]?.isLoading = false }
        do {
            let page = try await service.fetchInbox(limit: Self.pageSize)
            inboxes[email]?.page = page
            inboxes[email]?.error = nil
            inboxes[email]?.needsReconnect = false
            inboxes[email]?.lastRefresh = .now
            if isViewing(email) { markSeen(email) }
        } catch {
            inboxes[email]?.error = error.localizedDescription
            inboxes[email]?.needsReconnect = (error as? MailError)?.needsReauthentication ?? false
        }
    }

    private func startPolling() {
        Task { [weak self] in
            while true {
                await self?.refreshAll(olderThan: 30)
                try? await Task.sleep(for: Self.pollInterval)
                if self == nil { return }
            }
        }
    }

    private func observeSystem() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.currentDesktop = Desktops.current() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))  // Give the network a moment to come back.
                    await self?.refreshAll()
                }
            }
        })
    }

    // MARK: Accounts

    /// The client new accounts sign in with: the user's own, if they set one up, otherwise the
    /// built-in one.
    var defaultClient: OAuthClient? {
        Preferences.defaultClientID.flatMap(OAuthClient.load) ?? OAuthClient.builtIn
    }

    func useBuiltInClient() {
        Preferences.defaultClientID = nil
    }

    /// Signs in through the browser and adds the chosen account, or reconnects it if it's
    /// already connected.
    func addAccount(using client: OAuthClient, browser: BrowserProfile?, loginHint: String? = nil) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        do {
            let auth = GoogleOAuth(client: client)
            pendingOAuth = auth
            defer { pendingOAuth = nil }
            try await auth.signIn(loginHint: loginHint, browser: browser)
            let gmail = GmailClient(auth: auth)
            let email = try await gmail.emailAddress()

            if !client.isBuiltIn {
                client.save()
                Preferences.defaultClientID = client.id
            }
            Keychain.set(auth.currentRefreshToken, for: SecretKey.refreshToken(email: email))
            services[email] = gmail
            if let index = accounts.firstIndex(where: { $0.email == email }) {
                accounts[index].clientID = client.id
                accounts[index].browser = browser
            } else {
                let nickname = Account.defaultNickname(for: email, existing: accounts)
                accounts.append(Account(email: email, nickname: nickname, clientID: client.id, browser: browser, lastSeen: .now))
            }
            saveAccounts()
            inboxes[email]?.needsReconnect = false
            select(email)
            await refresh(email)
        } catch MailError.cancelled {
            // The user canceled; nothing to report.
        } catch {
            signInError = error.localizedDescription
        }
    }

    func reconnect(_ account: Account) async {
        guard let client = OAuthClient.load(id: account.clientID) ?? defaultClient else {
            signInError = "The OAuth client for \(account.email) is missing. Remove the account and add it again."
            return
        }
        await addAccount(using: client, browser: account.browser, loginHint: account.email)
    }

    func cancelSignIn() {
        pendingOAuth?.cancelSignIn()
    }

    func rename(_ account: Account, to nickname: String) {
        guard let index = accounts.firstIndex(where: { $0.email == account.email }) else { return }
        let trimmed = nickname.trimmingCharacters(in: .whitespaces)
        accounts[index].nickname = trimmed.isEmpty ? Account.defaultNickname(for: account.email, existing: []) : trimmed
        saveAccounts()
    }

    func setBrowser(_ browser: BrowserProfile?, for account: Account) {
        guard let index = accounts.firstIndex(where: { $0.email == account.email }) else { return }
        accounts[index].browser = browser
        saveAccounts()
    }

    /// Opens a Gmail link in the account's browser profile.
    func open(_ url: URL, for account: Account) {
        Browsers.open(url, in: account.browser)
    }

    func moveAccounts(fromOffsets source: IndexSet, toOffset destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        saveAccounts()
    }

    func remove(_ account: Account) {
        let tokenKey = SecretKey.refreshToken(email: account.email)
        if let token = Keychain.get(tokenKey) { Self.revoke(token) }
        Keychain.set(nil, for: tokenKey)
        accounts.removeAll { $0.email == account.email }
        services[account.email] = nil
        inboxes[account.email] = nil
        desktopSelections = desktopSelections.filter { $0.value != account.email }
        if selectedEmail == account.email { selectedEmail = accounts.first?.email }
        if lastSelection == account.email { lastSelection = accounts.first?.email }
        saveAccounts()
        if persists {
            Preferences.desktopSelections = desktopSelections
            Preferences.lastSelection = lastSelection
        }
    }

    /// Desktops (by key) that remember `account`.
    func desktopCount(for account: Account) -> Int {
        desktopSelections.values.count { $0 == account.email }
    }

    private func saveAccounts() {
        if persists { Preferences.accounts = accounts }
    }

    /// Best effort: tells Google to drop the grant so it disappears from the account's
    /// third-party access list.
    private static func revoke(_ token: String) {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTP.formBody([("token", token)])
        Task { _ = try? await HTTP.data(for: request) }
    }
}
