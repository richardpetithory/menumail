#if DEBUG
import AppKit
import SwiftUI

/// Developer-only launch flags (debug builds only):
///   --debug-window          show the popup UI with sample accounts in a regular window, so it
///                           can be captured with `screencapture -l <window number>` (printed
///                           to stderr as MENUMAIL_PREVIEW_WINDOW <n>)
///   --debug-window-empty    the same, with no accounts (the welcome screen)
///   --debug-settings <tab>  the Settings window with sample accounts ("accounts", "general",
///                           or "add" for the add-account sheet's content)
///   --debug-menubar <dir>   write menu bar icon PNGs (with and without a count) to <dir>
///   --debug-logo <dir>      write logo-1024.png and logo-120.png (Google's consent-screen size)
enum DebugTools {
    private static var retained: [AnyObject] = []
    private static let arguments = CommandLine.arguments

    static var isActive: Bool {
        arguments.contains("--debug-window") || arguments.contains("--debug-window-empty")
            || arguments.contains("--debug-settings") || arguments.contains("--debug-logo")
            || arguments.contains("--debug-menubar")
    }

    static func handleLaunchArguments() {
        guard isActive else { return }
        if let index = arguments.firstIndex(of: "--debug-menubar"), index + 1 < arguments.count {
            writeMenuBarSamples(to: URL(fileURLWithPath: arguments[index + 1]))
            exit(0)
        }
        if let index = arguments.firstIndex(of: "--debug-logo"), index + 1 < arguments.count {
            let directory = URL(fileURLWithPath: arguments[index + 1])
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for pixels in [1024, 120] {
                try? MenuMailIcon.logoPNG(pixels: pixels).write(to: directory.appending(path: "logo-\(pixels).png"))
            }
            exit(0)
        }
        Task {
            try? await Task.sleep(for: .seconds(1))
            showPreviewWindow(empty: arguments.contains("--debug-window-empty"))
        }
    }

    private static func writeMenuBarSamples(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, count) in [("menubar", nil), ("menubar-3", "3"), ("menubar-50", "50+")] as [(String, String?)] {
            let image = MenuMailIcon.menuBar(count: count)
            let scale = 8
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) * scale,
                                       pixelsHigh: Int(image.size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: directory.appending(path: "\(name).png"))
        }
        try? MenuMailIcon.png(MenuMailIcon.appIcon(size: NSSize(width: 512, height: 512)), pixels: 512)
            .write(to: directory.appending(path: "appicon.png"))
        try? MenuMailIcon.png(MenuMailIcon.appIcon(size: NSSize(width: 32, height: 32)), pixels: 32)
            .write(to: directory.appending(path: "appicon-32.png"))
    }

    private static func showPreviewWindow(empty: Bool) {
        let now = Date.now
        let accounts = empty ? [] : [
            Account(email: "rick@gmail.com", nickname: "Personal", clientID: "preview", lastSeen: now.addingTimeInterval(-3_000)),
            Account(email: "rick@example.com", nickname: "Work", clientID: "preview", lastSeen: now.addingTimeInterval(-600)),
        ]
        let services: [String: MailService] = empty ? [:] : [
            "rick@gmail.com": PreviewService(messages: PreviewService.personal(now)),
            "rick@example.com": PreviewService(messages: PreviewService.work(now)),
        ]
        let store = MailStore(preview: accounts, services: services)
        Task { await store.refreshAll() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MenuMail Preview"
        let settingsTab = arguments.firstIndex(of: "--debug-settings").map { arguments[$0 + 1] }
        switch settingsTab {
        case nil:
            window.contentView = NSHostingView(rootView: RootView().environment(store))
        case "add":
            window.contentView = NSHostingView(rootView: AddAccountView(style: .sheet {})
                .frame(width: 480, height: 640).environment(store))
        case let tab?:
            UserDefaults.standard.set(tab, forKey: "settingsTab")
            window.contentView = NSHostingView(rootView: SettingsView().environment(store))
        }
        window.setContentSize(window.contentView!.fittingSize)
        window.isReleasedWhenClosed = false
        window.center()
        window.orderFrontRegardless()
        retained.append(window)
        FileHandle.standardError.write(Data("MENUMAIL_PREVIEW_WINDOW \(window.windowNumber)\n".utf8))
    }
}

/// In-memory inbox with sample messages, for the preview window.
final class PreviewService: MailService {
    private let messages: [MailMessage]

    init(messages: [MailMessage]) {
        self.messages = messages
    }

    func fetchInbox(limit: Int) async throws -> InboxPage {
        InboxPage(messages: Array(messages.prefix(limit)), hasMore: messages.count > limit)
    }

    private static func message(_ id: String, _ name: String, _ subject: String, _ snippet: String,
                                minutesAgo: Double, unread: Bool, now: Date) -> MailMessage {
        MailMessage(id: id, threadID: id, senderName: name, senderAddress: "\(name.lowercased().filter(\.isLetter))@example.com",
                    subject: subject, snippet: snippet, date: now.addingTimeInterval(-minutesAgo * 60), isUnread: unread)
    }

    static func personal(_ now: Date) -> [MailMessage] {
        [
            message("p1", "Delta Air Lines", "Your trip to Denver is coming up", "Check in opens 24 hours before departure. Here's everything you need for your flight on Friday.", minutesAgo: 4, unread: true, now: now),
            message("p2", "Mom", "Sunday dinner?", "Are you two coming over this weekend? Dad wants to grill if the weather holds up.", minutesAgo: 22, unread: true, now: now),
            message("p3", "GitHub", "[richardpetithory/makeep] New star", "Someone starred your repository makeep.", minutesAgo: 47, unread: false, now: now),
            message("p4", "Chase", "Your statement is ready", "Your October statement for the account ending in 4321 is now available to view online.", minutesAgo: 180, unread: false, now: now),
            message("p5", "REI Co-op", "Members save 20% this week", "Gear up for fall with member-only savings on camping, hiking and more.", minutesAgo: 60 * 26, unread: false, now: now),
            message("p6", "Alex Kim", "Photos from the lake", "Finally got these off my camera — a few of them came out great. Let me know which ones you want printed.", minutesAgo: 60 * 70, unread: false, now: now),
        ]
    }

    static func work(_ now: Date) -> [MailMessage] {
        [
            message("w1", "Jordan Lee", "Re: Q4 roadmap review", "Thanks — I moved the review to Thursday at 2pm so Sam can join. Updated doc attached.", minutesAgo: 3, unread: true, now: now),
            message("w2", "Sentry", "New issue in api-server", "TypeError: Cannot read properties of undefined (reading 'id') in handlers/session.ts", minutesAgo: 35, unread: true, now: now),
            message("w3", "Priya Shah", "Lunch & learn slides", "Here are the slides from today's session on the new deploy pipeline.", minutesAgo: 140, unread: false, now: now),
            message("w4", "Google Calendar", "Invitation: 1:1 @ Tue Oct 14", "You have been invited to the following event.", minutesAgo: 60 * 30, unread: false, now: now),
        ]
    }
}
#endif
