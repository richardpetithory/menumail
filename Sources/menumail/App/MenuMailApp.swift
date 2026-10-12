import AppKit
import SwiftUI

@main
struct MenuMailApp: App {
    @State private var store: MailStore
    @State private var showsMenuBarItem = !MenuMailApp.isDebugToolRun

    init() {
        Self.renderIconsetIfRequested()
        Self.exitIfAlreadyRunning()  // Before creating the store, which reads the Keychain.
        _store = State(initialValue: MailStore())
        // Menu bar only: no Dock icon (also set via LSUIElement when bundled).
        NSApplication.shared.setActivationPolicy(.accessory)
        if !Self.isDebugToolRun { LoginItem.enableOnFirstLaunch() }

        #if DEBUG
        DebugTools.handleLaunchArguments()
        #endif
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $showsMenuBarItem) {
            RootView()
                .environment(store)
        } label: {
            let count = store.menuBarCount
            Image(nsImage: MenuMailIcon.menuBar(count: count.count > 0 ? count.label : nil))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(store)
        }
    }

    /// `menumail --render-iconset <dir>`: used by scripts/bundle.sh to build AppIcon.icns from
    /// the same drawing code as the menu bar icon.
    private static func renderIconsetIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--render-iconset"), index + 1 < arguments.count else { return }
        do {
            try MenuMailIcon.writeIconset(to: URL(fileURLWithPath: arguments[index + 1]))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Failed to render iconset: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Another copy of the app (e.g. build/ and /Applications) would add a second menu bar icon.
    private static func exitIfAlreadyRunning() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }  // Unbundled debug runs.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty { exit(0) }
    }

    /// Debug tool runs (`--debug-window`) open their own window and stay out of the menu bar,
    /// so they don't look like a second copy of the app.
    private static var isDebugToolRun: Bool {
        #if DEBUG
        DebugTools.isActive
        #else
        false
        #endif
    }
}
