import Foundation

nonisolated struct MailMessage: Identifiable, Equatable, Sendable {
    var id: String
    var threadID: String
    var senderName: String
    var senderAddress: String
    var subject: String
    var snippet: String
    var date: Date
    var isUnread: Bool

    var sender: String { senderName.isEmpty ? senderAddress : senderName }

    /// Gmail web URL for this message's conversation, in the given account.
    func webURL(account email: String) -> URL {
        Self.gmailURL(account: email, fragment: "all/\(threadID)")
    }

    /// `https://mail.google.com/mail/u/?authuser=<email>#<fragment>`; authuser picks the
    /// account when the browser is signed in to several.
    static func gmailURL(account email: String, fragment: String) -> URL {
        var components = URLComponents(string: "https://mail.google.com/mail/u/")!
        components.queryItems = [.init(name: "authuser", value: email)]
        // "+" would otherwise be read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        components.fragment = fragment
        return components.url!
    }
}

/// The most recent inbox messages. `hasMore` means the inbox has older messages beyond these.
nonisolated struct InboxPage: Equatable, Sendable {
    var messages: [MailMessage]
    var hasMore: Bool
}

/// Splits a From header like `"Ada Lovelace" <ada@example.com>` into name and address.
nonisolated enum AddressParser {
    static func parse(_ header: String) -> (name: String, address: String) {
        let header = header.trimmingCharacters(in: .whitespaces)
        guard let open = header.lastIndex(of: "<"), let close = header.lastIndex(of: ">"), open < close else {
            return ("", header)
        }
        let address = String(header[header.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
        var name = header[..<open].trimmingCharacters(in: .whitespaces)
        if name.count >= 2, name.hasPrefix("\""), name.hasSuffix("\"") {
            name = String(name.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        }
        return (name, address)
    }
}

/// Gmail snippets are HTML-escaped (`&#39;`, `&amp;`, …).
nonisolated enum HTMLEntities {
    private static let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var rest = Substring(text)
        while let amp = rest.firstIndex(of: "&") {
            result += rest[..<amp]
            let afterAmp = rest[rest.index(after: amp)...]
            if let semi = afterAmp.prefix(10).firstIndex(of: ";"),
               let decoded = decodeEntity(afterAmp[..<semi]) {
                result += decoded
                rest = afterAmp[afterAmp.index(after: semi)...]
            } else {
                result += "&"
                rest = afterAmp
            }
        }
        return result + rest
    }

    private static func decodeEntity(_ entity: Substring) -> String? {
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            return UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if entity.hasPrefix("#") {
            return UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return named[String(entity)]
    }
}
