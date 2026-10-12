import ServiceManagement
import SwiftUI

/// "Open at login", backed by the system's Login Items (System Settings → General → Login
/// Items), so it reads the live status instead of keeping a copy that could drift.
struct LaunchAtLoginToggle: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at login", isOn: Binding(get: { status == .enabled }, set: setEnabled))
            if status == .requiresApproval {
                HStack(spacing: 4) {
                    Text("Allow it in System Settings → General → Login Items.")
                    Button("Open…") { SMAppService.openSystemSettingsLoginItems() }
                        .buttonStyle(.link)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        // The user can change it in System Settings while the app runs.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = SMAppService.mainApp.status
        }
        .onAppear { status = SMAppService.mainApp.status }
    }

    private func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = "Couldn't change the login item: \(error.localizedDescription)"
        }
        status = SMAppService.mainApp.status
    }
}

enum LoginItem {
    private static let defaultsKey = "didEnableLoginItemByDefault"

    /// Turns on "Open at login" the first time the app runs from an Applications folder; after
    /// that it's the user's choice. Waiting for an Applications folder avoids registering a copy
    /// that's about to be moved out of Downloads.
    static func enableOnFirstLaunch() {
        let path = Bundle.main.bundleURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard Bundle.main.bundleIdentifier != nil,
              path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/"),
              !UserDefaults.standard.bool(forKey: defaultsKey) else { return }
        UserDefaults.standard.set(true, forKey: defaultsKey)
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
    }
}
