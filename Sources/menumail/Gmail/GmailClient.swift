import Foundation

/// Where an account's inbox comes from: Gmail, or sample data in debug previews.
protocol MailService: AnyObject {
    func fetchInbox(limit: Int) async throws -> InboxPage
}

/// Read-only Gmail API v1 client for one account
/// (https://developers.google.com/workspace/gmail/api/reference/rest).
///
/// Each refresh lists the newest inbox message IDs plus the unread ones, and only fetches
/// metadata for messages it hasn't seen before.
final class GmailClient: MailService {
    let auth: GoogleOAuth
    private let baseURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/")!
    private var cache: [String: MailMessage] = [:]
    private static let maxConcurrentFetches = 5
    private static let maxRateLimitRetries = 3

    init(auth: GoogleOAuth) {
        self.auth = auth
    }

    func emailAddress() async throws -> String {
        let data = try await get("profile")
        return try JSONDecoder().decode(Profile.self, from: data).emailAddress
    }

    func fetchInbox(limit: Int) async throws -> InboxPage {
        async let inboxIDs = listIDs(labels: ["INBOX"], limit: limit)
        async let unreadIDs = listIDs(labels: ["INBOX", "UNREAD"], limit: 500)
        let (inbox, unread) = try await (inboxIDs, Set(unreadIDs.ids))

        // Gmail limits concurrent requests per user, so fetch a few at a time. Messages fetched
        // before a failure stay cached, so the next refresh picks up where this one stopped.
        var missing = inbox.ids.filter { cache[$0] == nil }[...]
        try await withThrowingTaskGroup(of: MailMessage.self) { group in
            for _ in 0..<Self.maxConcurrentFetches {
                guard let id = missing.popFirst() else { break }
                group.addTask { try await self.fetchMessage(id) }
            }
            for try await message in group {
                cache[message.id] = message
                if let id = missing.popFirst() { group.addTask { try await self.fetchMessage(id) } }
            }
        }
        // Drop messages that left the inbox so the cache doesn't grow forever.
        cache = cache.filter { inbox.ids.contains($0.key) }

        let messages = inbox.ids.compactMap { id -> MailMessage? in
            guard var message = cache[id] else { return nil }
            message.isUnread = unread.contains(id)
            return message
        }
        return InboxPage(messages: messages.sorted { $0.date > $1.date }, hasMore: inbox.hasMore)
    }

    // MARK: Requests

    private func listIDs(labels: [String], limit: Int) async throws -> (ids: [String], hasMore: Bool) {
        var query = labels.map { URLQueryItem(name: "labelIds", value: $0) }
        query.append(.init(name: "maxResults", value: String(limit)))
        query.append(.init(name: "fields", value: "messages/id,nextPageToken"))
        let page = try JSONDecoder().decode(MessageList.self, from: try await get("messages", query: query))
        return ((page.messages ?? []).map(\.id), page.nextPageToken != nil)
    }

    private func fetchMessage(_ id: String) async throws -> MailMessage {
        let query: [URLQueryItem] = [
            .init(name: "format", value: "metadata"),
            .init(name: "metadataHeaders", value: "From"),
            .init(name: "metadataHeaders", value: "Subject"),
            .init(name: "fields", value: "id,threadId,labelIds,snippet,internalDate,payload/headers"),
        ]
        return try JSONDecoder().decode(APIMessage.self, from: try await get("messages/\(id)", query: query)).message
    }

    private func get(_ path: String, query: [URLQueryItem] = [], attempt: Int = 0, reauthorized: Bool = false) async throws -> Data {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(try await auth.validAccessToken())", forHTTPHeaderField: "Authorization")
        do {
            return try await HTTP.data(for: request)
        } catch MailError.http(401, _) where !reauthorized {
            auth.invalidateAccessToken()
            return try await get(path, query: query, attempt: attempt, reauthorized: true)
        } catch let error as MailError where error.isRateLimit && attempt < Self.maxRateLimitRetries {
            // Exponential backoff with jitter: about 1s, 2s, 4s.
            let delay = Double(1 << attempt) * Double.random(in: 0.8...1.2)
            try await Task.sleep(for: .seconds(delay))
            return try await get(path, query: query, attempt: attempt + 1, reauthorized: reauthorized)
        }
    }
}

// MARK: - Wire format

nonisolated private struct Profile: Decodable {
    var emailAddress: String
}

nonisolated private struct MessageList: Decodable {
    struct Ref: Decodable { var id: String }
    var messages: [Ref]?
    var nextPageToken: String?
}

nonisolated private struct APIMessage: Decodable {
    struct Payload: Decodable { var headers: [Header]? }
    struct Header: Decodable { var name: String; var value: String }

    var id: String
    var threadId: String
    var labelIds: [String]?
    var snippet: String?
    var internalDate: String?
    var payload: Payload?

    var message: MailMessage {
        func header(_ name: String) -> String {
            payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        let from = AddressParser.parse(header("From"))
        let millis = internalDate.flatMap(Double.init) ?? 0
        return MailMessage(id: id, threadID: threadId, senderName: from.name, senderAddress: from.address,
                           subject: header("Subject"), snippet: HTMLEntities.decode(snippet ?? ""),
                           date: Date(timeIntervalSince1970: millis / 1000),
                           isUnread: labelIds?.contains("UNREAD") ?? false)
    }
}
