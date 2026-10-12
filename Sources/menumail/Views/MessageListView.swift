import SwiftUI

struct MessageListView: View {
    @Environment(MailStore.self) private var store
    let account: Account

    private var inbox: MailStore.Inbox? { store.inboxes[account.email] }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let error = inbox?.error {
                ErrorBanner(message: error, action: inbox?.needsReconnect == true
                    ? ("Reconnect \(account.email)…", { Task { await store.reconnect(account) } })
                    : nil)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
            Divider()
            // Content goes on an opaque surface, like Mail's message list; the popup's glass
            // material stays behind the header. Text over glass loses too much contrast.
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(account.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(statusLine).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if inbox?.isLoading == true {
                ProgressView().controlSize(.small)
            } else {
                Button { Task { await store.refresh(account.email) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh")
            }
            Button { store.open(Self.inboxURL(account.email), for: account) } label: {
                Label("Open Gmail", systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.borderless)
            .help("Open this inbox in \(account.browser?.label ?? "your browser")")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var statusLine: String {
        guard let inbox, let page = inbox.page else { return "Loading…" }
        let newCount = page.messages.count { store.isNew($0, in: account) }
        let unread = page.messages.count(where: \.isUnread)
        var parts: [String] = []
        if newCount > 0 { parts.append("\(newCount) new") }
        parts.append("\(unread)\(page.hasMore && unread == page.messages.count ? "+" : "") unread")
        parts.append("updated \(inbox.lastRefresh.formatted(.relative(presentation: .named)))")
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var content: some View {
        if let messages = inbox?.page?.messages {
            if messages.isEmpty {
                ContentUnavailableView("Inbox zero", systemImage: "tray",
                                       description: Text("Nothing in \(account.nickname)'s inbox."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(messages) { message in
                            MessageRow(message: message, isNew: store.isNew(message, in: account)) {
                                store.open(message.webURL(account: account.email), for: account)
                            }
                            Divider().padding(.leading, 26)
                        }
                        if inbox?.page?.hasMore == true {
                            Button("Older messages in Gmail…") { store.open(Self.inboxURL(account.email), for: account) }
                                .buttonStyle(.link)
                                .font(.caption)
                                .padding(10)
                        }
                    }
                }
            }
        } else if inbox?.error == nil {
            ProgressView().frame(maxHeight: .infinity)
        } else {
            Spacer()
        }
    }

    static func inboxURL(_ email: String) -> URL {
        MailMessage.gmailURL(account: email, fragment: "inbox")
    }
}

struct MessageRow: View {
    let message: MailMessage
    let isNew: Bool
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(message.isUnread ? Color.accentColor : .clear)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(message.sender)
                            .fontWeight(message.isUnread ? .semibold : .regular)
                            .lineLimit(1)
                        if isNew {
                            Text("NEW")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.red, in: .rect(cornerRadius: 3))
                        }
                        Spacer(minLength: 6)
                        Text(Self.shortDate(message.date))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                        .font(.callout)
                        .fontWeight(message.isUnread ? .medium : .regular)
                        .lineLimit(1)
                    if !message.snippet.isEmpty {
                        Text(message.snippet)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open in Gmail")
    }

    private var rowBackground: Color {
        if isHovered { return Color.primary.opacity(0.07) }
        return isNew ? Color.red.opacity(0.06) : .clear
    }

    /// Time for today, weekday for the last week, otherwise a short date (like Gmail).
    static func shortDate(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
           days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
