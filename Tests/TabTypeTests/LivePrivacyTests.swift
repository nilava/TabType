import AppKit
import Carbon.HIToolbox
import XCTest
@testable import TabType

/// Opt-in integration checks. Focus the synthetic local browser fixture via the
/// native UI first. No real document text or screenshots are retained.
@MainActor
final class LivePrivacyTests: XCTestCase {
    func testFocusedBrowserPrivacyBoundaries() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["TABTYPE_LIVE_PRIVACY"] else { throw XCTSkip("opt-in native browser fixture") }
        XCTAssertNotEqual(Bundle.main.bundleIdentifier, "app.tabtype.TabType", "use an isolated test preferences domain")
        XCTAssertTrue(AXIsProcessTrusted(), "test host needs existing Accessibility permission")
        XCTAssertTrue(CGPreflightScreenCaptureAccess(), "test host needs existing Screen Recording permission")
        let settings = AppSettings.shared
        let previous = (settings.isEnabled, settings.useScreenContext, settings.useScreenshotAppearance, settings.disabledDomains)
        let overrides = AppPolicyStore.userOverrides
        let engineGate = ContentAccessPolicy.engineAllowsContent
        defer {
            settings.isEnabled = previous.0; settings.useScreenContext = previous.1
            settings.useScreenshotAppearance = previous.2; settings.disabledDomains = previous.3
            AppPolicyStore.userOverrides = overrides; ContentAccessPolicy.engineAllowsContent = engineGate
            ContentAccessPolicy.invalidate()
        }
        settings.isEnabled = true; settings.useScreenContext = true
        settings.useScreenshotAppearance = true; settings.disabledDomains = []
        AppPolicyStore.userOverrides = [:]
        ContentAccessPolicy.engineAllowsContent = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Safari"
                && ["localhost", "127.0.0.1"].contains(AccessibilityBridge.focusedElement().flatMap { AccessibilityBridge.pageURL(of: $0) }?.host ?? "")
        }
        ContentAccessPolicy.invalidate()
        if let start = env["TABTYPE_LIVE_START"] {
            let deadline = Date().addingTimeInterval(60)
            while !FileManager.default.fileExists(atPath: start), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: start))
        }

        if mode == "credential" || mode == "password" {
            let field = try XCTUnwrap(AccessibilityBridge.focusedElement())
            XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, "com.apple.Safari")
            XCTAssertTrue(mode == "password" ? AccessibilityBridge.isSecureField(field) : AccessibilityBridge.isCredentialField(field))
            XCTAssertNil(ContentAccessPolicy.current())
            let denied = await ScreenContextProvider.captureFocusedWindow(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                fieldText: "", cropMode: .caretCropped, caretRect: nil, windowFrame: nil)
            XCTAssertNil(denied)
            return
        }
        let focusDeadline = Date().addingTimeInterval(45)
        while ContentAccessPolicy.current() == nil, Date() < focusDeadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        if ContentAccessPolicy.current() == nil {
            let f = AccessibilityBridge.focusedElement()
            print("LIVE FOCUS front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none") element=\(f != nil) fixture=\(f.flatMap { AccessibilityBridge.pageURL(of: $0) }?.host == "localhost") secure=\(IsSecureEventInputEnabled()) credential=\(f.map(AccessibilityBridge.isCredentialField) ?? false)")
        }
        let origin = try XCTUnwrap(ContentAccessPolicy.current())
        XCTAssertEqual(origin.host, "localhost", "focus the synthetic localhost fixture")
        let window = try XCTUnwrap(origin.windowFrame)
        if mode == "model-cache" {
            let models = LlamaModelManager.shared
            let id = try XCTUnwrap(models.recommendedID)
            XCTAssertTrue(models.isInstalled(id), "use the already-installed recommended model; never download in this test")
            guard models.isInstalled(id) else { return }
            models.load(id)
            let deadline = Date().addingTimeInterval(45)
            while !models.isLoaded, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertTrue(models.isLoaded)
            let learning = settings.collectTypingHistory
            settings.collectTypingHistory = false
            defer { settings.collectTypingHistory = learning }
            let engine = LlamaEngine(models: models)
            _ = await engine.complete(CompletionRequest(beforeCursor: "The capital of France is", afterCursor: "", screenContext: "", maxWords: 2))
            _ = try XCTUnwrap(engine.lastResult, "a legitimate completion must be retained in its authorized field")
            engine.clearRecent()
            XCTAssertNil(engine.lastResult, "privacy revocation must forget alternatives as well as exact-prompt cache entries")
            await models.inference.unload()
            return
        }
        if mode == "race" { settings.disabledDomains = ["127.0.0.1"] }
        if mode == "race" || mode == "inline-race" {
            let gate = URL(fileURLWithPath: try XCTUnwrap(env["TABTYPE_LIVE_GATE"]))
            let controller = InlineCommandController(settings: settings)
            if mode == "inline-race" {
                for c in "/2+2" { _ = controller.handleEdit(chars: String(c), isDeletion: false, caretRect: { nil }) }
                XCTAssertTrue(controller.isActive)
            }
            try Data("ready".utf8).write(to: gate.appendingPathExtension("ready"))
            print("LIVE PRIVACY READY: switch the synthetic fixture focus, then release the gate")
            let deadline = Date().addingTimeInterval(60)
            while !FileManager.default.fileExists(atPath: gate.path), Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: gate.path), "gate timed out")
            XCTAssertFalse(ContentAccessPolicy.isCurrent(origin))
            if mode == "inline-race" { XCTAssertNil(controller.accept()) }
            let stale = await ScreenContextProvider.captureFocusedWindow(pid: origin.pid, fieldText: "",
                cropMode: .caretCropped, caretRect: nil, windowFrame: window, origin: origin)
            XCTAssertNil(stale)
            return
        }
        if mode == "inline" || mode == "inline-selection" {
            let controller = InlineCommandController(settings: settings)
            for c in "/2+2" { _ = controller.handleEdit(chars: String(c), isDeletion: false, caretRect: { nil }) }
            if mode == "inline-selection" {
                let field = try XCTUnwrap(AccessibilityBridge.focusedElement())
                XCTAssertEqual(AccessibilityBridge.selection(of: field)?.selected, "TRAILING")
                XCTAssertFalse(AccessibilityBridge.hasCollapsedCaret(of: field))
                XCTAssertNil(controller.accept())
                return
            }
            let result = try XCTUnwrap(controller.accept())
            XCTAssertEqual(result.deleteCount, 4)
            XCTAssertEqual(result.insert, "4")
            return
        }
        if mode == "positive" {
        let captured = await ScreenContextProvider.captureFocusedWindow(pid: origin.pid,
            fieldText: "", cropMode: .caretCropped, caretRect: nil, windowFrame: window, origin: origin)
        let shot = try XCTUnwrap(captured)
        XCTAssertTrue(shot.2.uppercased().contains("LILAC RIVER"), "OCR must contain the authorized fixture canary")
        XCTAssertFalse(shot.2.contains("DECOY WINDOW CANARY"))
            return
        }
        if mode == "appearance" {
            let appearance = await GhostAppearanceProbe.captureScaled(rect: window.insetBy(dx: 20, dy: 20))
            XCTAssertNotNil(appearance, "authorized focused-window sampling must still work")
            return
        }
        let outside = await GhostAppearanceProbe.captureScaled(rect: CGRect(x: window.maxX + 10, y: window.minY, width: 20, height: 20))
        XCTAssertNil(outside)
        settings.useScreenshotAppearance = false
        let appearanceOff = await GhostAppearanceProbe.captureScaled(rect: window.insetBy(dx: 20, dy: 20))
        XCTAssertNil(appearanceOff)
        settings.useScreenContext = false
        let contextOff = await ScreenContextProvider.captureFocusedWindow(pid: origin.pid, fieldText: "",
            cropMode: .caretCropped, caretRect: nil, windowFrame: window)
        XCTAssertNil(contextOff)
        settings.useScreenContext = true
        settings.disabledDomains = ["http://localhost:49657/private"]
        XCTAssertNil(ContentAccessPolicy.current())
        let excluded = await ScreenContextProvider.captureFocusedWindow(pid: origin.pid, fieldText: "",
            cropMode: .caretCropped, caretRect: nil, windowFrame: window, origin: origin)
        XCTAssertNil(excluded)
        settings.disabledDomains = []
        settings.isEnabled = false
        XCTAssertNil(ContentAccessPolicy.current())
        settings.isEnabled = true
        var denial = AppOverride(); denial.enabled = false
        AppPolicyStore.userOverrides = [origin.bundleId: denial]
        XCTAssertNil(ContentAccessPolicy.current())
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.bundleIdentifier, "com.apple.Safari", "keep the synthetic fixture focused for this check")
    }

}
