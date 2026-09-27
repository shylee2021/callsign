import AppKit
import Testing
@testable import Callsign

@MainActor
struct AppIdentityCacheTests {
    private func window(pid: pid_t, owner: String) -> WindowInfo {
        WindowInfo(id: 1, pid: pid, owner: owner, title: "", frame: .zero, layer: 0, alpha: 1)
    }

    @Test func processesWithoutAnAppFallBackToTheWindowOwner() {
        let cache = AppIdentityCache()
        let identity = cache.identity(for: window(pid: .max, owner: "Helper"))
        #expect(identity.name == "Helper")
        #expect(identity.icon.size.width > 0 && identity.icon.size.height > 0)
        // Identities are cached per PID until the process quits.
        #expect(cache.identity(for: window(pid: .max, owner: "Other")).name == "Helper")
    }

    @Test func runningAppsUseTheirOwnNameAndLeaveTheCacheWhenTheyQuit() throws {
        let cache = AppIdentityCache()
        let app = NSRunningApplication.current
        let pid = app.processIdentifier
        let name = try #require(app.localizedName)
        #expect(cache.identity(for: window(pid: pid, owner: "Ignored owner")).name == name)
        #expect(cache.identities[pid] != nil)

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didTerminateApplicationNotification, object: NSWorkspace.shared,
            userInfo: [NSWorkspace.applicationUserInfoKey: app])
        #expect(cache.identities[pid] == nil)

        _ = cache.identity(for: window(pid: pid, owner: "Ignored owner"))
        cache.evict(pid: pid)
        #expect(cache.identities.isEmpty)
    }
}
