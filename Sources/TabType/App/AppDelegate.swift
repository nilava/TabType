import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let settings = AppSettings.shared
    private let provider = ModelProvider.shared
    private let llamaModels = LlamaModelManager.shared
    private lazy var engine = Engine(settings: settings, provider: provider)

    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var trustTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        startSecureInputWatch()

        // Rebuild the menu whenever model state or enablement changes.
        provider.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        settings.$isEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.rebuildMenu()
                // Visibly dim the menu-bar glyph while disabled — a silently-off
                // engine has repeatedly read as "the app is broken".
                self?.statusItem.button?.appearsDisabled = !enabled
            }
            .store(in: &cancellables)
        settings.$showMenuBarIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] show in self?.statusItem.isVisible = show }
            .store(in: &cancellables)

        // Accessory button → open Settings.
        NotificationCenter.default.addObserver(
            forName: .tabTypeOpenSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }

        // Apply the "disable macOS predictive text" preference.
        applyMacOSPredictiveText()
        settings.$disableMacOSPredictiveText
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyMacOSPredictiveText() }
            .store(in: &cancellables)

        Log.shared.info("TabType launched. engine=\(settings.engineChoice.rawValue) v2model=\(llamaModels.selectedID) v1model=\(settings.modelId) ax=\(AccessibilityBridge.isTrusted()) screen=\(ScreenContextProvider.shared.hasPermission()) emoji=\(EmojiMatcher.shared.all.count)")

        // Persist the model id only once it actually finishes loading, so a failed
        // switch to a different model never leaves settings pointing at a model that
        // isn't actually loaded (the previous working model stays active meanwhile).
        provider.onReady = { [weak self] modelId in
            self?.settings.modelId = modelId
            // Warm the KV cache with the static prompt prefix so the FIRST real
            // suggestion skips its system-prompt prefill (1-4s on big models).
            self?.engine.warmUpModel()
        }

        // Start loading the selected engine's model + spell dictionary right away.
        startSelectedEngine()
        settings.$engineChoice
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // @Published fires before the stored value changes — read it next tick.
                DispatchQueue.main.async {
                    self?.startSelectedEngine()
                    self?.rebuildMenu()
                }
            }
            .store(in: &cancellables)
        llamaModels.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.rebuildMenu()
                // Cache the static prompt head as soon as a v2 model is ready.
                if case .ready = status { self?.engine.warmUpModel() }
            }
            .store(in: &cancellables)
        if settings.autocorrectEnabled {
            SpellChecker.shared.loadIfNeeded(language: settings.autocorrectLanguage)
        }

        // Ask for Screen Recording up front if screen memory is on (non-blocking).
        if settings.useScreenContext && !ScreenContextProvider.shared.hasPermission() {
            ScreenContextProvider.shared.requestPermission()
        }

        // Confirm the capture+OCR pipeline works on this machine (logs the result).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            ScreenContextProvider.shared.selfTest()
        }

        // Gate on Accessibility permission.
        if AccessibilityBridge.isTrusted() {
            _ = engine.start()
        } else {
            showOnboarding()
            waitForTrustThenStart()
        }
    }

    /// Load only what the chosen engine needs: the v2 model, or v1's MLX model.
    private func startSelectedEngine() {
        switch settings.engineChoice {
        case .local:
            if provider.readyModelId != settings.modelId { provider.load(modelId: settings.modelId) }
        case .llama, .auto, .appleIntelligence:
            if !llamaModels.isLoaded { llamaModels.start() }
        }
    }

    /// The v2 model must be freed before exit: ggml aborts if Metal resources are
    /// still alive when the process tears down.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await llamaModels.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Status bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "TabType")
            button.image?.isTemplate = true
        }
        statusItem.isVisible = settings.showMenuBarIcon
        statusMenu.delegate = self
        // Honor the isEnabled we set in item(...) — with auto-enable on, AppKit
        // grays out action-less items like the "Pause For…" submenu parent.
        statusMenu.autoenablesItems = false
        statusItem.menu = statusMenu
        rebuildMenu()
    }

    /// Rebuild right before the menu is shown, so a time-limited pause that expired
    /// while the menu was closed is reflected immediately.
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = statusMenu
        menu.removeAllItems()

        menu.addItem(item(statusLine(), icon: engineIconName(), enabled: false))
        if secureInputActive {
            menu.addItem(item("Secure Input is on — suggestions paused",
                              icon: "lock.fill", enabled: false))
        }
        if let pause = engine.frontmostAppPause() {
            let mins = max(1, Int(pause.until.timeIntervalSinceNow / 60))
            menu.addItem(item("Paused in this app (\(mins)m left) — Resume",
                              icon: "pause.circle", action: #selector(resumeAppPause)))
        }
        menu.addItem(.separator())

        if engine.isPaused {
            let resumeTitle = settings.isEnabled ? "Resume TabType" : "Enable TabType"
            menu.addItem(item(resumeTitle, icon: "play.circle", action: #selector(resumeNow)))
        } else {
            let toggle = item(settings.isEnabled ? "Pause TabType" : "Enable TabType",
                              icon: settings.isEnabled ? "pause.circle" : "power",
                              action: #selector(toggleEnabled))
            menu.addItem(toggle)

            let pauseMenu = NSMenu()
            pauseMenu.autoenablesItems = false
            pauseMenu.addItem(item("For 15 Minutes", icon: "timer", action: #selector(pause15)))
            pauseMenu.addItem(item("For 1 Hour", icon: "timer", action: #selector(pause60)))
            pauseMenu.addItem(item("Until I Turn It Back On", icon: "moon.zzz", action: #selector(pauseIndefinitely)))
            let pauseItem = item("Pause For…", icon: "pause.circle")
            pauseItem.submenu = pauseMenu
            menu.addItem(pauseItem)
        }

        menu.addItem(.separator())

        menu.addItem(item("Settings…", icon: "gearshape", action: #selector(openSettings), key: ","))
        menu.addItem(item("Statistics", icon: "chart.bar", action: #selector(openStatistics)))

        if !AccessibilityBridge.isTrusted() {
            menu.addItem(item("Grant Accessibility Permission…", icon: "exclamationmark.triangle",
                              action: #selector(showOnboarding)))
        }

        menu.addItem(.separator())
        menu.addItem(item("Open Log", icon: "doc.text.magnifyingglass", action: #selector(openLog)))
        menu.addItem(item("About TabType", icon: "info.circle", action: #selector(openAbout)))

        menu.addItem(.separator())
        menu.addItem(item("Quit TabType", icon: "power", action: #selector(quit), key: "q"))
    }

    /// Build an `NSMenuItem` with an SF Symbol icon.
    private func item(_ title: String, icon: String, action: Selector? = nil,
                      key: String = "", enabled: Bool = true) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        if action != nil { menuItem.target = self }
        // Submenu parents legitimately have no action — don't disable them.
        menuItem.isEnabled = enabled
        return menuItem
    }

    private func engineIconName() -> String {
        if settings.engineChoice != .local {
            switch llamaModels.status {
            case .ready: return "cpu"
            case .downloading: return "arrow.down.circle"
            case .loading: return "gearshape.2"
            case .failed: return "exclamationmark.triangle"
            case .noModel: return "circle.dashed"
            }
        }
        switch provider.state {
        case .ready: return settings.engineChoice == .local ? "cpu" : "sparkles"
        case .downloading: return "arrow.down.circle"
        case .finalizing: return "gearshape.2"
        case .failed: return "exclamationmark.triangle"
        case .idle: return "circle.dashed"
        }
    }

    /// Another app holding macOS Secure Input silently blinds the keystroke tap —
    /// surface it instead of looking broken (Cotypist ships the same warning).
    private var secureInputActive = false
    private var secureInputTimer: Timer?

    func startSecureInputWatch() {
        secureInputTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let active = IsSecureEventInputEnabled()
                guard active != self.secureInputActive else { return }
                self.secureInputActive = active
                self.statusItem.button?.toolTip = active
                    ? "Another app has Secure Input on — TabType can't see keystrokes until it releases it."
                    : nil
                self.rebuildMenu()
                if active {
                    Log.shared.info("Secure Input active (another app) — keystroke tap is blind")
                }
            }
        }
    }

    private func statusLine() -> String {
        if settings.engineChoice != .local {
            let name = { (id: String) in self.llamaModels.entry(id: id)?.name ?? id }
            switch llamaModels.status {
            case .noModel: return "No model yet — choose one in Settings ▸ Engine"
            case .downloading(let id, let f): return "Downloading \(name(id))… \(Int(f * 100))%"
            case .loading(let id): return "Loading \(name(id))…"
            case .ready(let id): return "Model: \(name(id))"
            case .failed(_, let message): return message
            }
        }
        switch provider.state {
        case .idle: return "Starting…"
        case .downloading(let modelId, let p):
            return "Downloading \(shortModelName(modelId))… \(Int(p * 100))%"
        case .finalizing(let modelId):
            return "Loading \(shortModelName(modelId)) into memory…"
        case .ready(let id): return "Model: \(shortModelName(id))"
        case .failed(let modelId, let msg): return "Model error (\(shortModelName(modelId))): \(msg)"
        }
    }

    private func shortModelName(_ id: String) -> String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    // MARK: - Actions

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
        rebuildMenu()
    }

    @objc private func pause15() { engine.pause(minutes: 15); rebuildMenu() }
    @objc private func pause60() { engine.pause(minutes: 60); rebuildMenu() }
    @objc private func pauseIndefinitely() { engine.pause(minutes: nil); rebuildMenu() }
    @objc private func resumeNow() { engine.resume(); rebuildMenu() }
    @objc private func resumeAppPause() { engine.resumeFrontmostAppPause(); rebuildMenu() }

    @objc private func openStatistics() {
        SettingsNavigator.shared.pendingSection = .statistics
        openSettings()
    }

    @objc private func openAbout() {
        SettingsNavigator.shared.pendingSection = .about
        openSettings()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView().environmentObject(settings).environmentObject(provider)
                .environmentObject(llamaModels)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "TabType Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: SettingsNavigator.shared.desiredContentWidth, height: 620))
            window.minSize = NSSize(width: 760, height: 460)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
            // SwiftUI can't drive an AppKit-hosted window's size, so the settings
            // content publishes the width each section wants and we animate to it.
            SettingsNavigator.shared.$desiredContentWidth
                .removeDuplicates()
                .sink { [weak self] width in self?.resizeSettings(toContentWidth: width) }
                .store(in: &cancellables)
        }
        // Give TabType a Dock icon + Cmd-Tab entry while Settings is open — as a
        // menu-bar-only (.accessory) app, clicking another app would otherwise send
        // this window behind it with no way back except reopening from the menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        // Honor the current section's width now that the window is visible (the
        // sink's initial value arrived while it was still hidden).
        resizeSettings(toContentWidth: SettingsNavigator.shared.desiredContentWidth)
    }

    /// Animate the settings window to a section's desired content width, keeping it
    /// on screen. Height is preserved (respects any manual vertical resize).
    private func resizeSettings(toContentWidth width: CGFloat) {
        guard let window = settingsWindow, window.isVisible else {
            Log.shared.debug("resizeSettings(\(width)) skipped — window not visible")
            return
        }
        let currentContent = window.contentRect(forFrameRect: window.frame).size
        Log.shared.debug("resizeSettings: \(currentContent.width) -> \(width)")
        guard abs(currentContent.width - width) > 1 else { return }
        var frame = window.frame
        let target = window.frameRect(forContentRect:
            NSRect(x: 0, y: 0, width: width, height: currentContent.height)).size
        // Grow/shrink around the current center, then nudge back on screen.
        frame.origin.x -= (target.width - frame.width) / 2
        frame.size.width = target.width
        if let vis = window.screen?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, vis.minX), vis.maxX - frame.width)
        }
        // `setFrame(_:display:animate:)` is the reliable AppKit API — `animator()`
        // outside an explicit animation context can silently no-op.
        window.setFrame(frame, display: true, animate: true)
    }

    @objc private func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(
                onGrant: { AccessibilityBridge.requestTrust() },
                onGrantScreen: { _ = ScreenContextProvider.shared.requestPermission() },
                onDone: { [weak self] in self?.onboardingWindow?.close() }
            )
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Welcome to TabType"
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 480, height: 420))
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Log.fileURL)
    }

    /// Best-effort: write the global default that controls macOS inline predictive
    /// text so it doesn't conflict with TabType. Fully applies after log out/in.
    private func applyMacOSPredictiveText() {
        let key = "NSAutomaticInlinePredictionEnabled" as CFString
        let value = settings.disableMacOSPredictiveText ? kCFBooleanFalse : nil
        CFPreferencesSetValue(key, value, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication,
                                 kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === settingsWindow else { return }
        // Revert to menu-bar-only now that Settings is closed.
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Permission polling

    private func waitForTrustThenStart() {
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if AccessibilityBridge.isTrusted() {
                    self.trustTimer?.invalidate()
                    self.trustTimer = nil
                    _ = self.engine.start()
                    self.rebuildMenu()
                    self.onboardingWindow?.close()
                }
            }
        }
    }
}
