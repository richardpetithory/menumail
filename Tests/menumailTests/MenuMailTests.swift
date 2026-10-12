import Foundation
import Testing
@testable import menumail

private func message(_ id: String, minutesAgo: Double, from now: Date) -> MailMessage {
    MailMessage(id: id, threadID: id, senderName: "", senderAddress: "a@b.c", subject: "", snippet: "",
                date: now.addingTimeInterval(-minutesAgo * 60), isUnread: false)
}

struct NewCountTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func countsOnlyMessagesAfterLastSeen() {
        let page = InboxPage(messages: [message("1", minutesAgo: 1, from: now), message("2", minutesAgo: 5, from: now),
                                        message("3", minutesAgo: 30, from: now)], hasMore: true)
        let count = NewCount.of(page, since: now.addingTimeInterval(-10 * 60))
        #expect(count == NewCount(count: 2, isCapped: false))
        #expect(count.label == "2")
    }

    @Test func capsWhenEveryFetchedMessageIsNewAndMoreExist() {
        let page = InboxPage(messages: [message("1", minutesAgo: 1, from: now), message("2", minutesAgo: 2, from: now)], hasMore: true)
        #expect(NewCount.of(page, since: now.addingTimeInterval(-3600)).label == "2+")
        #expect(NewCount.of(InboxPage(messages: page.messages, hasMore: false), since: .distantPast).label == "2")
    }

    @Test func emptyInboxIsZero() {
        #expect(NewCount.of(InboxPage(messages: [], hasMore: true), since: .distantPast) == .zero)
    }

    @Test func sumsAcrossAccounts() {
        #expect((NewCount(count: 2, isCapped: false) + NewCount(count: 50, isCapped: true)).label == "52+")
    }
}

struct ParsingTests {
    @Test func parsesFromHeaders() {
        #expect(AddressParser.parse("\"Lovelace, Ada\" <ada@example.com>") == ("Lovelace, Ada", "ada@example.com"))
        #expect(AddressParser.parse("Ada <ada@example.com>") == ("Ada", "ada@example.com"))
        #expect(AddressParser.parse("ada@example.com") == ("", "ada@example.com"))
    }

    @Test func decodesSnippetEntities() {
        #expect(HTMLEntities.decode("It&#39;s &quot;done&quot; &amp; shipped &#x1F680; &bogus; a&b") == "It's \"done\" & shipped 🚀 &bogus; a&b")
    }

    @Test func messageURLTargetsAccountAndThread() {
        let url = message("abc123", minutesAgo: 0, from: .now).webURL(account: "me+x@gmail.com")
        #expect(url.absoluteString == "https://mail.google.com/mail/u/?authuser=me%2Bx@gmail.com#all/abc123")
    }

    @Test func recognizesRateLimitErrors() {
        #expect(MailError.http(429, "Too many concurrent requests for user").isRateLimit)
        #expect(MailError.http(403, #"{"error":{"errors":[{"reason":"userRateLimitExceeded"}]}}"#).isRateLimit)
        #expect(!MailError.http(403, #"{"error":{"errors":[{"reason":"insufficientPermissions"}]}}"#).isRateLimit)
        #expect(!MailError.http(500, "").isRateLimit)
    }

    @Test func summarizesDecodingErrors() throws {
        struct Message: Decodable { struct Header: Decodable { var name: String; var value: String }; var id: String; var headers: [Header] }
        func summary(_ json: String) -> String? {
            do { _ = try JSONDecoder().decode(Message.self, from: Data(json.utf8)); return nil }
            catch let error as DecodingError { return error.summary }
            catch { return "other" }
        }
        #expect(summary(#"{"headers":[]}"#) == "missing id")
        #expect(summary(#"{"id":"1","headers":[{"name":"From"}]}"#) == "missing headers.0.value")
        #expect(summary(#"{"id":1,"headers":[]}"#) == "unexpected value at id")
        #expect(summary("<html>") == "not JSON")
        #expect(MailError.unexpectedResponse("messages.get: missing id").errorDescription?.contains("messages.get: missing id") == true)
    }

    @Test func defaultNicknames() {
        let personal = Account(email: "a@gmail.com", nickname: "Personal", clientID: "", lastSeen: .now)
        #expect(Account.defaultNickname(for: "b@gmail.com", existing: [personal]) == "Personal 2")
        #expect(Account.defaultNickname(for: "ada@acme.co", existing: [personal]) == "Acme")
    }
}

struct DesktopTests {
    // Shape of CGSCopyManagedDisplaySpaces output on a Mac with two desktops and a full-screen app.
    let displays: [[String: Any]] = [[
        "Display Identifier": "DISPLAY-1",
        "Spaces": [
            ["ManagedSpaceID": 1, "id64": 1, "type": 0, "uuid": ""],
            ["ManagedSpaceID": 205, "id64": 205, "type": 0, "uuid": "SPACE-205"],
            ["ManagedSpaceID": 300, "id64": 300, "type": 4, "uuid": "SPACE-300"],
        ],
    ]]

    @Test func numbersDesktopsAndUsesStableKeys() {
        #expect(Desktops.resolve(activeSpaceID: 1, displays: displays)
                == .init(key: "DISPLAY-1/id1", number: 1, isFullScreen: false))
        #expect(Desktops.resolve(activeSpaceID: 205, displays: displays)
                == .init(key: "DISPLAY-1/SPACE-205", number: 2, isFullScreen: false))
        #expect(Desktops.resolve(activeSpaceID: 300, displays: displays)?.isFullScreen == true)
        #expect(Desktops.resolve(activeSpaceID: 999, displays: displays) == nil)
    }

    @Test func currentDesktopIsDetectedOnThisMac() {
        // The private API should be present; if this fails, per-desktop selection is disabled.
        #expect(Desktops.current() != nil)
    }
}

struct BrowserTests {
    @Test func readsChromiumProfiles() throws {
        let localState = #"{"profile":{"info_cache":{"Profile 3":{"name":"Work"},"Default":{"name":"Personal"}}}}"#
        let profiles = Browsers.profiles(fromLocalState: Data(localState.utf8), bundleID: "com.brave.Browser.origin", appName: "Brave Origin")
        #expect(profiles.map(\.label) == ["Brave Origin – Personal", "Brave Origin – Work"])
        #expect(profiles.map(\.directory) == ["Default", "Profile 3"])
        #expect(Browsers.profiles(fromLocalState: Data("{}".utf8), bundleID: "x", appName: "X").isEmpty)
    }

    @Test func listsInstalledProfiles() {
        print("Installed browser profiles:", Browsers.installedProfiles().map(\.label))
    }
}
