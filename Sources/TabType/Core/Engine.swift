import AppKit
import ApplicationServices
import Combine

/// Central orchestrator: wires keystrokes → context → prediction → ghost-text
/// overlay → Tab-to-accept. Runs entirely on the main actor (the event tap is
/// serviced on the main run loop).
@MainActor
final class Engine {
    private let settings: AppSettings
    private let provider: ModelProvider
    private let router: EngineRouter
    private let monitor = KeystrokeMonitor()
    private let overlay = SuggestionOverlay()
    private let inlineCommand: InlineCommandController
    private let accessory = AccessoryButton()
    private let alternatives = AlternativesController()
    /// The last non-speculative request, kept for word-alternatives regeneration.
    private var lastReq: CompletionRequest?

    /// Fallback context buffer, used when the Accessibility API can't provide the
    /// focused field's text. Rebuilt on focus change.
    private var buffer = ""
    private var currentSuggestion: String?
    private var debounceWork: DispatchWorkItem?
    private var lastFocusedPID: pid_t = 0
    private var lastPredictedPrompt: String = ""
    private(set) var pausedUntil: Date?
    private var scheduleToken = 0
    /// AX text length captured at keydown (before the app processes the key), so we
    /// can poll until the keystroke actually lands in the field ("host publish").
    private var hostBaselineLen: Int?
    /// When set (after accepting a suggestion), `hostPublished()` waits for the field
    /// to reach at least this length — synthesized multi-char inserts land
    /// incrementally, and predicting on a half-landed insert regenerates stale text.
    private var hostExpectedLen: Int?
    /// The text most recently inserted via Tab-accept, used to reject a follow-up
    /// prediction that merely regenerates what was just accepted.
    private var lastAcceptedText: String?
    private var lastAcceptedAt: Date = .distantPast
    /// When the user last typed — presentation waits for a pause (see
    /// `presentWhenSettled`), because Electron caret bounds lag during bursts.
    private var lastKeystrokeAt = Date.distantPast
    /// One-shot flag so the disabled state is logged once, not per keystroke.
    private var loggedDisabled = false
    /// Cotypist-style "parked seed": a suggestion generated speculatively
    /// MID-BURST for a snapshot of the input, served instantly at the next pause
    /// when the typed text still matches (possibly having typed INTO it — LCP).
    private var parked: (input: String, suggestion: String)?
    /// True while `currentSuggestion` is the un-accepted TAIL of a suggestion the
    /// user is Tabbing through word-by-word. While held, no new prediction may
    /// start, land, or overwrite the display — otherwise the recompute triggered
    /// by the accepted word's own insertion steals the remainder mid-Tab.
    /// Released when the remainder is exhausted, on any non-matching real
    /// keystroke (via `clearSuggestion`), or on Escape/focus/app change.
    private var protectingRemainder = false
    /// One-shot bypass of prediction gates (force-activate shortcut).
    private var forceNextPrediction = false
    /// Per-app temporary pauses (bundle id → resume time).
    private var pausedApps: [String: Date] = [:]
    /// Lightweight conversational context: the user's last few COMMITTED inputs
    /// per app (chat fields empty on every send, so without this the model never
    /// sees what the user has been saying). In-memory only.
    private var recentInputs: [String: [String]] = [:]
    /// The last AX-read field text per app — the reliable source for committed
    /// messages. The keystroke fallback `buffer` is lossy (missed keystrokes,
    /// send-by-click boundaries) and used to glue messages together mid-word.
    private var lastAXInput: (bundleId: String, text: String)?

    /// Snapshot the just-sent message (Return pressed / field cleared). Prefers
    /// the last AX snapshot of the field over the keystroke buffer.
    private func commitRecentInput(bundleId: String?) {
        guard let bundleId else { return }
        var text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ax = lastAXInput, ax.bundleId == bundleId {
            let axText = ax.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // The AX snapshot wins unless the buffer strictly extends it (a few
            // final keystrokes typed after the last prediction cycle).
            if !axText.isEmpty, !text.hasPrefix(axText) { text = axText }
        }
        lastAXInput = nil
        guard text.count >= 4 else { return }
        var list = recentInputs[bundleId] ?? []
        if list.last != text {
            list.append(String(text.suffix(300)))
            if list.count > 3 { list.removeFirst(list.count - 3) }
            recentInputs[bundleId] = list
        }
        buffer = ""   // the message left the field
        // The sent message (and often a reply) is about to appear in the transcript —
        // capture it sooner than the next natural refresh would.
        let policy = AppPolicyStore.policy(forBundleId: bundleId)
        if (settings.useScreenContext || policy.forceScreenContext) && policy.includesScreenContext {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                ScreenContextProvider.shared.refreshIfStale()
            }
        }
    }
    /// One-shot log flag for the chat-panels-only skip.
    private var loggedChatPanelSkip: Set<String> = []

    /// Code editors (`chatPanelsOnly`): allow only short text inputs — sidebar
    /// chat composers — never the tall main-editor surface.
    private func allowedByChatPanelPolicy(_ policy: AppPolicy, element: AXUIElement?,
                                          bundleId: String?) -> Bool {
        guard policy.chatPanelsOnly, !forceNextPrediction else { return true }
        if let element, AccessibilityBridge.isTextInput(element),
           let frame = AccessibilityBridge.elementFrame(of: element),
           frame.height <= 280 {
            return true
        }
        if let bundleId, loggedChatPanelSkip.insert(bundleId).inserted {
            Log.shared.info("chat-panels-only: suppressing in \(bundleId)'s editor surface (sidebar chat inputs stay active)")
        }
        return false
    }

    /// Handles for the ghost-dismissal observers (app switch, mouse click).
    private var workspaceObserver: NSObjectProtocol?
    private var mouseMonitor: Any?
    private var accessoryToggleObserver: AnyCancellable?
    /// AX focused-element observer for the frontmost app (recreated on app switch).
    private var focusObserver: AXFocusObserver?

    /// Pasteboard freshness tracking for clipboard context (see `freshClipboardText`).
    private var clipboardChangeCount = -1
    private var clipboardFirstSeen = Date.distantPast

    private(set) var isRunning = false

    init(settings: AppSettings = .shared, provider: ModelProvider = .shared) {
        self.settings = settings
        self.provider = provider
        self.router = EngineRouter(settings: settings, provider: provider)
        self.inlineCommand = InlineCommandController(settings: settings)
    }

    /// Start monitoring. Returns false if the event tap couldn't be created
    /// (usually missing Accessibility permission).
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        wireCallbacks()
        guard monitor.start() else { return false }
        installDismissObservers()
        installFreshContextRekick()
        // Whatever is on the pasteboard at launch predates this session — treat it
        // as stale so it never enters a prompt (only copies made from now on do).
        clipboardChangeCount = NSPasteboard.general.changeCount
        clipboardFirstSeen = .distantPast
        // Personal phrase memory: learn the user's recurring phrases from history.
        if settings.collectTypingHistory {
            PhraseMemory.shared.rebuild(from: TypingHistoryStore.shared.allEntries)
        }
        isRunning = true
        return true
    }

    /// When a screen capture lands with genuinely new content while a suggestion is
    /// visible (or a prediction is imminent), regenerate against the fresh context —
    /// otherwise a capture only ever benefits the NEXT prediction and suggestions
    /// permanently run one conversation-turn behind.
    private var lastFreshRekick = Date.distantPast
    private func installFreshContextRekick() {
        ScreenContextProvider.shared.onFreshContext = { [weak self] bundleId in
            guard let self else { return }
            guard Date().timeIntervalSince(self.lastFreshRekick) > 1.0 else { return }
            guard bundleId == AccessibilityBridge.frontmostBundleId() ?? "" else { return }
            // Only worth a regeneration when something is (about to be) on screen.
            guard self.currentSuggestion != nil || !self.buffer.isEmpty else { return }
            // Never regenerate over a remainder being Tabbed through.
            guard !(self.protectingRemainder && self.currentSuggestion != nil) else { return }
            self.lastFreshRekick = Date()
            self.lastPredictedPrompt = ""   // context changed — bypass the dedup skip
            self.forceNextPrediction = true
            Log.shared.debug("fresh screen context for \(bundleId) — re-kicking prediction")
            self.schedulePrediction()
        }
    }

    /// The keystroke tap only sees keydowns, so without these the ghost text
    /// lingers forever when the user Cmd-Tabs away or clicks elsewhere.
    private func installDismissObservers() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            // System screenshot UI "activating" is not an app switch — hitting
            // ⌘⇧4 must never dismiss the ghost the user is trying to capture.
            let systemCapture: Set<String> = [
                "com.apple.screencaptureui", "com.apple.screenshot.launcher",
            ]
            if let bid = app?.bundleIdentifier, systemCapture.contains(bid) {
                Log.shared.debug("app-switch observer: ignoring \(bid)")
                return
            }
            let newPid = app?.processIdentifier
            MainActor.assumeIsolated {
                // The accessory button is anchored to the previous app's window —
                // hide it now; the next edit in the new app re-shows it.
                self.accessory.hide()
                self.parked = nil   // parked seeds never cross app boundaries
                // Track the new app's focused element via AX notifications so we
                // notice field changes INSTANTLY, not on the next keystroke.
                if let newPid { self.installFocusObserver(pid: newPid) }
                guard self.currentSuggestion != nil || self.inlineCommand.isActive else { return }
                self.clearSuggestion()
                self.lastPredictedPrompt = ""
            }
        }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier {
            installFocusObserver(pid: pid)
        }
        // Hide/show immediately when the Settings toggle changes — otherwise an
        // already-visible button lingers until the next app switch.
        accessoryToggleObserver = settings.$showAccessoryButton
            .removeDuplicates()
            .sink { [weak self] on in
                guard let self else { return }
                if on { self.updateAccessoryButton() } else { self.accessory.hide() }
            }
        // A click that moves the caret or focus makes the ghost stale — but clicks
        // that touch neither (e.g. the ⌘⇧4 screenshot crosshair) must NOT dismiss.
        // So verify the click's consequence instead of assuming it.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { _ in
            MainActor.assumeIsolated {
                let hadSuggestion = self.currentSuggestion != nil
                // Even without a ghost, a click can move text focus (e.g. web
                // navigation) — the accessory button must follow.
                guard hadSuggestion || self.settings.showAccessoryButton else { return }
                let beforeElement = AccessibilityBridge.focusedElement()
                let beforeCaret = beforeElement.flatMap { AccessibilityBridge.caretOffset(of: $0) }
                let beforeLen = beforeElement.flatMap { AccessibilityBridge.stringValue(of: $0)?.count }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    // A click is exactly when text focus appears/disappears with no
                    // keystroke — re-evaluate the accessory button either way.
                    self.updateAccessoryButton()
                    // Send-button click: the field emptied without a keystroke —
                    // remember what was said (same as Return-to-send).
                    if let beforeLen, beforeLen >= 4, self.buffer.count >= 4,
                       let e = AccessibilityBridge.focusedElement(),
                       let afterLen = AccessibilityBridge.stringValue(of: e)?.count, afterLen <= 1 {
                        let bid = AccessibilityBridge.frontmostBundleId()
                        if AppPolicyStore.policy(forBundleId: bid).laggyCaret {
                            self.commitRecentInput(bundleId: bid)
                        }
                        // The field emptied — any displayed ghost (including a
                        // Tab-protected remainder) belongs to the SENT message.
                        // The focus/caret checks below can't catch this in
                        // Electron apps (caret offset reads nil on both sides).
                        if self.currentSuggestion != nil {
                            self.clearSuggestion()
                            self.lastPredictedPrompt = ""
                        }
                    }
                    guard self.currentSuggestion != nil else { return }
                    let afterElement = AccessibilityBridge.focusedElement()
                    let afterCaret = afterElement.flatMap { AccessibilityBridge.caretOffset(of: $0) }
                    let focusChanged: Bool
                    switch (beforeElement, afterElement) {
                    case (nil, nil): focusChanged = false
                    case let (b?, a?): focusChanged = !CFEqual(b, a)
                    default: focusChanged = true
                    }
                    if focusChanged || beforeCaret != afterCaret {
                        self.clearSuggestion()
                        self.lastPredictedPrompt = ""
                    }
                }
            }
        }
    }

    /// Watch the app's focused element: on any focus change, drop stale UI and
    /// warm the context for the NEW field before the first keystroke lands there.
    private func installFocusObserver(pid: pid_t) {
        guard pid != 0 else { focusObserver = nil; return }
        focusObserver = AXFocusObserver(pid: pid) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.currentSuggestion != nil { self.clearSuggestion() }
                if self.inlineCommand.isActive { self.inlineCommand.cancel() }
                self.buffer = ""
                self.lastPredictedPrompt = ""
                self.parked = nil   // parked seeds never cross field boundaries
                self.updateAccessoryButton()
                // Host-aware: a browser tab on a chat site gets the chat treatment.
                let policy = AppPolicyStore.policy(
                    forBundleId: AccessibilityBridge.frontmostBundleId(),
                    host: AccessibilityBridge.frontmostURLHost())
                if (self.settings.useScreenContext || policy.forceScreenContext) && policy.includesScreenContext {
                    ScreenContextProvider.shared.refreshIfStale()
                }
                self.schedulePrewarm(policy: policy)
            }
        }
    }

    // MARK: - Context prewarm

    private var prewarmTask: Task<Void, Never>?
    private var lastPrewarmKey: String?

    /// Speculatively prefill the KV cache with the CURRENT app's context sections
    /// (persona + previous writing + recent messages + clipboard + screen) shortly
    /// after a focus change, so the user's first real pause pays only the
    /// Input-tail prefill instead of the whole prompt. The 1-token result is
    /// discarded; runs only when idle and skipped in Low Power Mode.
    private func schedulePrewarm(policy: AppPolicy) {
        guard settings.isEnabled, !PowerMonitor.shared.isLowPower else { return }
        prewarmTask?.cancel()
        prewarmTask = Task { [weak self] in
            // Let the focus-change screen capture land first (throttle is 1.5s, a
            // capture kicked just above typically completes well inside 0.8s).
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self, !Task.isCancelled else { return }
            // Only when idle — never compete with a real prediction.
            guard self.currentSuggestion == nil, self.buffer.isEmpty else { return }
            let bid = AccessibilityBridge.frontmostBundleId()
            let screenCap = policy.screenContextCap ?? AppPolicyStore.defaultContextCap
            let screenEnabled = (self.settings.useScreenContext || policy.forceScreenContext)
                && policy.includesScreenContext
            let screen = screenEnabled
                ? ScreenContextProvider.shared.contextText(for: bid, cap: screenCap) : ""
            let key = (bid ?? "") + "|" + String(screen.hashValue)
            guard key != self.lastPrewarmKey else { return }   // context unchanged
            self.lastPrewarmKey = key
            let personalExamples: [TypingHistoryStore.AcceptPair] =
                (self.settings.collectTypingHistory && TypingHistoryStore.shared.acceptCount >= 5)
                ? TypingHistoryStore.shared.recentAccepts(limit: 2) : []
            let previousWriting: [String] = self.settings.collectTypingHistory
                ? TypingHistoryStore.shared.contextSamples(budget: 350) : []
            let recentMessages = bid.flatMap { self.recentInputs[$0] } ?? []
            let persona = policy.customInstructions.isEmpty
                ? self.settings.personaPreface
                : self.settings.personaPreface + " " + policy.customInstructions
            let req = CompletionRequest(
                beforeCursor: "Hello", afterCursor: "",
                screenContext: screen,
                clipboard: self.settings.useClipboardContext ? self.freshClipboardText() : "",
                persona: persona,
                personalExamples: personalExamples,
                previousWriting: previousWriting,
                recentMessages: recentMessages,
                speculative: true,
                screenContextBudget: screenCap,
                maxWords: 1, maxTokens: 1, temperature: 0.0)
            let start = Date()
            _ = await self.router.current.complete(req)
            Log.shared.debug("context prewarm (\(bid ?? "?")) finished in \(Int(Date().timeIntervalSince(start) * 1000))ms")
        }
    }

    /// Word alternatives: numbered list of alternative next words. Candidates:
    /// the current suggestion's first word, the phrase memory's top continuations,
    /// a dictionary completion (mid-word), plus one higher-temperature model
    /// regeneration that streams in when ready.
    private func showWordAlternatives() {
        let caretRect = AccessibilityBridge.focusedElement()
            .flatMap { AccessibilityBridge.caretRect(of: $0) }
        var initial: [String] = []
        if let suggestion = currentSuggestion,
           let first = suggestion.split(whereSeparator: { $0 == " " || $0 == "\n" }).first {
            initial.append(String(first))
        }
        initial += PhraseMemory.shared.alternatives(after: buffer, limit: 2)
        guard !initial.isEmpty || lastReq != nil else { return }
        alternatives.show(candidates: initial.isEmpty ? ["…"] : initial, caretRect: caretRect)
        let gen = alternatives.currentGeneration

        // Mid-word dictionary completion joins asynchronously.
        let partial = String(buffer.reversed().prefix { $0.isLetter }.reversed())
        if partial.count >= 3 {
            Task { [weak self] in
                guard let self else { return }
                if let word = await SpellChecker.shared.completion(
                    for: partial, language: self.settings.autocorrectLanguage) {
                    self.alternatives.addCandidate(String(word.dropFirst(partial.count)),
                                                   forGeneration: gen, caretRect: caretRect)
                }
            }
        }
        // One higher-temperature regeneration for a genuinely different option.
        if var req = lastReq {
            req.temperature = 0.7
            req.maxTokens = 8
            req.maxWords = 2
            Task { [weak self] in
                guard let self else { return }
                guard let raw = await self.router.current.complete(req),
                      let first = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                          .split(whereSeparator: { $0 == " " || $0 == "\n" }).first else { return }
                self.alternatives.addCandidate(String(first), forGeneration: gen, caretRect: caretRect)
            }
        }
    }

    /// Insert a chosen alternative word (accept-word bookkeeping included).
    private func insertAlternative(_ word: String) {
        alternatives.hide()
        overlay.hide()
        currentSuggestion = nil
        let toInsert = word + (settings.includeTrailingSpace ? " " : "")
        buffer += toInsert
        Statistics.shared.recordAccepted(wordCount: 1)
        if settings.collectTypingHistory { TypingHistoryStore.shared.record(toInsert) }
        let strategy = AppPolicyStore.policy(forBundleId: AccessibilityBridge.frontmostBundleId())
            .insertionStrategy
        let baselineLen = AccessibilityBridge.focusedElement()
            .flatMap { AccessibilityBridge.stringValue(of: $0)?.count }
        DispatchQueue.main.async {
            self.lastKeystrokeAt = Date()
            TextInserter.insert(toInsert, strategy: strategy)
            self.hostBaselineLen = baselineLen
            self.hostExpectedLen = baselineLen.map { $0 + toInsert.count }
            self.schedulePrediction()
        }
    }

    /// Warm the model's KV prefix cache with the static prompt head (system prompt
    /// + chat template + persona) so the first real suggestion skips that prefill.
    func warmUpModel() {
        let personalExamples: [TypingHistoryStore.AcceptPair] =
            (settings.collectTypingHistory && TypingHistoryStore.shared.acceptCount >= 5)
            ? TypingHistoryStore.shared.recentAccepts(limit: 2) : []
        let req = CompletionRequest(
            beforeCursor: "Hello", afterCursor: "", screenContext: "", clipboard: "",
            persona: settings.personaPreface, personalExamples: personalExamples,
            previousWriting: [], speculative: true,
            maxWords: 1, maxTokens: 1, temperature: 0.0)
        Task { [weak self] in
            guard let self else { return }
            let start = Date()
            _ = await self.router.current.complete(req)
            Log.shared.info("model warm-up finished in \(Int(Date().timeIntervalSince(start) * 1000))ms — static prompt prefix cached")
        }
    }

    /// Pause suggestions for `minutes`, or indefinitely if nil, until `resume()`.
    func pause(minutes: Int?) {
        pausedUntil = minutes.map { Date().addingTimeInterval(TimeInterval($0 * 60)) } ?? .distantFuture
        clearSuggestion()
    }

    func resume() {
        pausedUntil = nil
    }

    /// Active per-app pause for the frontmost app, if any (for the menu).
    func frontmostAppPause() -> (bundleId: String, until: Date)? {
        guard let bid = AccessibilityBridge.frontmostBundleId(),
              let until = pausedApps[bid], Date() < until else { return nil }
        return (bid, until)
    }

    func resumeFrontmostAppPause() {
        if let bid = AccessibilityBridge.frontmostBundleId() { pausedApps[bid] = nil }
    }

    var isPaused: Bool {
        guard let until = pausedUntil else { return false }
        return Date() < until
    }

    func stop() {
        monitor.stop()
        clearSuggestion()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
        accessoryToggleObserver?.cancel()
        accessoryToggleObserver = nil
        accessory.hide()
        isRunning = false
    }

    // MARK: - Callback wiring

    private func wireCallbacks() {
        accessory.onClick = {
            NotificationCenter.default.post(name: .tabTypeOpenSettings, object: nil)
        }
        monitor.onEdit = { chars, isDeletion, _ in
            MainActor.assumeIsolated { self.handleEdit(chars: chars, isDeletion: isDeletion) }
        }
        monitor.handleControlKey = { keyCode, flags in
            MainActor.assumeIsolated { self.handleControlKey(keyCode: keyCode, flags: flags) }
        }
        router.onLateSuggestion = { [weak self] raw, req in
            self?.handleLateSuggestion(raw: raw, req: req)
        }
    }

    /// Map a keydown against configured shortcut bindings and navigation keys.
    private func handleControlKey(keyCode: Int64, flags: CGEventFlags) -> ControlDecision {
        // Word-alternatives panel intercepts digits/Escape while open.
        if alternatives.isActive {
            let digitKeys: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4]   // 1-4 row keys
            if let index = digitKeys[keyCode], let word = alternatives.candidate(at: index) {
                insertAlternative(word)
                return .swallow
            }
            alternatives.hide()
            if keyCode == 53 { return .swallow }   // Esc: just close
            // Any other key closes the panel and proceeds normally.
        }
        if settings.wordAlternativesKey.matches(keyCode: keyCode, flags: flags) {
            showWordAlternatives()
            return .swallow
        }

        // Global enable/disable toggle.
        if settings.toggleKey.matches(keyCode: keyCode, flags: flags) {
            settings.isEnabled.toggle()
            return .swallow
        }
        // Force-activate: one-shot bypass of the prediction gates (short input,
        // mid-line policy, chat-panels-only) — Cotypist's Ctrl+`.
        if settings.forceActivateKey.matches(keyCode: keyCode, flags: flags) {
            forceNextPrediction = true
            runPrediction()
            forceNextPrediction = false
            return .swallow
        }
        // Per-app temporary pause toggle (a few minutes in the frontmost app).
        if settings.appPauseKey.matches(keyCode: keyCode, flags: flags) {
            if let bid = AccessibilityBridge.frontmostBundleId() {
                if pausedApps[bid] != nil {
                    pausedApps[bid] = nil
                    Log.shared.info("per-app pause lifted for \(bid)")
                } else {
                    pausedApps[bid] = Date().addingTimeInterval(5 * 60)
                    clearSuggestion()
                    Log.shared.info("suggestions paused 5 min in \(bid)")
                }
            }
            return .swallow
        }
        // Per-app override: some apps need Tab to keep its native meaning (e.g. IDEs).
        let tabDisabled = keyCode == 48
            && AppPolicyStore.policy(forBundleId: AccessibilityBridge.frontmostBundleId()).disableTabKey
        // ⌥+accept-key sends the REAL key through (form navigation with a ghost up).
        let optionPassthrough = flags.contains(.maskAlternate)
            && !CGEventFlags(rawValue: settings.acceptWordKey.modifiers).contains(.maskAlternate)
            && !CGEventFlags(rawValue: settings.acceptAllKey.modifiers).contains(.maskAlternate)

        // Accept whole suggestion.
        if settings.acceptAllKey.matches(keyCode: keyCode, flags: flags.subtracting(optionPassthrough ? .maskAlternate : [])) {
            if optionPassthrough { clearSuggestion(); return .passthroughStrippingOption }
            if tabDisabled { return .passthrough }
            return acceptCurrent(whole: true) ? .swallow : .passthrough
        }
        // Accept a word (or an inline command). Honors the "accept whole" preference.
        if settings.acceptWordKey.matches(keyCode: keyCode, flags: flags.subtracting(optionPassthrough ? .maskAlternate : [])) {
            if optionPassthrough { clearSuggestion(); return .passthroughStrippingOption }
            if tabDisabled { return .passthrough }
            return acceptCurrent(whole: settings.acceptWholeLine) ? .swallow : .passthrough
        }
        // Dismiss.
        if settings.dismissKey.matches(keyCode: keyCode, flags: flags) {
            if inlineCommand.isActive || currentSuggestion != nil {
                if inlineCommand.isActive { inlineCommand.cancel() }
                clearSuggestion()
                if settings.escapeBehavior == "pause" {
                    pausedUntil = Date().addingTimeInterval(5)   // brief pause after Esc
                }
                return .swallow
            }
            return .passthrough
        }
        // While an emoji picker is active, Up/Down cycle the highlighted candidate
        // instead of cancelling the session and moving the real caret.
        if inlineCommand.isActive, keyCode == 126 || keyCode == 125 {
            let delta = keyCode == 126 ? -1 : 1
            if inlineCommand.moveSelection(by: delta, caretRect: {
                AccessibilityBridge.focusedElement().flatMap { AccessibilityBridge.caretRect(of: $0) }
            }) {
                return .swallow
            }
        }
        // Navigation / editing keys that invalidate a shown suggestion but pass through.
        let navKeys: Set<Int64> = [36, 123, 124, 125, 126, 116, 121, 115, 119] // return, arrows, page/home/end
        if navKeys.contains(keyCode) {
            if inlineCommand.isActive { inlineCommand.cancel() }
            // Return in a chat app usually SENDS — remember what was said, so the
            // next suggestion can continue the user's side of the conversation.
            if keyCode == 36, !flags.contains(.maskShift) {
                let bid = AccessibilityBridge.frontmostBundleId()
                if AppPolicyStore.policy(forBundleId: bid).laggyCaret {
                    commitRecentInput(bundleId: bid)
                }
            }
            clearSuggestion()
            return .passthrough
        }
        return .notControl
    }

    // MARK: - Editing

    private func handleEdit(chars: String, isDeletion: Bool) {
        lastKeystrokeAt = Date()
        // Freeze screen captures while typing (see ScreenContextProvider).
        ScreenContextProvider.shared.lastEditAt = lastKeystrokeAt
        // Track focus changes to reset the fallback buffer and enable enhanced
        // accessibility for Electron/Chromium apps (Slack, VS Code, browsers…).
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if pid != lastFocusedPID {
            lastFocusedPID = pid
            buffer = ""
            if pid != 0 { AccessibilityBridge.enableEnhancedAccessibility(pid: pid) }
            updateAccessoryButton()

            // Kick off screen-memory capture right away on focus change rather than
            // waiting for the next runPrediction() cycle — otherwise the very first
            // suggestion in a freshly-focused window has no completed capture yet.
            let policy = AppPolicyStore.policy(forBundleId: AccessibilityBridge.frontmostBundleId())
            if (settings.useScreenContext || policy.forceScreenContext) && policy.includesScreenContext {
                ScreenContextProvider.shared.refreshIfStale()
            }
        }

        // Maintain fallback buffer.
        if isDeletion {
            if !buffer.isEmpty { buffer.removeLast() }
        } else {
            buffer += chars
        }

        // Inline commands (:emoji / macro) take priority over LLM suggestions.
        let commandActive = inlineCommand.handleEdit(
            chars: chars, isDeletion: isDeletion,
            caretRect: {
                AccessibilityBridge.focusedElement().flatMap { AccessibilityBridge.caretRect(of: $0) }
            })
        if commandActive {
            router.cancelInFlight()
            overlay.hide()
            currentSuggestion = nil
            debounceWork?.cancel()
            return
        }

        // Type-through: when the user types exactly what the ghost predicts, keep
        // the suggestion and shrink it in place instead of killing and regenerating
        // it — stable, instant, and zero model calls for matching keystrokes.
        if !isDeletion, let suggestion = currentSuggestion,
           !chars.isEmpty, suggestion.hasPrefix(chars), suggestion.count > chars.count {
            let remainder = String(suggestion.dropFirst(chars.count))
            // Hide immediately (the old position now overlaps the just-typed char);
            // the shrunken ghost reappears at the settled caret after the pause —
            // during a fast burst it stays hidden, exactly like Cotypist.
            overlay.hide()
            presentWhenSettled(suggestion: remainder, isNewSuggestion: false)
            return
        }

        // Any other edit invalidates the shown suggestion.
        clearSuggestion()

        let bundleId = AccessibilityBridge.frontmostBundleId()
        let policy = AppPolicyStore.policy(forBundleId: bundleId)
        guard policy.isEnabled,
              settings.isEnabled(forBundleId: bundleId) else {
            // Once per disable, not per keystroke — a silently-dead engine has
            // repeatedly masqueraded as "autocomplete is broken".
            if !loggedDisabled {
                loggedDisabled = true
                Log.shared.info("suggestions inactive for \(bundleId ?? "?") (global enable=\(settings.isEnabled), app policy enabled=\(policy.isEnabled)) — keystrokes ignored")
            }
            return
        }
        loggedDisabled = false

        // On a word boundary: replace an emoticon, else autocorrect the finished word.
        // Never autocorrect a code editor's main surface (identifiers aren't typos).
        let autocorrectAllowed = (policy.autocorrectOverride ?? settings.autocorrectEnabled)
            && (!policy.chatPanelsOnly
                || allowedByChatPanelPolicy(policy, element: AccessibilityBridge.focusedElement(),
                                            bundleId: bundleId))
        if !isDeletion, let ch = chars.last, ch == " " || ch == "\n" {
            if !(settings.emoticonsEnabled && replaceEmoticon(boundary: ch)), autocorrectAllowed {
                maybeAutocorrect()
            }
        }

        guard router.current.isReady else { return }

        // Snapshot AX text length *now* — the tap fires before the app inserts the
        // key, so this is the pre-keystroke length. We poll until it changes.
        hostBaselineLen = AccessibilityBridge.focusedElement()
            .flatMap { AccessibilityBridge.stringValue(of: $0)?.count }

        schedulePrediction()
        maybeShowInstantWordCompletion(isDeletion: isDeletion)
    }

    /// Sombra-style zero-latency layer: complete the current WORD from the frequency
    /// dictionary immediately (microseconds, no GPU) while the LLM works on the
    /// phrase continuation. The LLM result replaces this ghost when it lands.
    /// At word boundaries, the personal phrase memory gets first shot: recurring
    /// phrases from the user's own history beat the model for names/sign-offs/jargon.
    private func maybeShowInstantWordCompletion(isDeletion: Bool) {
        guard !isDeletion, currentSuggestion == nil else { return }
        // Same credential gate as the model path — the dictionary layer was
        // happily completing "co" → "company" inside email fields.
        if let f = AccessibilityBridge.focusedElement(),
           AccessibilityBridge.isSecureField(f) || AccessibilityBridge.isCredentialField(f) {
            return
        }

        // Word boundary → the user's own recurring phrases, remembered verbatim.
        if settings.collectTypingHistory, let last = buffer.last, last == " " {
            if let phrase = PhraseMemory.shared.continuation(after: String(buffer.dropLast())) {
                Log.shared.debug("predict -> \"\(phrase)\" [phrase memory] (0ms)")
                presentWhenSettled(suggestion: phrase, isNewSuggestion: true)
                return
            }
        }

        guard let last = buffer.last, last.isLetter else { return }
        // Mid-email ("…@lodhagroup.co" → "company") is never a wanted completion.
        if let lastWord = buffer.split(whereSeparator: { $0 == " " || $0 == "\n" }).last,
           let at = lastWord.firstIndex(of: "@"), at != lastWord.startIndex,
           lastWord.index(after: at) != lastWord.endIndex {
            return
        }
        let partial = String(buffer.reversed().prefix { $0.isLetter }.reversed())
        guard partial.count >= 3 else { return }
        let token = scheduleToken
        Task { [weak self] in
            guard let self else { return }
            guard let word = await SpellChecker.shared.completion(
                for: partial, language: self.settings.autocorrectLanguage) else { return }
            // Stale if another keystroke happened or the LLM already presented.
            guard token == self.scheduleToken, self.currentSuggestion == nil,
                  word.count > partial.count else { return }
            let remainder = String(word.dropFirst(partial.count))
            Log.shared.debug("predict -> \"\(remainder)\" [dictionary] (0ms)")
            // Presented only once typing pauses (settle gate) — mid-burst caret
            // bounds can't be trusted, and Cotypist shows nothing mid-burst either.
            self.presentWhenSettled(suggestion: remainder, isNewSuggestion: true)
        }
    }

    /// The Cotypist presentation rule (observed live): NEVER paint a ghost while
    /// keys are streaming — Electron caret bounds lag ~0.3-0.5s during a burst, so
    /// mid-burst placement lands on stale coordinates and overlaps typed text.
    /// Waits until the typing has paused for the app's settle delay, re-reads the
    /// caret THEN, and presents. A newer keystroke re-arms the wait; a changed
    /// suggestion aborts it.
    private func presentWhenSettled(suggestion: String, isNewSuggestion: Bool,
                                    allowWrap: Bool = false, minSettle: TimeInterval? = nil) {
        // A remainder being Tabbed through is protected — a NEW suggestion must
        // never steal its display slot (re-presents of the remainder itself come
        // through with isNewSuggestion: false).
        if isNewSuggestion, protectingRemainder, currentSuggestion != nil {
            Statistics.shared.record(.heldForRemainder)
            return
        }
        // Register immediately: any keystroke during the wait clears/replaces it
        // (clearSuggestion / type-through), aborting the scheduled presentation.
        currentSuggestion = suggestion
        let policy = AppPolicyStore.policy(forBundleId: AccessibilityBridge.frontmostBundleId())
        // Electron bounds lag ~0.3s after the last keystroke; 0.4s matches the
        // observed Cotypist timing, with the occupancy/ink-band guards as backstop.
        // A caller can lower it (parked seeds: content already proven ready).
        let settle: TimeInterval = minSettle ?? (policy.laggyCaret ? 0.4 : 0.12)
        let elapsed = Date().timeIntervalSince(lastKeystrokeAt)
        if elapsed >= settle {
            guard currentSuggestion == suggestion else { return }
            let element = AccessibilityBridge.focusedElement()
            let caretRect = element.flatMap { AccessibilityBridge.caretRect(of: $0) }
            let windowRect = element.flatMap { ContextReader.windowRect(of: $0) }
            present(suggestion: suggestion, inlineCaret: caretRect, windowRect: windowRect,
                    policy: policy, isNewSuggestion: isNewSuggestion, allowWrap: allowWrap)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (settle - elapsed) + 0.01) { [weak self] in
            guard let self, self.currentSuggestion == suggestion else { return }
            self.presentWhenSettled(suggestion: suggestion, isNewSuggestion: isNewSuggestion,
                                    allowWrap: allowWrap, minSettle: minSettle)
        }
    }

    /// Wait for the keystroke to appear in the AX tree (host-publish), then predict.
    /// Polls on the main run loop without blocking; a token cancels stale schedules.
    ///
    /// In continuous mode (default), the "settle" wait is just long enough for the
    /// keystroke to land in the AX tree — a prediction is requested on essentially
    /// every keystroke, and `Predictor`'s coalescing (busy-gate + latest-request-wins)
    /// collapses a fast-typing burst down to one generation at a time, so suggestions
    /// keep pace with typing instead of only appearing once it pauses. In debounced
    /// mode (opt-out, or automatic on battery — see `batteryUseDebounce`), the full
    /// idle-wait behavior is preserved.
    private func schedulePrediction() {
        debounceWork?.cancel()
        scheduleToken += 1
        let token = scheduleToken
        let start = Date()

        func poll(_ delay: Double) {
            let work = DispatchWorkItem { [weak self] in
                guard let self, token == self.scheduleToken else { return }
                let elapsed = Date().timeIntervalSince(start)
                if self.hostPublished() || elapsed > 0.4 {
                    self.runPrediction()
                } else {
                    poll(0.025)
                }
            }
            debounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        // Laggy-caret (Electron) apps: mid-burst AX text is INCOMPLETE, so every
        // continuous-mode request captures stale input, gets generated, and is
        // discarded by the freshness guard — while keeping the model busy so the
        // real post-pause request queues behind garbage. Predict only after the
        // same idle pause used for presentation (the Cotypist request cadence).
        let laggy = AppPolicyStore.policy(forBundleId: AccessibilityBridge.frontmostBundleId()).laggyCaret
        let useContinuous = !laggy && settings.continuousGeneration
            && !(PowerMonitor.shared.isLowPower && settings.batteryUseDebounce)
        if laggy {
            // Speculative "parked seed": generate for the current snapshot while
            // the user is still typing — the KV prefix cache makes it cheap — and
            // PARK the result. At the pause, a matching park serves instantly.
            let token = scheduleToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                guard let self, token == self.scheduleToken else { return }
                self.runPrediction(speculative: true)
            }
            poll(0.2)    // brief idle-wait; the freshness guard + re-kick cover stale input
        } else if useContinuous {
            poll(0.02)   // minimal settle — just a chance for host-publish, no idle-wait
        } else {
            // Initial settle = the configured debounce (+ battery back-off), then fast polls.
            let baseDebounce = settings.debounceMs
            let settle = baseDebounce + PowerMonitor.shared.extraDebounceMs
            poll(Double(settle) / 1000.0)
        }
    }

    /// If the token just before the boundary is a known emoticon (":-)"), replace it
    /// with the emoji. Returns true if a replacement was made.
    private func replaceEmoticon(boundary: Character) -> Bool {
        guard buffer.count >= 2 else { return false }
        let withoutBoundary = String(buffer.dropLast())
        guard let token = withoutBoundary.split(whereSeparator: { $0 == " " || $0 == "\n" }).last,
              let emoji = Emoticons.emoji(for: String(token)) else { return false }
        let deleteCount = token.count + 1   // token + boundary
        buffer = String(buffer.dropLast(deleteCount)) + emoji + String(boundary)
        DispatchQueue.main.async {
            TextInserter.backspace(count: deleteCount)
            TextInserter.insert(emoji + String(boundary), strategy: .keystroke)
        }
        return true
    }

    /// Correct the word just before the trailing boundary in the buffer, if SymSpell
    /// finds a confident fix. Applied asynchronously and only if the buffer tail is
    /// still intact (the user hasn't typed past it).
    private func maybeAutocorrect() {
        // buffer currently ends with the boundary char just typed.
        guard buffer.count >= 4 else { return }
        let withoutBoundary = String(buffer.dropLast())
        guard let word = withoutBoundary.split(whereSeparator: { $0 == " " || $0 == "\n" }).last,
              word.count >= 3, word.allSatisfy({ $0.isLetter }) else { return }
        let wordStr = String(word)
        let boundary = String(buffer.last!)
        let expectedSuffix = wordStr + boundary

        // Don't touch secure fields.
        if let f = AccessibilityBridge.focusedElement(), AccessibilityBridge.isSecureField(f) { return }

        SpellChecker.shared.correct(wordStr, language: settings.autocorrectLanguage) { [weak self] corrected in
            guard let self, let corrected else { return }
            guard self.buffer.hasSuffix(expectedSuffix) else { return }  // tail unchanged
            let deleteCount = expectedSuffix.count
            self.buffer = String(self.buffer.dropLast(deleteCount)) + corrected + boundary
            TextInserter.backspace(count: deleteCount)
            TextInserter.insert(corrected + boundary, strategy: .keystroke)
            Log.shared.debug("autocorrect: \(wordStr) -> \(corrected)")
        }
    }

    /// Reject/strip suggestions that just repeat what the user already typed. Returns
    /// the (possibly trimmed) suggestion, or nil if it's a pure echo.
    nonisolated static func stripEcho(_ suggestion: String, prefix: String) -> String? {
        let sug = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sug.isEmpty else { return nil }
        let tail = String(prefix.suffix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return suggestion }

        let sugLower = sug.lowercased()
        let tailLower = tail.lowercased()
        // Pure echo: the suggestion is (part of) the end of what was typed.
        if tailLower.hasSuffix(sugLower) || sugLower == tailLower { return nil }
        // Mid-prefix echo: the whole suggestion already appears in the recent text
        // ("testing how fast the autocomplete" → "how fast the"). Only for LONG
        // suggestions — re-using a short phrase from two sentences ago ("sounds
        // good", "the proposal") is normal writing, not an echo; the pure-echo
        // suffix check above already catches actual repetition at the caret.
        let echoWords = sugLower.split(separator: " ").count
        if echoWords >= 4 || sugLower.count >= 30, tailLower.contains(sugLower) { return nil }
        // Overlap: suggestion starts by repeating the tail's last words → strip it.
        if sugLower.hasPrefix(tailLower), sug.count > tail.count {
            let stripped = String(sug.dropFirst(tail.count))
            return stripped.isEmpty ? nil : stripped
        }
        return suggestion
    }

    /// Reply-opener phrases that signal the model answered instead of continuing the
    /// user's text (assistant-persona drift). Checked case-insensitively against the
    /// start of the (trimmed) suggestion.
    nonisolated private static let assistantSpeakPrefixes: [String] = [
        "i'm sorry", "i am sorry", "i apologize",
        "as an ai", "as a language model",
        "great question", "that's a great",
    ]

    /// Openers that are fine mid-sentence but signal REPLY-drift when the author
    /// just finished a sentence ("?"/"!" — exactly when the model is most tempted
    /// to answer the conversation instead of continuing the author's text).
    /// "Yes,"/"No,"/"Sure," live here rather than in the unconditional list: in a
    /// chat the author's OWN reply very often starts exactly that way, and hard-
    /// rejecting those deleted the highest-value chat suggestions.
    nonisolated private static let sentenceEndReplyPrefixes: [String] = [
        "i'll ", "i will ", "i can ", "here's ", "here is ",
        "you can ", "you should ", "we can ", "let me ",
        "sure,", "sure!", "sure.", "of course,", "certainly,",
        "yes,", "yes.", "no,", "no.",
        "i understand", "i see that",
        "unfortunately", "thanks for", "thank you for",
    ]

    /// Reject suggestions that read like an assistant reply rather than a continuation
    /// of the user's own text. Returns the suggestion unchanged, or nil to reject.
    /// `inputTail` (the typed text's end) gates the stricter check.
    nonisolated static func stripAssistantSpeak(_ suggestion: String,
                                                inputTail: String = "") -> String? {
        let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        for prefix in assistantSpeakPrefixes where lower.hasPrefix(prefix) {
            return nil
        }
        // After a finished sentence, reply-shaped openers are almost always the
        // model answering the conversation, not the author's next sentence.
        let tail = inputTail.trimmingCharacters(in: .whitespaces)
        if let last = tail.last, last == "?" || last == "!" {
            for prefix in sentenceEndReplyPrefixes where lower.hasPrefix(prefix) {
                return nil
            }
        }
        return suggestion
    }

    /// Reconcile a suggestion's leading boundary against the char before the caret so
    /// accepting never merges words (or doubles spaces). Only handles the unambiguous
    /// whitespace-boundary case; the letter/number-boundary case is ambiguous (same-word
    /// completion vs. new word) and is resolved by `reconcileMidWord` instead, which can
    /// actually distinguish the two via the plausibility dictionary.
    nonisolated static func reconcile(_ suggestion: String, prefix: String) -> String {
        var s = suggestion
        guard let prev = prefix.last, prev.isWhitespace else { return s }
        while let f = s.first, f == " " { s.removeFirst() }
        return s
    }

    /// Resolves a suggestion's leading boundary when the caret sits right after a
    /// letter/number — the case `reconcile` can't disambiguate on its own. Tries the
    /// same-word completion first (no space — e.g. "the" + "n" → "then", matching what
    /// the model is explicitly instructed to do when it ends mid-word); if that's
    /// implausible, reinterprets the fragment as a new word (space inserted) instead of
    /// just discarding it; only rejects if neither reading is plausible.
    private func reconcileMidWord(_ suggestion: String, prefix: String, req: CompletionRequest,
                                  elapsedMs: UInt64) async -> String? {
        let noLeadingSpace = suggestion.hasPrefix(" ") ? String(suggestion.dropFirst()) : suggestion
        guard !noLeadingSpace.isEmpty else { return nil }

        let partial = String(prefix.reversed().prefix { $0.isLetter }.reversed())
        let fragment = String(noLeadingSpace.prefix { $0.isLetter || $0 == "'" })

        // The model often completes the WHOLE word being typed ("te" → "test");
        // strip the already-typed part so accepting doesn't duplicate it ("tetest").
        if let stripped = Engine.stripPartialOverlap(suggestion: noLeadingSpace,
                                                     partial: partial, fragment: fragment) {
            return stripped.isEmpty ? nil : stripped
        }

        let sameWordPlausible = await SpellChecker.shared.isPlausibleContinuation(
            partial: partial, fragment: fragment, language: settings.autocorrectLanguage)
        if sameWordPlausible {
            return noLeadingSpace   // direct append — completes the current word
        }

        // Names and jargon are never in the dictionary, but they're almost always
        // already visible somewhere — on screen, in the conversation, or earlier in
        // the author's own text. If the joined word appears in any of those, accept
        // the same-word reading instead of discarding a correct completion.
        let joined = (partial + fragment).lowercased()
        if !partial.isEmpty, joined.count >= 3 {
            let seenInContext = req.screenContext.lowercased().contains(joined)
                || req.recentMessages.contains(where: { $0.lowercased().contains(joined) })
                || prefix.dropLast(partial.count).lowercased().contains(joined)
            if seenInContext {
                return noLeadingSpace
            }
        }

        let newWordPlausible = await SpellChecker.shared.isPlausibleContinuation(
            partial: "", fragment: fragment, language: settings.autocorrectLanguage)
        guard newWordPlausible else {
            Log.shared.debug("predict -> (mid-word implausible: \(partial)+\(fragment)) (\(elapsedMs)ms)")
            Statistics.shared.record(.rejectedMidWordImplausible)
            return nil
        }
        return " " + noLeadingSpace
    }

    /// Trims the suggestion's tail when it duplicates the text already after the
    /// caret ("…later today?" suggested while "?" already follows → drop the "?").
    /// Longest overlap wins, capped to keep the scan cheap.
    nonisolated static func trimSuffixOverlap(_ suggestion: String, afterCursor: String) -> String {
        let after = afterCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !after.isEmpty, !suggestion.isEmpty else { return suggestion }
        let maxLen = min(20, min(suggestion.count, after.count))
        for len in stride(from: maxLen, through: 1, by: -1) {
            let candidate = String(after.prefix(len))
            guard suggestion.hasSuffix(candidate) else { continue }
            // Short overlaps of ordinary letters ("e" == "e") are coincidence, not
            // duplication — only trim them when they're punctuation.
            if len < 3 && candidate.contains(where: { $0.isLetter || $0.isNumber }) { continue }
            return String(suggestion.dropLast(len))
        }
        return suggestion
    }

    /// When the caret is mid-word and the model repeated the word being typed
    /// ("te" typed, suggestion "test and more"), returns the suggestion with the
    /// already-typed partial stripped ("st and more"). Returns "" for a pure echo
    /// of the partial (caller rejects), nil when there's no overlap to strip.
    nonisolated static func stripPartialOverlap(suggestion: String, partial: String,
                                                fragment: String) -> String? {
        guard partial.count >= 2,
              fragment.lowercased().hasPrefix(partial.lowercased()) else { return nil }
        guard fragment.count > partial.count else {
            // Fragment IS the partial ("te" → "te" or "te and more"): drop the
            // duplicated word, keep any genuine continuation after it. An empty
            // result (pure echo) is rejected by the caller.
            return String(suggestion.dropFirst(fragment.count))
        }
        return String(suggestion.dropFirst(partial.count))
    }

    /// Gate junk predictions: need at least a couple of meaningful characters and a
    /// sensible boundary (don't fire mid-URL or right after a bare `/@`).
    nonisolated static func shouldPredict(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return false }
        
        // Wait for at least 1 word on the current line before predicting (or a very long first word).
        let currentLine = input.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
        let lineTrimmed = currentLine.trimmingCharacters(in: .whitespaces)
        guard lineTrimmed.contains(where: { $0.isWhitespace }) || lineTrimmed.count >= 3 else { return false }
        if let last = input.last, "/@".contains(last) { return false }
        if let lastWord = input.split(whereSeparator: { $0 == " " || $0 == "\n" }).last {
            if lastWord.contains("://") { return false }
            // Typing an email address (content-based backstop for credential
            // fields the AX label check can't identify): "x@y" mid-word. A chat
            // @mention has nothing before the "@" and stays allowed.
            if let at = lastWord.firstIndex(of: "@"), at != lastWord.startIndex,
               lastWord.index(after: at) != lastWord.endIndex {
                return false
            }
        }
        return true
    }

    /// True once the field's AX text reflects the latest keystroke (or AX text isn't
    /// available, in which case the keystroke buffer is the source of truth).
    private func hostPublished() -> Bool {
        guard let baseline = hostBaselineLen,
              let element = AccessibilityBridge.focusedElement(),
              let len = AccessibilityBridge.stringValue(of: element)?.count else {
            return true
        }
        // After a Tab-accept, synthesized multi-char inserts land incrementally —
        // wait for the whole insert, not just the first character.
        if let expected = hostExpectedLen { return len >= expected }
        return len != baseline
    }

    private func runPrediction(speculative: Bool = false) {
        let front = NSWorkspace.shared.frontmostApplication
        let frontApp = front?.localizedName
        let bundleId = front?.bundleIdentifier
        // Domain-specific overrides (browsers): most specific policy wins.
        let host = AccessibilityBridge.frontmostURLHost()
        let policy = AppPolicyStore.policy(forBundleId: bundleId, host: host)
        guard policy.isEnabled else { return }

        // The user is Tabbing through a suggestion word-by-word — the remainder
        // on screen must not be recomputed out from under them. But if the field
        // has emptied under the hold (message sent without a keystroke), the
        // remainder belongs to the sent text — drop it and continue normally.
        if protectingRemainder, currentSuggestion != nil {
            let fieldText = AccessibilityBridge.focusedElement()
                .flatMap { AccessibilityBridge.stringValue(of: $0) } ?? ""
            if fieldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clearSuggestion()
            } else {
                Statistics.shared.record(.heldForRemainder)
                return
            }
        }

        // Paused after Escape, or conserving battery (on-demand only).
        if let until = pausedUntil, Date() < until { return }
        if PowerMonitor.shared.isLowPower && settings.batteryOnDemandOnly { return }

        // Per-domain disable (browsers).
        if !settings.disabledDomains.isEmpty, let host = AccessibilityBridge.frontmostURLHost(),
           settings.disabledDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            Log.shared.debug("predict skipped: disabled domain \(host)")
            return
        }

        // Screen memory (throttled, off the typing path), unless this app opts out or
        // we're conserving battery. Chat/messaging apps force this on regardless of
        // the global toggle — reading recent conversation is the whole point there.
        let screenContextEnabled = (settings.useScreenContext || policy.forceScreenContext)
            && policy.includesScreenContext
        if screenContextEnabled && !PowerMonitor.shared.shouldPauseCapture {
            ScreenContextProvider.shared.refreshIfStale()
        }
        _ = frontApp
        // One cap for both the fetch and the prompt budget so they can't diverge.
        // Host-aware: in browsers, only same-site entries count as current context.
        let screenCap = policy.screenContextCap ?? AppPolicyStore.defaultContextCap
        var screenContext = screenContextEnabled
            ? ScreenContextProvider.shared.contextText(for: bundleId, cap: screenCap, host: host) : ""
        // Cross-app background: the previous app/site's freshest snippet, offered
        // as an explicitly labeled section — useful ("replying about what I just
        // read") without masquerading as the current topic.
        let previousApp = screenContextEnabled
            ? ScreenContextProvider.shared.previousAppSnippet(excludingBundleId: bundleId, host: host)
            : nil

        let ctx = ContextReader.gather(
            fallbackBuffer: buffer,
            screenContext: screenContext,
            inputChars: policy.inputContextChars ?? settings.contextChars,
            wantsDocumentHead: policy.documentProfile)

        // Google Docs renders to canvas — AX text is unavailable until the user
        // enables its accessibility mode. Tell them ONCE how to fix it.
        if !settings.didShowGoogleDocsHint,
           let host = AccessibilityBridge.frontmostURLHost(), host.hasSuffix("docs.google.com"),
           let focused = ctx.focused, AccessibilityBridge.stringValue(of: focused) == nil {
            settings.didShowGoogleDocsHint = true
            overlay.showHUD(text: "Google Docs: turn on View ▸ Show accessibility (⌘⌥Z) to get suggestions",
                            windowRect: ctx.focused.flatMap { ContextReader.windowRect(of: $0) })
            DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
                guard let self, self.currentSuggestion == nil else { return }
                self.overlay.hide()
            }
            return
        }

        guard ctx.hasInput, forceNextPrediction || Engine.shouldPredict(ctx.input) else {
            // An empty field with a ghost still painted means the text left the
            // field without a keystroke (send click, programmatic clear) — the
            // suggestion belongs to text that no longer exists.
            if !ctx.hasInput, currentSuggestion != nil { clearSuggestion() }
            return
        }

        // A truly empty line gives a small model nothing to anchor on, so it can
        // latch onto screen noise — but the old threshold (12 chars) blinded the
        // first words of EVERY message and toggled the <on_screen> section in and
        // out of the prompt, invalidating the prewarmed KV prefix exactly when
        // latency matters most. Reply-drift on short prefixes is already handled
        // by the continuation reminder, StartGuard, and stripAssistantSpeak.
        if !policy.forceScreenContext {
            let currentLine = ctx.input.split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
            if currentLine.trimmingCharacters(in: .whitespaces).count < 3 { screenContext = "" }
        }

        // Require an actual focused element — like Cotypist, never suggest when
        // nothing is focused/selected (even if the keystroke buffer has text, e.g.
        // from typing over a non-text control or between fields).
        guard ctx.focused != nil else {
            Log.shared.debug("predict skipped: no focused element")
            return
        }

        // Code editors: only sidebar chat inputs, never the main editor.
        guard allowedByChatPanelPolicy(policy, element: ctx.focused, bundleId: bundleId) else { return }

        // Per-app temporary pause (shortcut-toggled, a few minutes).
        if let bid = bundleId, let until = pausedApps[bid] {
            if Date() < until { return }
            pausedApps[bid] = nil
        }

        // Never autocomplete a password field.
        if policy.excludesSecureField, let f = ctx.focused, AccessibilityBridge.isSecureField(f) {
            Log.shared.debug("predict skipped: secure field in \(bundleId ?? "?")")
            return
        }
        // …or the plain-text half of a login/payment form (email, username, OTP,
        // card number): suggestions there are noise at best.
        if let f = ctx.focused, AccessibilityBridge.isCredentialField(f) {
            Log.shared.debug("predict skipped: credential field in \(bundleId ?? "?")")
            return
        }

        // Per-app "mid-line completions" override.
        if !forceNextPrediction, !policy.allowsMidLine, let f = ctx.focused,
           AccessibilityBridge.hasTextAfterCaret(of: f) {
            Log.shared.debug("predict skipped: mid-line disabled for \(bundleId ?? "?")")
            return
        }

        if settings.collectTypingHistory && settings.storeInputsWithoutAcceptedCompletions {
            TypingHistoryStore.shared.record(String(ctx.input.suffix(120)))
        }

        // Parked seed: a speculative generation from mid-burst may already cover
        // the current input — serve it instantly instead of generating again.
        if !speculative, let p = parked {
            parked = nil
            if ctx.input == p.input {
                Log.shared.debug("predict -> \"\(p.suggestion)\" [parked] (0ms)")
                presentWhenSettled(suggestion: p.suggestion, isNewSuggestion: true, minSettle: 0.25)
                return
            }
            // The user typed INTO the parked suggestion — serve the remaining tail.
            if ctx.input.hasPrefix(p.input) {
                let typedExtra = String(ctx.input.dropFirst(p.input.count))
                if !typedExtra.isEmpty, p.suggestion.hasPrefix(typedExtra),
                   p.suggestion.count > typedExtra.count {
                    let tail = String(p.suggestion.dropFirst(typedExtra.count))
                    Log.shared.debug("predict -> \"\(tail)\" [parked lcp] (0ms)")
                    presentWhenSettled(suggestion: tail, isNewSuggestion: true, minSettle: 0.25)
                    return
                }
            }
        }

        // Remember the field's AX text — commitRecentInput reads this when the
        // message is sent (the keystroke buffer alone is lossy).
        if let bid = bundleId, !ctx.input.isEmpty { lastAXInput = (bid, ctx.input) }

        // Skip redundant work if nothing changed since the last prediction.
        if !speculative {
            if ctx.dedupKey == lastPredictedPrompt { return }
            lastPredictedPrompt = ctx.dedupKey
        }

        let engine = router.current
        let clipboard = settings.useClipboardContext ? freshClipboardText() : ""
        let persona = policy.customInstructions.isEmpty
            ? settings.personaPreface
            : settings.personaPreface + " " + policy.customInstructions
        // Personal few-shot: only once there's real signal (≥5 accepts).
        let personalExamples: [TypingHistoryStore.AcceptPair] =
            (settings.collectTypingHistory && TypingHistoryStore.shared.acceptCount >= 5)
            ? TypingHistoryStore.shared.recentAccepts(limit: 2) : []
        // The author's own recent writing — the strongest voice/topic context.
        let previousWriting: [String] = settings.collectTypingHistory
            ? TypingHistoryStore.shared.contextSamples(budget: 350) : []
        // The user's last few sent messages in THIS app — conversational thread.
        let recentMessages = bundleId.flatMap { recentInputs[$0] } ?? []
        let req = CompletionRequest(
            beforeCursor: ctx.input,
            afterCursor: ctx.afterCursor,
            screenContext: screenContext,
            clipboard: clipboard,
            persona: persona,
            personalExamples: personalExamples,
            previousWriting: previousWriting,
            recentMessages: recentMessages,
            documentStart: ctx.documentStart,
            previousAppName: previousApp?.app ?? "",
            previousAppContext: previousApp?.text ?? "",
            screenIsConversation: policy.transcriptViaAX,
            speculative: speculative,
            screenContextBudget: screenCap,
            maxWords: (PowerMonitor.shared.isLowPower && settings.batteryShorterCompletions)
                ? min(settings.maxWords, 3) : settings.maxWords,
            maxTokens: settings.maxTokens,
            temperature: settings.temperature)
        if !speculative { lastReq = req }   // word-alternatives regeneration basis
        Log.shared.debug("predict app=\(bundleId ?? "?") engine=\(engine.displayName) focused=\(ctx.focused != nil) screenCtx=\(screenContext.count) inputTail=\"\(String(ctx.input.suffix(40)))\"")
        if settings.verboseLog {
            let fullPrompt = PromptBuilder.body(req, cap: PromptBuilder.defaultCap)
            Log.shared.debug("predict full prompt:\n---\n\(fullPrompt)\n---")
        }
        let startedAt = DispatchTime.now()

        Task { [weak self] in
            guard let self else { return }
            // Completing a misspelling is never what the user wants — skip the whole
            // generation when the last COMPLETED word looks like a typo (opt-out via
            // Settings ▸ Text Tools). Mid-word partials are exempt: a half-typed rare
            // name ("Nil…") is indistinguishable from a typo to the dictionary, and
            // gating on it suppressed generation for exactly the words the model is
            // best placed to finish from context.
            if self.settings.skipOnTypo, let (token, isPartial) = Engine.typoCheckToken(ctx.input),
               !isPartial,
               await SpellChecker.shared.isLikelyTypo(
                   word: token, isPartial: isPartial, language: self.settings.autocorrectLanguage) {
                Log.shared.debug("predict -> (typo before caret, skipped: \"\(token)\")")
                Statistics.shared.record(.gatedTypo)
                return
            }
            Statistics.shared.record(.requested)
            let raw = await engine.complete(req)
            await self.handlePredictionResult(
                raw: raw, req: req, ctxInput: ctx.input, policy: policy, startedAt: startedAt)
        }
    }

    /// The token the typo gate should inspect: the trailing letter-run when the caret
    /// is mid-word (`isPartial`), or the last completed word right after a boundary.
    /// Returns nil when there's nothing meaningful to check (punctuation, digits…).
    nonisolated static func typoCheckToken(_ input: String) -> (String, Bool)? {
        guard let last = input.last else { return nil }
        if last.isLetter {
            let partial = String(input.reversed().prefix { $0.isLetter }.reversed())
            return partial.isEmpty ? nil : (partial, true)
        }
        guard last == " " || last == "\n" else { return nil }
        let trimmed = String(input.dropLast())
        guard let word = trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" }).last else { return nil }
        let cleaned = String(word).trimmingCharacters(in: .punctuationCharacters)
        return cleaned.isEmpty ? nil : (cleaned, false)
    }

    /// Shared post-processing for a raw model output: echo/assistant-speak rejection,
    /// word-boundary reconciliation, the mid-word plausibility guard, and finally
    /// showing the suggestion. Used both for the direct `runPrediction()` path and for
    /// a coalesced request that completes later (`handleLateSuggestion`).
    private func handlePredictionResult(raw: String?, req: CompletionRequest, ctxInput: String,
                                        policy: AppPolicy, startedAt: DispatchTime) async {
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
        if settings.verboseLog {
            Log.shared.debug("predict raw model output (pre-post-processing): \(raw.map { "\"\($0)\"" } ?? "nil")")
        }
        // nil here is usually NOT an empty generation — busy-coalesced and
        // superseded requests also return nil (and are retried/late-delivered);
        // the Predictor records the accurate funnel event for each case.
        guard let raw, !raw.isEmpty else {
            Log.shared.debug("predict -> (no suggestion) (\(elapsedMs)ms)")
            return
        }
        // Drop echoes (the model repeating what was just typed), then reject
        // assistant-speak/reply-drift, then reconcile the word boundary so
        // accepting never merges into the prefix.
        guard let deEchoed = Engine.stripEcho(raw, prefix: ctxInput) else {
            Log.shared.debug("predict -> (echo rejected) (\(elapsedMs)ms)")
            Statistics.shared.record(.rejectedEcho)
            return
        }
        guard let clean = Engine.stripAssistantSpeak(deEchoed, inputTail: String(ctxInput.suffix(10))) else {
            Log.shared.debug("predict -> (assistant-speak rejected) (\(elapsedMs)ms)")
            Statistics.shared.record(.rejectedAssistantSpeak)
            return
        }
        var suggestion = Engine.reconcile(clean, prefix: ctxInput)
        guard !suggestion.isEmpty else { return }

        // Don't duplicate what already follows the caret ("?" suggested when a "?"
        // is already there).
        suggestion = Engine.trimSuffixOverlap(suggestion, afterCursor: req.afterCursor)
        guard !suggestion.isEmpty else {
            Log.shared.debug("predict -> (entirely duplicated after-cursor text) (\(elapsedMs)ms)")
            Statistics.shared.record(.rejectedSuffixOverlap)
            return
        }

        // Reject a prediction that merely regenerates the text just accepted via Tab
        // (happens when the speculative refetch still raced the insert into the AX
        // tree — the accepted text isn't in the prefix yet, so stripEcho misses it).
        if let accepted = lastAcceptedText, Date().timeIntervalSince(lastAcceptedAt) < 3,
           suggestion.trimmingCharacters(in: .whitespaces) == accepted.trimmingCharacters(in: .whitespaces) {
            Log.shared.debug("predict -> (repeat of accepted text rejected) (\(elapsedMs)ms)")
            Statistics.shared.record(.rejectedRepeatAccepted)
            return
        }

        // Letter/number boundary is ambiguous (same-word completion vs. new word) —
        // resolve it via the plausibility dictionary rather than always forcing a
        // space, which used to destroy correct mid-word completions like "the"+"n".
        if let lastWord = ctxInput.last, lastWord.isLetter || lastWord.isNumber {
            guard let resolved = await reconcileMidWord(suggestion, prefix: ctxInput, req: req, elapsedMs: elapsedMs) else {
                return
            }
            suggestion = resolved
        }

        // Speculative results are PARKED, never presented — being "stale" is their
        // entire purpose (they were generated for a mid-burst snapshot).
        if req.speculative {
            parked = (input: ctxInput, suggestion: suggestion)
            Log.shared.debug("predict -> parked \"\(suggestion)\" for snapshot tail \"…\(String(ctxInput.suffix(24)))\" (\(elapsedMs)ms)")
            return
        }

        // The field may have changed while the model was generating (more typing,
        // deletions, Cmd+A wipe) — a result for stale input must never be shown.
        // Same guard the late-coalesced path has always had.
        let fresh = ContextReader.gather(fallbackBuffer: buffer, screenContext: req.screenContext,
                                         inputChars: settings.contextChars)
        guard fresh.input == ctxInput else {
            Log.shared.debug("predict -> (input changed during generation, discarded) (\(elapsedMs)ms)")
            Statistics.shared.record(.discardedStale)
            // Re-kick for the CURRENT input — without this, a burst whose requests
            // were all stale ends with the model idle and no suggestion ever shown.
            // Not while a remainder is being Tabbed through: the "changed" input
            // is the accepted word itself.
            if !(protectingRemainder && currentSuggestion != nil) { schedulePrediction() }
            return
        }

        Log.shared.debug("predict -> \"\(suggestion)\" (\(elapsedMs)ms)")
        // Wrapped (multi-line) ghost is only safe when nothing follows the caret —
        // otherwise the wrapped lines paint over the user's own text below.
        let allowWrap = req.afterCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Placement resolves inside the settle gate: presentation waits for a
        // typing pause and reads the caret THEN (mid-burst reads are stale).
        presentWhenSettled(suggestion: suggestion, isNewSuggestion: true, allowWrap: allowWrap)
    }

    /// A coalesced local-model request finished after its original `runPrediction()`
    /// caller already gave up (see `Predictor.onLateSuggestion`). Only shown if the
    /// caret prefix still matches what it was generated for — never shows a
    /// suggestion behind what's since been typed.
    private func handleLateSuggestion(raw: String, req: CompletionRequest) {
        if let until = pausedUntil, Date() < until { return }
        // Never replace (or re-kick over) a remainder being Tabbed through.
        if protectingRemainder, currentSuggestion != nil {
            Statistics.shared.record(.heldForRemainder)
            return
        }
        let ctx = ContextReader.gather(
            fallbackBuffer: buffer, screenContext: req.screenContext, inputChars: settings.contextChars)
        // Speculative results skip the staleness check — they're parked, and being
        // generated for an older snapshot is their whole point.
        guard req.speculative || ctx.input == req.beforeCursor else {
            Log.shared.debug("predict -> (late suggestion stale, discarded)")
            Statistics.shared.record(.discardedStale)
            schedulePrediction()   // regenerate for the input as it is NOW
            return
        }
        let policy = AppPolicyStore.policy(forBundleId: AccessibilityBridge.frontmostBundleId())
        guard policy.isEnabled else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.handlePredictionResult(
                raw: raw, req: req,
                ctxInput: req.speculative ? req.beforeCursor : ctx.input,
                policy: policy, startedAt: DispatchTime.now())
        }
    }

    /// Display the suggestion: inline ghost text when we have precise caret bounds,
    /// otherwise a HUD pill anchored to the focused window (Electron/Catalyst apps).
    private func present(suggestion: String, inlineCaret: CGRect?, windowRect: CGRect?,
                         policy: AppPolicy? = nil, isNewSuggestion: Bool = true,
                         allowWrap: Bool = false) {
        // Re-present paths don't carry a policy — resolve the frontmost app's so
        // per-app presentation rules (bubble vs inline) always apply.
        let policy = policy ?? AppPolicyStore.policy(forBundleId: AccessibilityBridge.frontmostBundleId())
        // A remainder being Tabbed through owns the display slot (see
        // presentWhenSettled — this is the direct-call backstop).
        if isNewSuggestion, protectingRemainder, currentSuggestion != nil,
           currentSuggestion != suggestion {
            return
        }
        currentSuggestion = suggestion
        if isNewSuggestion { Statistics.shared.recordShown() }
        if let caretRect = inlineCaret {
            // Match the field's real font when available; fall back to a caret-height guess.
            let element = AccessibilityBridge.focusedElement()
            let caret = element.flatMap { AccessibilityBridge.caretOffset(of: $0) } ?? 0
            let axFont = element.flatMap { AccessibilityBridge.fontAtCaret(of: $0, caret: caret) }
            let base = axFont ?? NSFont.systemFont(ofSize: max(11, caretRect.height * policy.fontSizeRatio))
            let font = NSFont(descriptor: base.fontDescriptor,
                              size: base.pointSize * policy.fontFactor) ?? base
            let anchored = caretRect.offsetBy(dx: 0, dy: policy.verticalOffset)
            Log.shared.debug("placement app=\(AccessibilityBridge.frontmostBundleId() ?? "?") caretRect=\(caretRect) axFont=\(axFont != nil ? "yes(\(axFont!.pointSize)pt)" : "no, using \(base.pointSize)pt heuristic") fontFactor=\(policy.fontFactor) verticalOffset=\(policy.verticalOffset) anchored=\(anchored)")
            // Screenshot-assisted colour so ghost text blends with the field's text.
            var color: NSColor?
            if settings.useScreenshotAppearance {
                GhostAppearanceProbe.shared.refresh(caretRect: caretRect)
                color = GhostAppearanceProbe.shared.current?.ghostColor
            }
            // Mid-line (text follows the caret): an inline ghost would paint over
            // that text — show a bubble just above the caret instead (Sombra-style).
            // Only POSITIVE evidence of caret-at-end allows inline rendering; an
            // unreadable field (Electron) counts as mid-line, never inline-wrap.
            // Wrap mode only in native apps: in Electron the attributed first-line
            // indent renders at the wrong x (observed "system" drawn ~54pt left of
            // the indent target), while the plain single-line path places exactly
            // at the caret. Single-line + tail truncation is also what Cotypist
            // shows in these apps.
            let caretAtEnd = element.map(AccessibilityBridge.caretConfirmedAtEnd) == true
            let fieldRect = (allowWrap && caretAtEnd && !policy.laggyCaret)
                ? element.flatMap { AccessibilityBridge.elementFrame(of: $0) } : nil
            // Clamp the ghost to the text INPUT BOX's right edge, not just the
            // window's — composers are narrower than their windows, and a ghost
            // clamped only to the window spills past the box.
            let elementFrame = element.flatMap { AccessibilityBridge.elementFrame(of: $0) }
            let boxRight: CGFloat? = {
                var limit = windowRect.map { $0.maxX - 8 }
                if let f = elementFrame, f.width >= 60, f.width <= 2400,
                   f.insetBy(dx: -8, dy: -8).contains(CGPoint(x: anchored.midX, y: anchored.midY)) {
                    limit = min(limit ?? f.maxX - 6, f.maxX - 6)
                }
                return limit
            }()

            // Paint at a SPECIFIC caret rect and font — the occupancy retry must
            // render at the position it verified, and the ink-band probe may have
            // refined the vertical position/size from the real glyph pixels.
            let paint: (CGRect, NSFont) -> Void = { [weak self] rect, useFont in
                guard let self else { return }
                let shown = self.overlay.showInline(
                    text: suggestion, at: rect, font: useFont,
                    opacity: self.settings.ghostOpacity, color: color,
                    maxRightX: boxRight,
                    fieldRect: fieldRect)
                if !shown {
                    // No room for even a couple of characters inline — HUD pill.
                    self.overlay.showHUD(text: suggestion, windowRect: windowRect)
                }
            }

            guard isNewSuggestion else { paint(anchored, font); return }

            // Final occupancy check: AX caret geometry sometimes lies (stale
            // selection index, wrong y on wrapped lines in Electron) — before
            // painting inline, look at the actual PIXELS where the ghost would go.
            // Occupied → retry once at a freshly-read caret; still occupied → drop
            // this cycle (never paint over text). Unknown → trust AX.
            overlay.hide()   // our own previous ghost must not trip the check
            let hasAXFont = axFont != nil
            Task { [weak self] in
                guard let self else { return }
                // Stop the strip well short of the input box's right edge — trailing
                // controls (send buttons, icons) live there and read as "occupied".
                func stripRight(of rect: CGRect) -> CGRect? {
                    var width: CGFloat = 120
                    if let boxRight { width = min(width, boxRight - 40 - (rect.maxX + 2)) }
                    guard width >= 24 else { return nil }   // too cramped to judge — trust AX
                    return CGRect(x: rect.maxX + 2, y: rect.minY + 2,
                                  width: width, height: max(rect.height - 4, 6))
                }
                func checkOccupied(_ rect: CGRect) async -> Bool? {
                    guard let strip = stripRight(of: rect) else { return nil }
                    return await GhostAppearanceProbe.hasTextPixels(in: strip)
                }
                var target = anchored
                var occupied = await checkOccupied(target)
                guard self.currentSuggestion == suggestion else { return }   // stale
                if occupied == true {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard self.currentSuggestion == suggestion else { return }
                    // Re-read the caret — the bounds may have settled by now — and
                    // both CHECK and PAINT at that fresh position.
                    target = (AccessibilityBridge.focusedElement()
                        .flatMap { AccessibilityBridge.caretRect(of: $0) } ?? anchored)
                        .offsetBy(dx: 0, dy: policy.verticalOffset)
                    occupied = await checkOccupied(target)
                    guard self.currentSuggestion == suggestion else { return }
                    if occupied == true {
                        // Never paint a ghost over real pixels — but a generated,
                        // filtered, fresh suggestion should not die silently either
                        // (dark Electron input bars sit right at the contrast
                        // threshold and used to eat every suggestion this way).
                        // The HUD pill is anchored to the window, not the caret,
                        // so it can't overlap the text.
                        Log.shared.debug("placement: strip still occupied — showing HUD pill instead")
                        Statistics.shared.record(.occupiedFallback)
                        self.overlay.showHUD(text: suggestion, windowRect: windowRect)
                        return
                    }
                }

                // Pixel-true vertical alignment + size: sample the REAL text's ink
                // band just left of the caret and match the ghost to it — the AX
                // line box's padding varies per app, centering in it is a guess.
                var useFont = font
                var rect = target
                var probedBaseline: CGFloat?
                let leftStrip = CGRect(x: max(0, target.minX - 180), y: target.minY - 3,
                                       width: min(170, target.minX), height: target.height + 6)
                if let band = await GhostAppearanceProbe.inkBand(in: leftStrip) {
                    guard self.currentSuggestion == suggestion else { return }
                    let bandHeight = band.bottom - band.top
                    // A band taller than the caret's line box means the strip caught
                    // more than one line of text (or an icon) — distrust it entirely.
                    if bandHeight >= 6, bandHeight <= target.height + 2 {
                        if !hasAXFont {
                            // Baseline-to-ascent span ≈ 0.78 × point size for typical
                            // text (caps/tall letters present in a 170pt strip).
                            let ascentSpan = band.baseline - band.top
                            if ascentSpan >= 5 {
                                let size = min(max(ascentSpan * 1.28, 9), target.height * 0.95)
                                useFont = NSFont(descriptor: font.fontDescriptor, size: size) ?? font
                            }
                        }
                        // BASELINE-to-BASELINE alignment — the only anchor that's
                        // independent of which glyphs each text happens to contain
                        // (ink tops/bottoms shift with letter shapes; baselines don't).
                        // The label's baseline sits `ascender` below its line-box top,
                        // and showInline centers that box in `rect`:
                        //   baseline = rect.minY + (rect.height - lineBox)/2 + ascender
                        let lineBox = useFont.ascender + abs(useFont.descender) + useFont.leading
                        let y = band.baseline - useFont.ascender - (target.height - lineBox) / 2
                        rect = CGRect(x: target.minX, y: y,
                                      width: target.width, height: target.height)
                        probedBaseline = band.baseline
                        Log.shared.debug("placement: baseline \(String(format: "%.1f", band.baseline)) band \(String(format: "%.0f-%.0f", band.top, band.bottom)) -> font \(String(format: "%.1f", useFont.pointSize))pt")
                    }
                }

                // Text mirror (Cotypist's rendering): re-render the typed tail +
                // suggestion ourselves on a field-matched backdrop — exact tail/ghost
                // alignment by construction. Needs the probed baseline + colours.
                if policy.laggyCaret, self.settings.textMirroring,
                   let baseline = probedBaseline,
                   let appearance = GhostAppearanceProbe.shared.current {
                    let before = AccessibilityBridge.focusedElement()
                        .flatMap { AccessibilityBridge.textBeforeCaret(of: $0, maxChars: 40) } ?? ""
                    var tail = ""
                    if let lastToken = before.split(whereSeparator: { $0 == " " || $0 == "\n" }).last,
                       !before.hasSuffix(" "), !before.hasSuffix("\n") {
                        tail = String(lastToken.suffix(24))
                    }
                    Log.shared.debug("placement: mirror tail=\"\(tail)\"")
                    self.overlay.showMirror(
                        typedTail: tail, suggestion: suggestion, caretRect: rect,
                        baseline: baseline, font: useFont,
                        textColor: appearance.textColor,
                        backgroundColor: appearance.backgroundColor,
                        ghostOpacity: self.settings.ghostOpacity,
                        maxRightX: boxRight)
                    return
                }
                paint(rect, useFont)
            }
        } else {
            overlay.showHUD(text: suggestion, windowRect: windowRect)
        }
    }

    // MARK: - Accept / dismiss

    /// Accept the current inline command or LLM suggestion. Returns true if something
    /// was accepted (so the key is swallowed). `whole` = accept the entire suggestion.
    private func acceptCurrent(whole: Bool) -> Bool {
        // Inline command (emoji/macro) takes priority over LLM suggestions.
        if inlineCommand.isActive {
            if let (deleteCount, insert) = inlineCommand.accept() {
                buffer = String(buffer.dropLast(deleteCount)) + insert
                DispatchQueue.main.async {
                    TextInserter.backspace(count: deleteCount)
                    TextInserter.insert(insert, strategy: .keystroke)
                }
                return true
            }
            inlineCommand.cancel()
            return false
        }

        guard let suggestion = currentSuggestion, !suggestion.isEmpty else { return false }

        let toInsert: String
        let remainder: String
        if whole {
            toInsert = suggestion
            remainder = ""
        } else {
            var split = TextInserter.firstWord(of: suggestion)
            var accepted = split.accepted
            var rest = split.remainder
            // Optionally hold back trailing punctuation (…"word?" → "word" + "?").
            if !settings.includeTrailingPunctuation {
                var trimmed = accepted
                while let last = trimmed.last, last.isPunctuation || last == "?" || last == "!" {
                    rest = String(last) + rest
                    trimmed.removeLast()
                }
                if !trimmed.isEmpty { accepted = trimmed }
            }
            // Optionally hold back the trailing space.
            if !settings.includeTrailingSpace, accepted.hasSuffix(" ") {
                accepted.removeLast()
                rest = " " + rest
            }
            toInsert = accepted
            remainder = rest
            _ = split
        }

        overlay.hide()
        currentSuggestion = remainder.isEmpty ? nil : remainder
        protectingRemainder = !remainder.isEmpty
        if protectingRemainder {
            // Tear down the prediction machinery armed by earlier real keystrokes,
            // or it fires on the just-inserted word and replaces the remainder:
            // the host-publish poll (scheduleToken), the debounce, and any
            // in-flight generation whose stale result would re-kick.
            debounceWork?.cancel()
            scheduleToken += 1
            router.cancelInFlight()
        }
        buffer += toInsert
        let strategy = AppPolicyStore.policy(forBundleId: AccessibilityBridge.frontmostBundleId())
            .insertionStrategy
        let wordCount = toInsert.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        Statistics.shared.recordAccepted(wordCount: max(wordCount, toInsert.isEmpty ? 0 : 1))
        if settings.collectTypingHistory {
            TypingHistoryStore.shared.record(toInsert)
            // Prefix+accepted pair → personal few-shot examples; the accepted text
            // also feeds the phrase memory (buffer already includes toInsert).
            TypingHistoryStore.shared.recordAccept(
                prefixTail: String(buffer.dropLast(toInsert.count).suffix(80)),
                accepted: toInsert)
            PhraseMemory.shared.ingest(String(buffer.suffix(160)))
        }

        // Snapshot the pre-insertion field length so the speculative re-prediction
        // below can wait until the WHOLE insert has landed in the AX tree —
        // predicting on pre-insertion text regenerates the suggestion just accepted.
        let baselineLen = AccessibilityBridge.focusedElement()
            .flatMap { AccessibilityBridge.stringValue(of: $0)?.count }
        lastAcceptedText = toInsert
        lastAcceptedAt = Date()

        // Insert on the next tick so we return from the tap callback first.
        DispatchQueue.main.async {
            // Synthesized keystrokes are invisible to the tap (injected marker), so
            // stamp the keystroke clock manually — the settle gate must treat the
            // insertion like typing, or the remainder ghost paints at the
            // pre-insert caret and overlaps the inserted text.
            self.lastKeystrokeAt = Date()
            TextInserter.insert(toInsert, strategy: strategy)
            if remainder.isEmpty {
                // Suggestion exhausted — speculatively fetch the next continuation so it
                // appears sooner than waiting for the next keystroke's debounce.
                guard self.currentSuggestion == nil else { return }
                self.hostBaselineLen = baselineLen
                self.hostExpectedLen = baselineLen.map { $0 + toInsert.count }
                self.schedulePrediction()
                return
            }
            // The synthesized keystrokes are processed by the target app slightly
            // after we post them — the settle gate re-reads the caret only after
            // things quiet down, so the remaining ghost lands at the new position.
            self.presentWhenSettled(suggestion: remainder, isNewSuggestion: false)
        }
        return true
    }

    /// Clipboard is context only for a short while after copying — stale contents
    /// (copied minutes/hours ago) are noise, not signal. Also skips non-prose
    /// content (logs, timestamps, hex dumps) via a letter-ratio gate.
    private func freshClipboardText() -> String {
        let pb = NSPasteboard.general
        if pb.changeCount != clipboardChangeCount {
            clipboardChangeCount = pb.changeCount
            clipboardFirstSeen = Date()
        }
        guard Date().timeIntervalSince(clipboardFirstSeen) < 120 else { return "" }
        let text = String((pb.string(forType: .string) ?? "").prefix(300))
        guard !text.isEmpty else { return "" }
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard Double(letters) / Double(text.count) >= 0.6 else { return "" }
        return text
    }

    private func updateAccessoryButton() {
        let bundleId = AccessibilityBridge.frontmostBundleId()
        let policy = AppPolicyStore.policy(forBundleId: bundleId)
        guard settings.showAccessoryButton,
              let element = AccessibilityBridge.focusedElement(),
              AccessibilityBridge.isTextInput(element),   // not a button/link/web area
              allowedByChatPanelPolicy(policy, element: element, bundleId: bundleId),
              let windowRect = ContextReader.windowRect(of: element) else {
            accessory.hide(); return
        }
        accessory.show(near: windowRect)
    }

    private func clearSuggestion() {
        debounceWork?.cancel()
        scheduleToken += 1   // invalidate any in-flight host-publish poll
        router.cancelInFlight()
        protectingRemainder = false
        currentSuggestion = nil
        hostExpectedLen = nil
        alternatives.hide()
        overlay.hide()
    }
}
