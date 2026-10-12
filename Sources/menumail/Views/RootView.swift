import SwiftUI

struct RootView: View {
    @Environment(MailStore.self) private var store
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            if store.accounts.isEmpty {
                AddAccountView(style: .welcome)
                    .background(Color(nsColor: .windowBackgroundColor))  // Readable text, as in the list.
            } else {
                inbox
            }
        }
        .frame(width: 400, height: 560)
        .background(WindowObserver(onShow: store.popupDidOpen, onHide: store.popupDidClose))
    }

    private var inbox: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                AccountTabs()
                Button(action: showSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(",")
                    .help("Settings")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            if let account = store.selectedAccount {
                MessageListView(account: account)
            }
        }
    }

    /// Menu bar apps aren't active, so bring the Settings window to the front explicitly.
    private func showSettings() {
        openSettings()
        NSApp.activate()
    }
}

/// One tab per account, each with its own new-message badge.
struct AccountTabs: View {
    @Environment(MailStore.self) private var store

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(store.accounts) { account in
                    tab(account)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tab(_ account: Account) -> some View {
        let isSelected = account.email == store.selectedAccount?.email
        let count = store.newCount(for: account)
        return Button { store.select(account.email) } label: {
            HStack(spacing: 5) {
                Text(account.nickname)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .lineLimit(1)
                if store.inboxes[account.email]?.needsReconnect == true {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                } else if count.count > 0 {
                    Text(count.label)
                        .font(.caption2.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.red, in: .capsule)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(account.email)
    }
}

/// Error banner shared by every screen.
struct ErrorBanner: View {
    let message: String
    var action: (label: String, perform: () -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.caption).textSelection(.enabled).lineLimit(5)
                if let action { Button(action.label, action: action.perform).controlSize(.small) }
            }
            Spacer()
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(8)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 6))
    }
}

/// Reports when the hosting window (the menu bar popup) is shown and hidden.
struct WindowObserver: NSViewRepresentable {
    let onShow: () -> Void
    let onHide: () -> Void

    func makeNSView(context: Context) -> ObservingView {
        ObservingView()
    }

    func updateNSView(_ view: ObservingView, context: Context) {
        view.onShow = onShow
        view.onHide = onHide
    }

    final class ObservingView: NSView {
        var onShow: () -> Void = {}
        var onHide: () -> Void = {}
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibilityChanged() }
            })
            observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onShow() }
            })
            visibilityChanged()
        }

        private func visibilityChanged() {
            guard let window else { return }
            if window.isVisible && window.occlusionState.contains(.visible) { onShow() } else { onHide() }
        }
    }
}
