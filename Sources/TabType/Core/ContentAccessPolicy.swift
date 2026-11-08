import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Shared authorization before reading text or pixels. A snapshot is also an
/// async capability: focus/settings changes revoke work already in flight.
@MainActor
enum ContentAccessPolicy {
    struct Snapshot: @unchecked Sendable {
        let generation: UInt64
        let pid: pid_t
        let bundleId: String
        let host: String?
        let element: AXUIElement
        let windowFrame: CGRect?
        let windowTitle: String?
    }

    private static var generation: UInt64 = 0
    static var engineAllowsContent: (() -> Bool)?
    private static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "com.microsoft.edgemac",
        "org.mozilla.firefox", "company.thebrowser.Browser", "company.thebrowser.dia",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static func invalidate() { generation &+= 1 }

    nonisolated static func canonicalHost(_ host: String) -> String {
        WebsiteRule.host(from: host) ?? host.lowercased()
    }

    /// Ambiguous or missing window identity must never select a different window.
    nonisolated static func windowIndex(pid: pid_t, frame: CGRect,
                                        windows: [(pid: pid_t?, frame: CGRect)]) -> Int? {
        let matches = windows.indices.filter { i in
            let w = windows[i]
            return w.pid == pid && abs(w.frame.minX - frame.minX) <= 2
                && abs(w.frame.minY - frame.minY) <= 2
                && abs(w.frame.width - frame.width) <= 2 && abs(w.frame.height - frame.height) <= 2
        }
        return matches.count == 1 ? matches.first : nil
    }

    static func allows(enabled: Bool, appEnabled: Bool, domainEnabled: Bool,
                       host: String?, disabledDomains: Set<String>,
                       isBrowser: Bool, secure: Bool, credential: Bool) -> Bool {
        guard enabled, appEnabled, domainEnabled, !secure, !credential else { return false }
        guard let host else { return !isBrowser || disabledDomains.isEmpty }
        guard WebsiteRule.host(from: host) != nil else { return false }
        // An unrecognized saved exclusion must not silently permit the browser.
        guard disabledDomains.allSatisfy({ WebsiteRule.host(from: $0) != nil }) else { return false }
        return !disabledDomains.contains { WebsiteRule.matches(host: host, rule: $0) }
    }

    static func current() -> Snapshot? {
        var authorized = false
        defer { if !authorized { invalidate() } }
        let settings = AppSettings.shared
        guard settings.isEnabled, engineAllowsContent?() != false,
              !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication, let bundleId = app.bundleIdentifier,
              AppPolicyStore.policy(forBundleId: bundleId).isEnabled,
              let element = AccessibilityBridge.focusedElement() else { return nil }
        // Authorization must not use the one-second URL cache: a browser can
        // reuse the same accessibility element while navigating to another site.
        let host = AccessibilityBridge.pageURL(of: element)?.host.map(canonicalHost)
        let policy = AppPolicyStore.policy(forBundleId: bundleId, host: host)
        let deniedOverrides = AppPolicyStore.userOverrides.compactMap { key, value -> String? in
            guard key.hasPrefix("domain:"), value.enabled == false else { return nil }
            return String(key.dropFirst("domain:".count))
        }
        // With no resolved URL, neither list of excluded sites can be enforced.
        let invalidOverrides = deniedOverrides.filter { WebsiteRule.host(from: $0) == nil }
        let exclusions = settings.disabledDomains.union(host == nil ? deniedOverrides : invalidOverrides)
        guard allows(enabled: settings.isEnabled, appEnabled: true, domainEnabled: policy.isEnabled,
                     host: host, disabledDomains: exclusions,
                     isBrowser: browsers.contains(bundleId),
                     secure: AccessibilityBridge.isSecureField(element),
                     credential: AccessibilityBridge.isCredentialField(element)) else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == app.processIdentifier else { return nil }
        authorized = true
        return Snapshot(generation: generation, pid: pid, bundleId: bundleId, host: host,
                        element: element, windowFrame: ContextReader.windowRect(of: element),
                        windowTitle: ScreenContextProvider.stableTitle(AccessibilityBridge.focusedWindowTitle()))
    }

    static func isCurrent(_ snapshot: Snapshot) -> Bool {
        guard snapshot.generation == generation, let now = current() else { return false }
        return snapshot.pid == now.pid && snapshot.host == now.host
            && CFEqual(snapshot.element, now.element) && snapshot.windowFrame == now.windowFrame
            && snapshot.windowTitle == now.windowTitle
    }
}
