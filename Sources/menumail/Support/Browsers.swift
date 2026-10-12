import AppKit

/// A browser profile to open an account's links in. Chromium-based browsers (Brave, Chrome,
/// Edge, Vivaldi, …) take `--profile-directory`, so links for a work account can open in the work
/// profile. Arc and Opera don't use Chromium profiles that way, so they aren't listed.
nonisolated struct BrowserProfile: Codable, Hashable, Identifiable, Sendable {
    var bundleID: String
    /// Directory name under the browser's user data folder, e.g. "Default" or "Profile 3".
    var directory: String
    /// "Brave Origin – Work", saved so the setting still reads well if the profile goes away.
    var label: String

    var id: String { "\(bundleID)/\(directory)" }
}

enum Browsers {
    nonisolated private struct Chromium {
        var bundleID: String
        /// User data folder relative to ~/Library/Application Support.
        var dataPath: String
    }

    nonisolated private static let chromiumBrowsers = [
        Chromium(bundleID: "com.brave.Browser", dataPath: "BraveSoftware/Brave-Browser"),
        Chromium(bundleID: "com.brave.Browser.origin", dataPath: "BraveSoftware/Brave-Origin"),
        Chromium(bundleID: "com.brave.Browser.beta", dataPath: "BraveSoftware/Brave-Browser-Beta"),
        Chromium(bundleID: "com.brave.Browser.nightly", dataPath: "BraveSoftware/Brave-Browser-Nightly"),
        Chromium(bundleID: "com.google.Chrome", dataPath: "Google/Chrome"),
        Chromium(bundleID: "com.google.Chrome.beta", dataPath: "Google/Chrome Beta"),
        Chromium(bundleID: "com.google.Chrome.dev", dataPath: "Google/Chrome Dev"),
        Chromium(bundleID: "com.google.Chrome.canary", dataPath: "Google/Chrome Canary"),
        Chromium(bundleID: "com.microsoft.edgemac", dataPath: "Microsoft Edge"),
        Chromium(bundleID: "com.microsoft.edgemac.Beta", dataPath: "Microsoft Edge Beta"),
        Chromium(bundleID: "com.microsoft.edgemac.Dev", dataPath: "Microsoft Edge Dev"),
        Chromium(bundleID: "org.chromium.Chromium", dataPath: "Chromium"),
        Chromium(bundleID: "com.vivaldi.Vivaldi", dataPath: "Vivaldi"),
    ]

    /// Profiles of the installed Chromium browsers, read from each browser's "Local State".
    static func installedProfiles() -> [BrowserProfile] {
        let support = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return chromiumBrowsers.flatMap { browser -> [BrowserProfile] in
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID),
                  let data = try? Data(contentsOf: support.appending(path: browser.dataPath).appending(path: "Local State"))
            else { return [] }
            let appName = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
            return profiles(fromLocalState: data, bundleID: browser.bundleID, appName: appName)
        }
    }

    /// Parses Chromium's `profile.info_cache`. Split out for tests.
    nonisolated static func profiles(fromLocalState data: Data, bundleID: String, appName: String) -> [BrowserProfile] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = (root["profile"] as? [String: Any])?["info_cache"] as? [String: [String: Any]]
        else { return [] }
        return cache.map { directory, info in
            let name = info["name"] as? String ?? directory
            return BrowserProfile(bundleID: bundleID, directory: directory, label: "\(appName) – \(name)")
        }
        .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    /// Opens `url` in `profile`, or in the default browser when there's no profile (or its
    /// browser was uninstalled).
    static func open(_ url: URL, in profile: BrowserProfile?) {
        guard let profile, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.bundleID) else {
            NSWorkspace.shared.open(url)
            return
        }
        // A new instance passes the URL and profile to the running browser and exits; without
        // it, macOS would just activate the running browser and drop the arguments.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--profile-directory=\(profile.directory)", url.absoluteString]
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if error != nil { DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
        }
    }
}
