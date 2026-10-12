import AppKit

/// Identifies the current desktop (Mission Control Space) so each one can remember its own
/// selected account.
///
/// macOS has no public API for this, so it uses the private CoreGraphics/SkyLight calls that
/// window managers use, looked up at runtime: if they disappear, every desktop simply shares
/// one selection.
enum Desktops {
    /// A stable identifier for a desktop. Space UUIDs survive restarts and reordering; the
    /// display identifier keeps desktops on different monitors apart.
    nonisolated struct Desktop: Equatable, Sendable {
        var key: String
        /// 1-based position among the display's desktops, as Mission Control numbers them.
        var number: Int?
        var isFullScreen: Bool

        var label: String {
            if isFullScreen { return "Full-screen space" }
            return number.map { "Desktop \($0)" } ?? "This desktop"
        }
    }

    static func current() -> Desktop? {
        guard let api = API.shared else { return nil }
        let connection = api.mainConnectionID()
        let activeID = api.activeSpace(connection)
        guard let displays = api.copyManagedDisplaySpaces(connection)?.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }
        return resolve(activeSpaceID: activeID, displays: displays)
    }

    /// Finds the active space in `CGSCopyManagedDisplaySpaces` output. Split out for tests.
    nonisolated static func resolve(activeSpaceID: UInt64, displays: [[String: Any]]) -> Desktop? {
        for display in displays {
            let displayID = display["Display Identifier"] as? String ?? "Main"
            let spaces = display["Spaces"] as? [[String: Any]] ?? []
            var desktopNumber = 0
            for space in spaces {
                let isFullScreen = (space["type"] as? Int ?? 0) != 0
                if !isFullScreen { desktopNumber += 1 }
                guard spaceID(space) == activeSpaceID else { continue }
                // The first desktop's UUID is empty, so fall back to the numeric ID.
                let uuid = space["uuid"] as? String ?? ""
                let spaceKey = uuid.isEmpty ? "id\(activeSpaceID)" : uuid
                return Desktop(key: "\(displayID)/\(spaceKey)",
                               number: isFullScreen ? nil : desktopNumber,
                               isFullScreen: isFullScreen)
            }
        }
        return nil
    }

    nonisolated private static func spaceID(_ space: [String: Any]) -> UInt64? {
        if let id = space["id64"] as? UInt64 { return id }
        if let id = space["id64"] as? Int { return UInt64(id) }
        if let id = space["ManagedSpaceID"] as? Int { return UInt64(id) }
        return nil
    }

    private struct API {
        typealias MainConnectionID = @convention(c) () -> Int32
        typealias GetActiveSpace = @convention(c) (Int32) -> UInt64
        typealias CopyManagedDisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

        let mainConnectionID: MainConnectionID
        let activeSpace: GetActiveSpace
        let copyManagedDisplaySpaces: CopyManagedDisplaySpaces

        static let shared: API? = {
            let handle = dlopen(nil, RTLD_NOW)
            guard let main = dlsym(handle, "CGSMainConnectionID"),
                  let active = dlsym(handle, "CGSGetActiveSpace"),
                  let copy = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return nil }
            return API(mainConnectionID: unsafeBitCast(main, to: MainConnectionID.self),
                       activeSpace: unsafeBitCast(active, to: GetActiveSpace.self),
                       copyManagedDisplaySpaces: unsafeBitCast(copy, to: CopyManagedDisplaySpaces.self))
        }()
    }
}
