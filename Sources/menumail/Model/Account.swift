import Foundation

/// A connected Gmail account. Non-secret settings live in UserDefaults; the refresh token
/// lives in the Keychain under the email address.
nonisolated struct Account: Codable, Identifiable, Equatable, Sendable {
    var email: String
    var nickname: String
    var clientID: String
    /// Where this account's links (and sign-in) open; nil means the default browser.
    var browser: BrowserProfile?
    /// Messages that arrived after this moment count as new. Moves forward whenever the
    /// account's tab is shown in the popup.
    var lastSeen: Date

    var id: String { email }

    static func defaultNickname(for email: String, existing: [Account]) -> String {
        let domain = email.split(separator: "@").last.map { String($0).lowercased() } ?? ""
        let base: String
        if domain == "gmail.com" || domain == "googlemail.com" {
            base = "Personal"
        } else {
            base = domain.split(separator: ".").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? email
        }
        let taken = Set(existing.map(\.nickname))
        var name = base
        var suffix = 2
        while taken.contains(name) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        return name
    }
}

nonisolated enum MenuBarCountMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case allAccounts
    case currentDesktop

    var id: String { rawValue }

    var label: String {
        switch self {
        case .allAccounts: "All accounts"
        case .currentDesktop: "This desktop's account"
        }
    }
}

/// How many messages are new. `isCapped` means at least `count` (every fetched message is new).
nonisolated struct NewCount: Equatable, Sendable {
    var count: Int
    var isCapped: Bool

    static let zero = NewCount(count: 0, isCapped: false)

    static func + (lhs: NewCount, rhs: NewCount) -> NewCount {
        NewCount(count: lhs.count + rhs.count, isCapped: lhs.isCapped || rhs.isCapped)
    }

    var label: String { isCapped ? "\(count)+" : "\(count)" }

    /// Counts the messages in `page` that arrived after `lastSeen`.
    static func of(_ page: InboxPage, since lastSeen: Date) -> NewCount {
        let count = page.messages.count { $0.date > lastSeen }
        return NewCount(count: count, isCapped: page.hasMore && count == page.messages.count && count > 0)
    }
}

/// Everything MenuMail persists outside the Keychain.
struct Preferences {
    private static var defaults: UserDefaults { .standard }

    static var accounts: [Account] {
        get { decode([Account].self, "accounts") ?? [] }
        set { encode(newValue, "accounts") }
    }

    /// Desktop key (see `Desktops.Desktop.key`) → selected account email.
    static var desktopSelections: [String: String] {
        get { decode([String: String].self, "desktopSelections") ?? [:] }
        set { encode(newValue, "desktopSelections") }
    }

    /// The most recently selected account, used on desktops without a selection of their own.
    static var lastSelection: String? {
        get { defaults.string(forKey: "lastSelection") }
        set { defaults.set(newValue, forKey: "lastSelection") }
    }

    /// The OAuth client used when adding accounts.
    static var defaultClientID: String? {
        get { defaults.string(forKey: "defaultClientID") }
        set { defaults.set(newValue, forKey: "defaultClientID") }
    }

    static var menuBarCountMode: MenuBarCountMode {
        get { defaults.string(forKey: "menuBarCountMode").flatMap(MenuBarCountMode.init) ?? .allAccounts }
        set { defaults.set(newValue.rawValue, forKey: "menuBarCountMode") }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func encode<T: Encodable>(_ value: T, _ key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }
}
