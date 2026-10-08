import AppKit
import TabTypeKit
import ApplicationServices
import Combine

/// Central orchestrator: wires keystrokes → context → prediction → ghost-text
/// overlay → Tab-to-accept. Runs entirely on the main actor (the event tap is
/// serviced on the main run loop).
@MainActor
final class Engine {
    private let settings: AppSettings
    private let router: EngineRouter
    private let monitor = KeystrokeMonitor()
    private let overlay = SuggestionOverlay()
    /// Per field (see `fitKey` in `present`): measured correction from the AX-styled
    /// baseline estimate to the real text's baseline, in points.
    private var baselineAdjust: [String: CGFloat] = [:]
    /// Per field: font family measured from the screen when AX reports only the
    /// size (Chromium), and the fields already tried.
    private var fieldFamily: [String: String] = [:]
    private var familyTried: Set<String> = []
    private let inlineCommand: InlineCommandController
    private let accessory = AccessoryButton()
    private let alternatives = AlternativesController()
    /// The last non-speculative request, kept for word-alternatives regeneration.
    private var lastReq: CompletionRequest?

    /// Fallback context buffer, used when the Accessibility API can't provide the
    /// focused field's text. Rebuilt on focus change.
    private var buffer = ""
    /// The ghost suggestion's lifecycle (type-through, Tab remainders, stale and
    /// repeated results) — see `SuggestionSession`.
    private var session = SuggestionSession()
    private var currentSuggestion: String? { session.text }
    /// What comes AFTER the suggestion on screen, computed in the background while
    /// it's shown: Tab through the last word and the next words appear at once,
    /// with no wait for the app to publish the insert (Cotypist's "prewarm").
    private var lookahead: Lookahead?
    private struct Lookahead {
        /// The suggestion it continues, and the field text once that's accepted.
        var after: String
        var input: String
        var request: CompletionRequest
        /// nil while computing; "" when the model had nothing confident.
        var text: String?
    }
    private var debounceWork: DispatchWorkItem?
    private var lastFocusedPID: pid_t = 0
    private var lastPredictedPrompt: String = ""
    private(set) var pausedUntil: Date?
    private var scheduleToken = 0
    /// AX text length captured at keydown (before the app processes the key), so we
    /// can poll until the keystroke actually lands in the field ("host publish").
    private var hostBaselineLen: Int?
    /// Text length read in the tap for the edit being handled.
    private var pendingBaselineLen: Int?
    /// When set (after accepting a suggestion), `hostPublished()` waits for the field
    /// to reach at least this length — synthesized multi-char inserts land
    /// incrementally, and predicting on a half-landed insert regenerates stale text.
    private var hostExpectedLen: Int?
    /// When the user last typed — presentation waits for a pause (see
    /// `presentWhenSettled`), because Electron caret bounds lag during bursts.
    private var lastKeystrokeAt = Date.distantPast
    /// Caret rect read just before the latest keystroke reached the app.
    private var caretAnchor: CGRect?
    /// TabType's own copy of the text before the caret, with keystrokes applied
    /// as they're typed (Cotypist's pending edits): predictions start from it at
    /// once instead of waiting for the app to publish each keystroke over AX.
    /// `axBaseline` is the last text the app itself reported; while AX still
    /// shows it, the app is lagging and the local copy is the truth. Any other
    /// AX text means the app caught up — or changed something (autocorrect, an
    /// input method) — and replaces the copy.
    private var expectedInput: String?
    private var axBaseline: String?
    private var expectedLimit = AppSettings.inputContextChars

    /// Notifications from the focused field; a pending placement re-checks the
    /// caret the moment one arrives (polling stays as the backstop).
    private var fieldObserver: AXFieldObserver?
    private var pendingPlacement: (() -> Void)?
    /// Screen/transcript capture scheduled for the next typing pause.
    private var pauseCapture: DispatchWorkItem?
    /// The generation running now (not lookaheads), and whether newer typing is
    /// waiting on it: a keystroke that only EXTENDS its input lets it finish and
    /// splices its result instead of cancelling ~90ms of work (Cotypist's
    /// in-flight decode deferral).
    private var inFlight: (input: String, id: Int)?
    private var inFlightCounter = 0
    private var deferredWhileInFlight = false
    /// One-shot flag so the disabled state is logged once, not per keystroke.
    private var loggedDisabled = false
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
    private var lastAXInput: (bundleId: String, text: String, windowTitle: String)?

    /// Whether to learn from writing in `bundleId`: the per-app choice, else the
    /// global "learn from my writing" setting.
    private func learnsFromWriting(_ bundleId: String) -> Bool {
        AppPolicyStore.userOverrides[bundleId]?.learnFromWriting ?? settings.collectTypingHistory
    }

    /// Keep the text written in the field being left (a draft, email, note…).
    private func recordFieldWriting() {
        guard let ax = lastAXInput, learnsFromWriting(ax.bundleId) else { return }
        WritingStore.shared.record(ax.text, bundleId: ax.bundleId, fieldKey: ax.windowTitle, kind: .field)
    }

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
        if learnsFromWriting(bundleId) {
            WritingStore.shared.record(text, bundleId: bundleId, fieldKey: nil, kind: .message)
        }
        var list = recentInputs[bundleId] ?? []
        if list.last != text {
            list.append(SecretSanitizer.sanitize(String(text.suffix(300))))
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
    /// Scrolling moves the text under a ghost: hide it, re-place once scrolling stops.
    private var scrollMonitor: Any?
    private var scrollSettle: DispatchWorkItem?
    /// `allowWrap` of the suggestion on screen, for re-placing it.
    private var shownAllowWrap = false
    private var accessoryToggleObserver: AnyCancellable?
    /// AX focused-element observer for the frontmost app (recreated on app switch).
    private var focusObserver: AXFocusObserver?

    /// Pasteboard freshness tracking for clipboard context (see `freshClipboardText`).
    private var clipboardChangeCount = -1
    private var clipboardFirstSeen = Date.distantPast

    private(set) var isRunning = false

    init(settings: AppSettings = .shared) {
        self.settings = settings
        self.router = EngineRouter()
        self.inlineCommand = InlineCommandController(settings: settings)
    }

    /// Start monitoring. Returns false if the event tap couldn't be created
    /// (usually missing Accessibility permission).
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        // A hung app must not stall typing: cap every AX call (Cotypist does too).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        wireCallbacks()
        guard monitor.start() else { return false }
        installDismissObservers()
        installFreshContextRekick()
        // Whatever is on the pasteboard at launch predates this session — treat it
        // as stale so it never enters a prompt (only copies made from now on do).
        clipboardChangeCount = NSPasteboard.general.changeCount
        clipboardFirstSeen = .distantPast
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
            guard !self.session.isProtectingRemainder else { return }
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
                self.recordFieldWriting()
                self.lastAXInput = nil
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
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) { _ in
            MainActor.assumeIsolated {
                guard let suggestion = self.currentSuggestion else { return }
                self.overlay.hide()
                self.scrollSettle?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.currentSuggestion == suggestion else { return }
                    self.presentWhenSettled(suggestion: suggestion, isNewSuggestion: false,
                                            allowWrap: self.shownAllowWrap, minSettle: 0)
                }
                self.scrollSettle = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            }
        }
        // A click that moves the caret or focus makes the ghost stale — but clicks
        // that touch neither (e.g. the ⌘⇧4 screenshot crosshair) must NOT dismiss.
        // So verify the click's consequence instead of assuming it.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { _ in
            MainActor.assumeIsolated {
                let hadSuggestion = self.currentSuggestion != nil
                self.dropPendingEdits()   // a click can move the caret
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
                self.dropPendingEdits()
                self.recordFieldWriting()
                self.lastAXInput = nil
                self.buffer = ""
                self.lastPredictedPrompt = ""
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
            var req = CompletionRequest(
                beforeCursor: "Hello", afterCursor: "",
                screenContext: screen,
                clipboard: self.settings.useClipboardContext ? self.freshClipboardText() : "",
                speculative: true, maxWords: 1, warmUpOnly: true)
            req.screenIsConversation = policy.transcriptViaAX
            self.applyWriterContext(&req, appName: NSWorkspace.shared.frontmostApplication?.localizedName,
                                    policy: policy)
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
        // A selected word: offer words that fit in its place instead.
        let llama = router.current
        if let element = AccessibilityBridge.focusedElement(),
           let selection = AccessibilityBridge.selection(of: element) {
            let word = selection.selected.trimmingCharacters(in: .whitespacesAndNewlines)
            if !word.isEmpty, !word.contains("\n"), word.split(separator: " ").count <= 3 {
                showSynonyms(for: word, before: selection.before, after: selection.after, llama: llama,
                             caretRect: AccessibilityBridge.caretRect(of: element))
                return
            }
        }
        alternativesReplaceSelection = false
        let caretRect = AccessibilityBridge.focusedElement()
            .flatMap { AccessibilityBridge.caretRect(of: $0) }
        var initial: [String] = []
        if let suggestion = currentSuggestion,
           let first = suggestion.split(whereSeparator: { $0 == " " || $0 == "\n" }).first {
            initial.append(String(first))
        }
        if let result = router.current.lastResult {
            // The decoder's runner-up first words, already scored against the context.
            initial += result.alternatives.map { $0.text.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !initial.contains($0) }
        }
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
    }

    /// The open picker lists replacements for the selection (synonym mode), not
    /// next words.
    private var alternativesReplaceSelection = false

    /// Synonym mode: words the model finds fitting in place of the selection.
    private func showSynonyms(for word: String, before: String, after: String, llama: LlamaEngine,
                              caretRect: CGRect?) {
        let base = lastReq
        Task { [weak self] in
            let words = await llama.synonyms(for: word, before: before, after: after, base: base)
            guard let self else { return }
            guard !words.isEmpty else {
                Log.shared.debug("synonyms: none for \"\(word)\"")
                return
            }
            Log.shared.debug("synonyms for \"\(word)\": \(words.joined(separator: ", "))")
            self.alternativesReplaceSelection = true
            self.alternatives.show(candidates: words, caretRect: caretRect)
        }
    }

    /// Replace the selected text with a picked synonym (typing over a selection
    /// replaces it natively).
    private func replaceSelection(with word: String) {
        alternatives.hide()
        alternativesReplaceSelection = false
        let strategy = AppPolicyStore.policy(forBundleId: AccessibilityBridge.frontmostBundleId())
            .insertionStrategy
        DispatchQueue.main.async {
            self.markEdit()
            self.dropPendingEdits()   // text changed other than by typing
            TextInserter.insert(word, strategy: strategy)
        }
    }

    /// Insert a chosen alternative word (accept-word bookkeeping included).
    private func insertAlternative(_ word: String) {
        alternatives.hide()
        overlay.hide()
        session.clear()
        let toInsert = word + (settings.includeTrailingSpace ? " " : "")
        buffer += toInsert
        Statistics.shared.recordAccepted(wordCount: 1)
        let strategy = AppPolicyStore.policy(forBundleId: AccessibilityBridge.frontmostBundleId())
            .insertionStrategy
        let baselineLen = AccessibilityBridge.focusedElement()
            .flatMap { AccessibilityBridge.textLength(of: $0) }
        DispatchQueue.main.async {
            self.markEdit()
            self.dropPendingEdits()   // text changed other than by typing
            TextInserter.insert(toInsert, strategy: strategy)
            self.hostBaselineLen = baselineLen
            self.hostExpectedLen = baselineLen.map { $0 + toInsert.utf16.count }
            self.schedulePrediction()
        }
    }

    /// Warm the model's KV prefix cache with the static prompt head (system prompt
    /// + chat template + persona) so the first real suggestion skips that prefill.
    func warmUpModel() {
        var req = CompletionRequest(beforeCursor: "Hello", afterCursor: "", screenContext: "",
                                    speculative: true, maxWords: 1, warmUpOnly: true)
        applyWriterContext(&req, appName: nil, policy: AppPolicyStore.policy(forBundleId: nil))
        Task { [weak self] in
            guard let self else { return }
            let start = Date()
            _ = await self.router.current.complete(req)
            Log.shared.info("model warm-up finished in \(Int(Date().timeIntervalSince(start) * 1000))ms — static prompt prefix cached")
        }
    }

    /// Writer identity and instructions for the v2 prompt assembler, which frames
    /// them itself instead of using v1's pre-rendered `persona`.
    private func applyWriterContext(_ req: inout CompletionRequest, appName: String?, policy: AppPolicy) {
        req.appName = appName ?? ""
        req.authorName = settings.authorName.trimmingCharacters(in: .whitespaces)
        let style = settings.writingStyle.trimmingCharacters(in: .whitespaces)
        req.customInstructions = [style.isEmpty ? "" : "Writing style: \(style).",
                                  settings.customInstructions, policy.customInstructions]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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

    /// Pause suggestions in the frontmost app for `minutes`.
    func pauseFrontmostApp(minutes: Int) {
        guard let bid = AccessibilityBridge.frontmostBundleId() else { return }
        pausedApps[bid] = Date().addingTimeInterval(TimeInterval(minutes * 60))
        clearSuggestion()
        Log.shared.info("suggestions paused \(minutes) min in \(bid)")
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
        if let scrollMonitor {
            NSEvent.removeMonitor(scrollMonitor)
            self.scrollMonitor = nil
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
        // The tap holds the key until it returns: read only what must be read
        // BEFORE the app sees the key, then let it through and do the rest.
        monitor.onEdit = { chars, isDeletion, _ in
            MainActor.assumeIsolated {
                self.beforeEditDelivered()
                DispatchQueue.main.async { self.handleEdit(chars: chars, isDeletion: isDeletion) }
            }
        }
        monitor.handleControlKey = { keyCode, flags in
            MainActor.assumeIsolated { self.handleControlKey(keyCode: keyCode, flags: flags) }
        }
    }

    /// Map a keydown against configured shortcut bindings and navigation keys.
    private func handleControlKey(keyCode: Int64, flags: CGEventFlags) -> ControlDecision {
        // Word-alternatives panel intercepts digits/Escape while open.
        if alternatives.isActive {
            let digitKeys: [Int64: Int] = [18: 1, 19: 2, 20: 3, 21: 4]   // 1-4 row keys
            if let index = digitKeys[keyCode], let word = alternatives.candidate(at: index) {
                if alternativesReplaceSelection {
                    replaceSelection(with: word)
                } else {
                    insertAlternative(word)
                }
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
            return acceptCurrent(whole: false) ? .swallow : .passthrough
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
            dropPendingEdits()   // the caret moves, or the message is sent
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

    /// An edit is about to reach the field (a keystroke the tap sees first, or text
    /// we insert): stamp the clock and remember the caret BEFORE it lands —
    /// presentation knows the field has caught up once the caret leaves it.
    private func markEdit() {
        lastKeystrokeAt = Date()
        caretAnchor = AccessibilityBridge.focusedElement().flatMap { AccessibilityBridge.caretRect(of: $0) }
    }

    /// In the tap, before the key reaches the app: the clock, the caret and the
    /// text length as they are BEFORE the edit.
    private func beforeEditDelivered() {
        let element = AccessibilityBridge.focusedElement()
        lastKeystrokeAt = Date()
        caretAnchor = element.flatMap { AccessibilityBridge.caretRect(of: $0) }
        pendingBaselineLen = element.flatMap { AccessibilityBridge.textLength(of: $0) }
    }

    private func handleEdit(chars: String, isDeletion: Bool) {
        // Freeze screen captures while typing (see ScreenContextProvider), and
        // capture once the typing pauses — otherwise a long message keeps the
        // context from before it started.
        ScreenContextProvider.shared.lastEditAt = lastKeystrokeAt
        pauseCapture?.cancel()
        let capture = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let policy = AppPolicyStore.policy(forBundleId: AccessibilityBridge.frontmostBundleId(),
                                               host: AccessibilityBridge.frontmostURLHost())
            if (self.settings.useScreenContext || policy.forceScreenContext) && policy.includesScreenContext
                && !PowerMonitor.shared.shouldPauseCapture {
                ScreenContextProvider.shared.refreshIfStale()
            }
        }
        pauseCapture = capture
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: capture)
        // Track focus changes to reset the fallback buffer and enable enhanced
        // accessibility for Electron/Chromium apps (Slack, VS Code, browsers…).
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        if pid != lastFocusedPID {
            lastFocusedPID = pid
            buffer = ""
            dropPendingEdits()
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

        applyPendingEdit(chars: chars, isDeletion: isDeletion)

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
            session.clear()
            debounceWork?.cancel()
            return
        }

        // Type-through: when the user types exactly what the ghost predicts, keep
        // the suggestion and shrink it in place instead of killing and regenerating
        // it — stable, instant, and zero model calls for matching keystrokes.
        if !isDeletion, currentSuggestion != nil, let remainder = session.typeThrough(chars) {
            // Move the ghost past the typed characters right away (their width in
            // the field's font); the settled caret then confirms the position.
            if !overlay.advance(typed: chars, remainder: remainder) { overlay.hide() }
            presentWhenSettled(suggestion: remainder, isNewSuggestion: false, allowWrap: shownAllowWrap)
            return
        }

        // Any other edit invalidates the shown suggestion. Typing (not deleting)
        // keeps a running generation alive for splicing.
        clearSuggestion(keepGeneration: !isDeletion)

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

        // The pre-keystroke text length, read in the tap (see `beforeEditDelivered`).
        // We poll until it changes.
        hostBaselineLen = pendingBaselineLen

        schedulePrediction()
    }

    /// The Cotypist presentation rule (observed live): NEVER paint a ghost while
    /// keys are streaming — Electron caret bounds lag ~0.3-0.5s during a burst, so
    /// mid-burst placement lands on stale coordinates and overlaps typed text.
    /// Waits until the typing has paused for the app's settle delay, re-reads the
    /// caret THEN, and presents. A newer keystroke re-arms the wait; a changed
    /// suggestion aborts it.
    private func presentWhenSettled(suggestion: String, isNewSuggestion: Bool,
                                    allowWrap: Bool = false, minSettle: TimeInterval? = nil,
                                    earlyOnCaretMove: Bool = true) {
        // A remainder being Tabbed through is protected — a NEW suggestion must
        // never steal its display slot (re-presents of the remainder itself come
        // through with isNewSuggestion: false).
        // Register immediately: any keystroke during the wait clears/replaces it
        // (clearSuggestion / type-through), aborting the scheduled presentation.
        guard session.register(suggestion, isNew: isNewSuggestion) else {
            Statistics.shared.record(.heldForRemainder)
            return
        }
        let policy = AppPolicyStore.policy(forBundleId: AccessibilityBridge.frontmostBundleId())
        // Electron bounds lag ~0.3s after the last keystroke; 0.4s matches the
        // observed Cotypist timing, with the occupancy/ink-band guards as backstop.
        // The settle time is a DEADLINE, not a wait: the caret is ready as soon as
        // it has left where it was before the last keystroke (native apps: one
        // read; Electron, whose bounds trail the text: two matching reads).
        let deadline: TimeInterval = minSettle ?? (policy.laggyCaret ? 0.4 : 0.12)
        let keystrokeAt = lastKeystrokeAt
        var previous: CGRect?
        var placed = false
        observeFocusedField()

        func attempt() {
            guard !placed, currentSuggestion == suggestion, keystrokeAt == lastKeystrokeAt else { return }
            let element = AccessibilityBridge.focusedElement()
            let caretRect = element.flatMap { AccessibilityBridge.caretRect(of: $0) }
            let elapsed = Date().timeIntervalSince(keystrokeAt)
            var ready = elapsed >= deadline
            if !ready, earlyOnCaretMove, let caretRect, let anchor = caretAnchor,
               Self.caretMoved(caretRect, from: anchor) {
                ready = !policy.laggyCaret || previous.map { Self.sameCaret($0, caretRect) } == true
                previous = caretRect
            }
            guard ready else {
                pendingPlacement = attempt
                DispatchQueue.main.asyncAfter(deadline: .now() + min(0.016, max(0.001, deadline - elapsed))) {
                    attempt()
                }
                return
            }
            placed = true
            pendingPlacement = nil
            let windowRect = element.flatMap { ContextReader.windowRect(of: $0) }
            present(suggestion: suggestion, inlineCaret: caretRect, windowRect: windowRect,
                    policy: policy, isNewSuggestion: isNewSuggestion, allowWrap: allowWrap)
        }
        attempt()
    }

    /// Apply a keystroke to the local copy of the field (see `expectedInput`).
    private func applyPendingEdit(chars: String, isDeletion: Bool) {
        guard var text = expectedInput else { return }
        if isDeletion {
            guard !text.isEmpty else { expectedInput = nil; return }
            text.removeLast()
        } else {
            // Only plain text keeps the copy exact; anything else re-reads AX.
            guard !chars.isEmpty, chars.allSatisfy({ !$0.isNewline || $0 == "\n" }),
                  !chars.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" })
            else { expectedInput = nil; return }
            text += chars.replacingOccurrences(of: "\r", with: "\n")
            if text.count > expectedLimit { text = String(text.suffix(expectedLimit)) }
        }
        expectedInput = text
    }

    /// The text before the caret as it is now: the app's AX text, unless the
    /// app is still showing what it showed before our pending keystrokes.
    private func reconcile(axInput: String) -> String {
        guard let expected = expectedInput, let baseline = axBaseline else {
            expectedInput = axInput
            axBaseline = axInput
            return axInput
        }
        if axInput == baseline, expected != baseline { return expected }   // app lagging
        // Partly caught up (two keys typed, one shown): still behind the copy.
        if axInput != expected, expected.hasPrefix(axInput), axInput.hasPrefix(baseline) {
            axBaseline = axInput
            return expected
        }
        if axInput != expected {
            Log.shared.debug("pending edits: field differs from the local copy — re-reading it")
        }
        expectedInput = axInput
        axBaseline = axInput
        return axInput
    }

    /// Forget the local copy (focus/caret moved, text changed elsewhere).
    private func dropPendingEdits() {
        expectedInput = nil
        axBaseline = nil
    }

    /// Watch the focused field's own notifications (re-created when focus moves).
    private func observeFocusedField() {
        guard let element = AccessibilityBridge.focusedElement() else { fieldObserver = nil; return }
        if let current = fieldObserver, CFEqual(current.element, element) { return }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        fieldObserver = AXFieldObserver(pid: pid, element: element) { [weak self] in
            MainActor.assumeIsolated { self?.pendingPlacement?() }
        }
    }

    /// The caret has left `anchor` (a typed or deleted character moved it).
    nonisolated static func caretMoved(_ caret: CGRect, from anchor: CGRect) -> Bool {
        abs(caret.maxX - anchor.maxX) >= 0.5 || abs(caret.minY - anchor.minY) >= 0.5
    }

    nonisolated static func sameCaret(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.maxX - b.maxX) < 0.5 && abs(a.minY - b.minY) < 0.5 && abs(a.height - b.height) < 0.5
    }

    /// Wait for the keystroke to appear in the AX tree (host-publish), then predict.
    /// Polls on the main run loop without blocking; a token cancels stale schedules.
    private func schedulePrediction() {
        debounceWork?.cancel()
        scheduleToken += 1
        let token = scheduleToken
        let start = Date()

        func poll(_ delay: Double) {
            let work = DispatchWorkItem { [weak self] in
                guard let self, token == self.scheduleToken else { return }
                let elapsed = Date().timeIntervalSince(start)
                // With a local copy of the field, there's nothing to wait for.
                if self.expectedInput != nil || self.hostPublished() || elapsed > 0.4 {
                    self.runPrediction()
                } else {
                    poll(0.025)
                }
            }
            debounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        // Every app predicts as soon as the keystroke lands in the field: a newer
        // keystroke cancels the generation in flight (the engine's request gate),
        // so mid-burst requests never queue up behind each other, and the
        // stale-result guard drops anything the field has moved past.
        poll(0.02)
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
            self.dropPendingEdits()   // text changed other than by typing
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
            self.dropPendingEdits()   // text changed other than by typing
            TextInserter.backspace(count: deleteCount)
            TextInserter.insert(corrected + boundary, strategy: .keystroke)
            Log.shared.debug("autocorrect: \(wordStr) -> \(corrected)")
        }
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
              let len = AccessibilityBridge.textLength(of: element) else {
            return true
        }
        // After a Tab-accept, synthesized multi-char inserts land incrementally —
        // wait for the whole insert, not just the first character.
        if let expected = hostExpectedLen { return len >= expected }
        return len != baseline
    }

    private func runPrediction() {
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
        if session.isProtectingRemainder {
            let fieldText = AccessibilityBridge.focusedElement()
                .flatMap { AccessibilityBridge.stringValue(of: $0) } ?? ""
            if fieldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clearSuggestion()
            } else {
                Statistics.shared.record(.heldForRemainder)
                return
            }
        }

        // Paused after Escape.
        if let until = pausedUntil, Date() < until { return }

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
        let screenContext = screenContextEnabled
            ? ScreenContextProvider.shared.contextText(for: bundleId, cap: screenCap, host: host) : ""
        expectedLimit = policy.inputContextChars ?? AppSettings.inputContextChars
        var ctx = ContextReader.gather(
            fallbackBuffer: buffer,
            screenContext: screenContext,
            inputChars: expectedLimit,
            wantsDocumentHead: policy.documentProfile)
        let current = reconcile(axInput: ctx.input)
        if current != ctx.input {
            ctx.input = current
            ctx.dedupKey += "|pending|" + current
        }

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


        // Require an actual focused element — like Cotypist, never suggest when
        // nothing is focused/selected (even if the keystroke buffer has text, e.g.
        // from typing over a non-text control or between fields).
        guard ctx.focused != nil else {
            Log.shared.debug("predict skipped: no focused element")
            return
        }

        // Small fields (search boxes, single-word inputs) get no suggestions,
        // Cotypist's thresholds: ≥ 6400 pt² and at least 32pt tall or 300pt wide.
        if !policy.ignoreSizeThresholds, let f = ctx.focused, let frame = AccessibilityBridge.elementFrame(of: f),
           !Engine.fieldIsLargeEnough(frame) {
            Log.shared.debug("predict skipped: field too small (\(Int(frame.width))×\(Int(frame.height)))")
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

        // Remember the field's AX text — commitRecentInput reads this when the
        // message is sent (the keystroke buffer alone is lossy).
        if let bid = bundleId, !ctx.input.isEmpty { lastAXInput = (bid, ctx.input, ctx.windowTitle) }

        // Skip redundant work if nothing changed since the last prediction.
        if ctx.dedupKey == lastPredictedPrompt { return }
        lastPredictedPrompt = ctx.dedupKey

        // A generation for an earlier prefix of this text is still running: let it
        // finish (it's at most ~100ms away) and splice its result, rather than
        // cancel it and start over.
        if let running = inFlight, ctx.input != running.input, ctx.input.hasPrefix(running.input) {
            deferredWhileInFlight = true
            lastPredictedPrompt = ""   // the follow-up run must not be deduped
            return
        }

        let engine = router.current
        let clipboard = settings.useClipboardContext ? freshClipboardText() : ""
        var req = CompletionRequest(
            beforeCursor: ctx.input,
            afterCursor: ctx.afterCursor,
            screenContext: screenContext,
            clipboard: clipboard,
            documentStart: ctx.documentStart,
            screenIsConversation: policy.transcriptViaAX,
            maxWords: settings.maxWords)
        applyWriterContext(&req, appName: frontApp, policy: policy)
        req.windowTitle = ctx.windowTitle
        req.fieldPlaceholder = ctx.placeholder
        req.learnsFromWriting = bundleId.map(learnsFromWriting) ?? false
        lastReq = req   // word-alternatives regeneration basis
        Log.shared.debug("predict app=\(bundleId ?? "?") engine=\(engine.displayName) focused=\(ctx.focused != nil) screenCtx=\(screenContext.count) inputTail=\"\(String(ctx.input.suffix(40)))\"")
        let startedAt = DispatchTime.now()

        Task { [weak self] in
            guard let self else { return }
            // Completing a misspelling is never what the user wants — skip the
            // generation while the word being typed looks like a typo (opt-out via
            // Settings ▸ Text Tools). Like Cotypist, only the CURRENT word counts:
            // finished words (slang, other languages, names) never block. It must
            // also be 4+ letters, lowercase, and not the start of any word on
            // screen or earlier in the text.
            if self.settings.skipOnTypo, let (token, isPartial) = Engine.typoCheckToken(ctx.input),
               isPartial, Engine.partialMayBeTypo(token, context: ctx.input + "\n" + screenContext),
               await SpellChecker.shared.isLikelyTypo(
                   word: token, isPartial: isPartial, language: self.settings.autocorrectLanguage) {
                Log.shared.debug("predict -> (typo before caret, skipped: \"\(token)\")")
                Statistics.shared.record(.gatedTypo)
                return
            }
            Statistics.shared.record(.requested)
            self.inFlightCounter += 1
            let id = self.inFlightCounter
            self.inFlight = (ctx.input, id)
            let raw = await engine.complete(req)
            if self.inFlight?.id == id { self.inFlight = nil }
            await self.handlePredictionResult(
                raw: raw, req: req, ctxInput: ctx.input, policy: policy, startedAt: startedAt)
            // Typing that waited on this generation: if the splice didn't produce
            // a ghost, predict for what's in the field now.
            if self.deferredWhileInFlight, self.inFlight == nil {
                self.deferredWhileInFlight = false
                if self.currentSuggestion == nil { self.schedulePrediction() }
            }
        }
    }

    /// A half-typed word worth checking against the dictionary: long enough to
    /// judge, not capitalised (names), and not the start of any word already in
    /// the context (names and jargon the dictionary doesn't know).
    nonisolated static func partialMayBeTypo(_ partial: String, context: String) -> Bool {
        guard partial.count >= 4, partial.first?.isLowercase == true else { return false }
        let lower = partial.lowercased()
        let earlier = context.lowercased().dropLast(partial.count)
        return !earlier.split(whereSeparator: { !$0.isLetter }).contains { $0.hasPrefix(lower) }
    }

    /// Cotypist's minimum field size for suggestions.
    nonisolated static func fieldIsLargeEnough(_ frame: CGRect) -> Bool {
        frame.width * frame.height >= 6400 && (frame.height >= 32 || frame.width >= 300)
    }

    /// What's left of `suggestion` (made for `requested`) once the field holds
    /// `current` — when the user typed exactly its start. nil when they typed
    /// something else, deleted, or used it up.
    nonisolated static func splice(_ suggestion: String, requested: String, current: String) -> String? {
        guard current != requested, current.hasPrefix(requested) else { return nil }
        let typed = current.dropFirst(requested.count)
        guard suggestion.hasPrefix(typed), suggestion.count > typed.count else { return nil }
        return String(suggestion.dropFirst(typed.count))
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

    /// Post-processing for a finished suggestion (already exact insertion text):
    /// after-cursor duplicate trim, staleness/remainder/repeat checks via the
    /// session, then presentation.
    private func handlePredictionResult(raw: String?, req: CompletionRequest, ctxInput: String,
                                        policy: AppPolicy, startedAt: DispatchTime) async {
        let elapsedMs = (DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
        if settings.verboseLog {
            Log.shared.debug("predict raw model output (pre-post-processing): \(raw.map { "\"\($0)\"" } ?? "nil")")
        }
        // nil: superseded by newer input, below the confidence bar, or nothing likely.
        guard let raw, !raw.isEmpty else {
            Log.shared.debug("predict -> (no suggestion) (\(elapsedMs)ms)")
            return
        }
        var suggestion = raw
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
        if session.evaluate(suggestion, requestedInput: ctxInput, currentInput: ctxInput) == .repeatOfAccepted {
            Log.shared.debug("predict -> (repeat of accepted text rejected) (\(elapsedMs)ms)")
            Statistics.shared.record(.rejectedRepeatAccepted)
            return
        }


        // The field may have changed while the model was generating (more typing,
        // deletions, Cmd+A wipe) — a result for stale input must never be shown.
        // Same guard the late-coalesced path has always had.
        var fresh = ContextReader.gather(fallbackBuffer: buffer, screenContext: req.screenContext,
                                         inputChars: expectedLimit)
        fresh.input = reconcile(axInput: fresh.input)
        // Splice: the user typed ahead, and what they typed is the start of this
        // suggestion — show the rest of it for the text as it is now.
        var requestedInput = ctxInput
        if let tail = Engine.splice(suggestion, requested: ctxInput, current: fresh.input) {
            Log.shared.debug("predict -> spliced \"\(suggestion)\" → \"\(tail)\" after typing ahead")
            suggestion = tail
            requestedInput = fresh.input
        }
        switch session.evaluate(suggestion, requestedInput: requestedInput, currentInput: fresh.input) {
        case .present:
            break
        case .stale(let rekick):
            Log.shared.debug("predict -> (input changed during generation, discarded) (\(elapsedMs)ms)")
            Statistics.shared.record(.discardedStale)
            // Re-kick for the CURRENT input — without this, a burst whose requests
            // were all stale ends with the model idle and no suggestion ever shown.
            // (Not while a remainder is being Tabbed through: the "changed" input
            // is the accepted word itself.)
            if rekick { schedulePrediction() }
            return
        case .held:
            Statistics.shared.record(.heldForRemainder)
            return
        case .repeatOfAccepted:
            Statistics.shared.record(.rejectedRepeatAccepted)
            return
        case .empty:
            return
        }

        Log.shared.debug("predict -> \"\(suggestion)\" (\(elapsedMs)ms)")
        // Wrapped (multi-line) ghost is only safe when nothing follows the caret —
        // otherwise the wrapped lines paint over the user's own text below.
        let allowWrap = req.afterCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Placement resolves inside the settle gate: presentation waits for a
        // typing pause and reads the caret THEN (mid-burst reads are stale).
        presentWhenSettled(suggestion: suggestion, isNewSuggestion: true, allowWrap: allowWrap)
        startLookahead(after: suggestion, input: requestedInput, request: req)
    }

    /// Compute the continuation of `input + suggestion` while `suggestion` is shown.
    private func startLookahead(after suggestion: String, input: String, request: CompletionRequest) {
        var ahead = request
        ahead.beforeCursor = input + suggestion
        ahead.afterCursor = ""
        ahead.speculative = true
        let entry = Lookahead(after: suggestion, input: input + suggestion, request: ahead, text: nil)
        lookahead = entry
        let engine = router.current
        Task { [weak self] in
            let text = await engine.complete(ahead)
            guard let self, self.lookahead?.input == entry.input, self.lookahead?.after == suggestion else { return }
            self.lookahead?.text = text ?? ""
            if let text { Log.shared.debug("lookahead: after \"\(suggestion)\" → \"\(text)\"") }
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
        if isNewSuggestion, session.text == suggestion {
            // Already registered by presentWhenSettled.
        } else {
            guard session.register(suggestion, isNew: isNewSuggestion) else { return }
        }
        if isNewSuggestion { Statistics.shared.recordShown() }
        shownAllowWrap = allowWrap
        // Text mirror (per-app opt-in): preview the line + suggestion in a
        // floating mirror instead of placing ghost text in the field.
        if policy.textMirror {
            let element = AccessibilityBridge.focusedElement()
            let anchor = element.flatMap { AccessibilityBridge.elementFrame(of: $0) }
                ?? inlineCaret.map { CGRect(x: $0.minX - 200, y: $0.minY, width: 400, height: $0.height) }
                ?? windowRect.map { CGRect(x: $0.minX + 40, y: $0.maxY - 120, width: $0.width - 80, height: 40) }
            let before = expectedInput
                ?? element.flatMap { AccessibilityBridge.textBeforeCaret(of: $0, maxChars: 120) } ?? ""
            let line = String(before.split(separator: "\n", omittingEmptySubsequences: false).last ?? "")
            if let anchor {
                overlay.showMirror(typedTail: line, suggestion: suggestion, fieldRect: anchor,
                                   opacity: settings.ghostOpacity)
            } else {
                overlay.showHUD(text: suggestion, windowRect: windowRect)
            }
            return
        }
        if let caretRect = inlineCaret {
            // The field's own font and text colour, as the app reports them over AX
            // (AXFont / AXForegroundColor); a caret-height guess only when it doesn't.
            let element = AccessibilityBridge.focusedElement()
            let caret = element.flatMap { AccessibilityBridge.caretOffset(of: $0) } ?? 0
            let style = element.flatMap { AccessibilityBridge.textStyle(of: $0, caret: caret) }
            let elementFrame = element.flatMap { AccessibilityBridge.elementFrame(of: $0) }
            // One placement record per field: app + input box + line height (the
            // window title changes per browser tab and would force refits).
            let fitKey = [AccessibilityBridge.frontmostBundleId() ?? "?",
                          "\(Int(caretRect.height.rounded()))",
                          "\(Int(elementFrame?.minX ?? 0)),\(Int(elementFrame?.minY ?? 0)),\(Int(elementFrame?.width ?? 0))"].joined(separator: "|")
            var base = style?.font ?? NSFont.systemFont(ofSize: max(11, caretRect.height * policy.fontSizeRatio))
            // Size-only reports (Chromium): the family measured for this field.
            if let style, !style.familyKnown, let family = fieldFamily[fitKey],
               let matched = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5,
                                                       size: style.font.pointSize) {
                base = matched
            }
            let font = policy.fontFactor == 1 ? base
                : NSFont(descriptor: base.fontDescriptor, size: base.pointSize * policy.fontFactor) ?? base
            let anchored = caretRect.offsetBy(dx: 0, dy: policy.verticalOffset)
            Log.shared.debug("placement app=\(AccessibilityBridge.frontmostBundleId() ?? "?") caretRect=\(caretRect) axFont=\(style.map { "yes(\($0.font.fontName) \($0.font.pointSize)pt\($0.familyKnown ? "" : ", size only"))" } ?? "no, using \(base.pointSize)pt heuristic") axColor=\(style?.color != nil ? "yes" : "no") fontFactor=\(policy.fontFactor) verticalOffset=\(policy.verticalOffset)")
            var color = style?.color
            if color == nil, settings.useScreenshotAppearance {
                GhostAppearanceProbe.shared.refresh(caretRect: caretRect)
                color = GhostAppearanceProbe.shared.current?.ghostColor
            }
            // Wrapped (multi-line) ghost only with positive evidence the caret is at
            // the end of the text — otherwise wrapped lines would cover the user's.
            let caretAtEnd = element.map(AccessibilityBridge.caretConfirmedAtEnd) == true
            let fieldRect = (allowWrap && caretAtEnd) ? elementFrame : nil
            let leftX = fieldRect == nil ? nil
                : element.flatMap { AccessibilityBridge.paragraphLeftX(of: $0, caret: caret) }
            // Clamp the ghost to the text INPUT BOX's right edge, not just the
            // window's — composers are narrower than their windows.
            let boxRight: CGFloat? = {
                var limit = windowRect.map { $0.maxX - 8 }
                if let f = elementFrame, f.width >= 60, f.width <= 2400,
                   f.insetBy(dx: -8, dy: -8).contains(CGPoint(x: anchored.midX, y: anchored.midY)) {
                    limit = min(limit ?? f.maxX - 6, f.maxX - 6)
                }
                return limit
            }()

            /// The fitted font, with the app's size adjustment applied.
            func fittedFont(_ fit: FieldFitCache.Fit) -> NSFont {
                guard policy.fontFactor != 1 else { return fit.font }
                return NSFont(descriptor: fit.font.fontDescriptor, size: fit.font.pointSize * policy.fontFactor)
                    ?? fit.font
            }

            // Paint at a specific caret rect, font and baseline (nil: derived from
            // the caret box) — the occupancy retry must render where it verified.
            let paint: (CGRect, NSFont, NSColor?, CGFloat?) -> Void = { [weak self] rect, useFont, useColor, baseline in
                guard let self else { return }
                let shown = self.overlay.showInline(
                    text: suggestion, at: rect, font: useFont,
                    opacity: self.settings.ghostOpacity, color: useColor ?? color,
                    maxRightX: boxRight, fieldRect: fieldRect, leftX: leftX,
                    baseline: baseline)
                if !shown {
                    // No room for even a couple of characters inline — HUD pill.
                    self.overlay.showHUD(text: suggestion, windowRect: windowRect)
                }
                Log.shared.debug("ghost painted \(Int(Date().timeIntervalSince(self.lastKeystrokeAt) * 1000))ms after the last edit")
            }
            /// AX-styled baseline: the caret-box estimate plus this field's measured
            /// correction, once known.
            let styledBaseline: (CGRect) -> CGFloat = { [weak self] rect in
                SuggestionOverlay.defaultBaseline(caret: rect, font: font)
                    + (self?.baselineAdjust[fitKey] ?? 0)
            }

            guard isNewSuggestion else {
                // Re-paint (type-through, Tab remainder): same font and baseline as
                // the field's first paint, so nothing flips between words.
                if style != nil {
                    paint(anchored, font, nil, styledBaseline(anchored))
                } else if let fit = FieldFitCache.shared.cached(key: fitKey) {
                    paint(anchored, fittedFont(fit), fit.textColor, anchored.minY + fit.baselineOffset)
                } else {
                    paint(anchored, font, nil, nil)
                }
                return
            }

            // Final occupancy check: AX caret geometry sometimes lies (stale
            // selection index, wrong y on wrapped lines in Electron) — before
            // painting inline, look at the actual PIXELS where the ghost would go.
            // Occupied → retry once at a freshly-read caret; still occupied → HUD.
            // Unknown → trust AX.
            // Skipped when AX vouches for the caret: nothing follows it in the text,
            // the app reports its text style, and the caret has moved off where it
            // was before the keystroke (so it isn't stale) — then there's nothing
            // the strip could reveal, and the screenshot would only cost time.
            let trustedCaret = caretAtEnd && style != nil
                && (caretAnchor.map { Self.caretMoved(caretRect, from: $0) } ?? false)
            if !trustedCaret { overlay.hide() }   // our own ghost must not trip the check
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
                var occupied = trustedCaret ? false : await checkOccupied(target)
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
                        // Never paint a ghost over real pixels; the HUD pill is
                        // anchored to the window, so it can't overlap the text.
                        Log.shared.debug("placement: strip still occupied — showing HUD pill instead")
                        Statistics.shared.record(.occupiedFallback)
                        self.overlay.showHUD(text: suggestion, windowRect: windowRect)
                        return
                    }
                }

                // The left strip of real text, for measuring the baseline.
                let leftStrip = CGRect(x: max(0, target.minX - 180), y: target.minY - 3,
                                       width: min(170, target.minX), height: target.height + 6)

                // Best: the app told us its font and colour. Paint now; measure this
                // field's baseline once from the real glyphs and correct if needed.
                if let style {
                    paint(target, font, nil, styledBaseline(target))
                    guard self.settings.useScreenshotAppearance else { return }
                    // Size-only report: measure the family once (size fixed), which
                    // also gives the exact baseline.
                    if !style.familyKnown, self.fieldFamily[fitKey] == nil,
                       self.familyTried.insert(fitKey).inserted {
                        let lineText = element.flatMap { AccessibilityBridge.textBeforeCaret(of: $0, maxChars: 120) } ?? ""
                        if let fit = await FieldFitCache.shared.fit(
                            caret: target, fieldFrame: elementFrame, key: fitKey + "|family", lineText: lineText,
                            verbose: self.settings.verboseLog, knownSize: style.font.pointSize),
                           fit.familyMatched, let family = fit.font.familyName {
                            guard self.currentSuggestion == suggestion else { return }
                            self.fieldFamily[fitKey] = family
                            let matched = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5,
                                                                    size: font.pointSize) ?? font
                            let baseline = target.minY + fit.baselineOffset
                            self.baselineAdjust[fitKey] = baseline
                                - SuggestionOverlay.defaultBaseline(caret: target, font: matched)
                            Log.shared.debug("placement: field family \(family) (size \(font.pointSize)pt from AX)")
                            paint(target, matched, nil, baseline)
                            return
                        }
                    }
                    guard self.baselineAdjust[fitKey] == nil,
                          let band = await GhostAppearanceProbe.inkBand(in: leftStrip),
                          self.currentSuggestion == suggestion else { return }
                    let bandHeight = band.bottom - band.top
                    guard bandHeight >= 6, bandHeight <= target.height + 2 else { return }
                    let estimate = SuggestionOverlay.defaultBaseline(caret: target, font: font)
                    let delta = band.baseline - estimate
                    guard abs(delta) <= target.height / 2 else { return }   // a different line
                    self.baselineAdjust[fitKey] = delta
                    Log.shared.debug("placement: measured baseline correction \(String(format: "%.1f", delta))pt")
                    if abs(delta) >= 1 { paint(target, font, nil, estimate + delta) }
                    return
                }

                // No style over AX: the field's measured font/size/baseline/colour.
                if self.settings.useScreenshotAppearance {
                    let lineText = element.flatMap { AccessibilityBridge.textBeforeCaret(of: $0, maxChars: 120) } ?? ""
                    if let fit = await FieldFitCache.shared.fit(caret: target, fieldFrame: elementFrame, key: fitKey,
                                                                lineText: lineText, verbose: self.settings.verboseLog) {
                        guard self.currentSuggestion == suggestion else { return }
                        paint(target, fittedFont(fit), fit.textColor, target.minY + fit.baselineOffset)
                        return
                    }
                }

                // Last resort: size and baseline from the real text's ink band.
                var useFont = font
                var probedBaseline: CGFloat?
                if let band = await GhostAppearanceProbe.inkBand(in: leftStrip) {
                    guard self.currentSuggestion == suggestion else { return }
                    let bandHeight = band.bottom - band.top
                    // Taller than the caret's line box: the strip caught more than
                    // one line (or an icon) — distrust it.
                    if bandHeight >= 6, bandHeight <= target.height + 2 {
                        // Baseline-to-ascent span ≈ 0.78 × point size for typical text.
                        let ascentSpan = band.baseline - band.top
                        if ascentSpan >= 5 {
                            let size = min(max(ascentSpan * 1.28, 9), target.height * 0.95)
                            useFont = NSFont(descriptor: font.fontDescriptor, size: size) ?? font
                        }
                        probedBaseline = band.baseline
                        Log.shared.debug("placement: baseline \(String(format: "%.1f", band.baseline)) band \(String(format: "%.0f-%.0f", band.top, band.bottom)) -> font \(String(format: "%.1f", useFont.pointSize))pt")
                    }
                }

                paint(target, useFont, nil, probedBaseline)
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
                    self.dropPendingEdits()   // text changed other than by typing
                    TextInserter.backspace(count: deleteCount)
                    TextInserter.insert(insert, strategy: .keystroke)
                }
                return true
            }
            inlineCommand.cancel()
            return false
        }

        let options = SuggestionSession.AcceptOptions(
            includeTrailingPunctuation: settings.includeTrailingPunctuation,
            includeTrailingSpace: settings.includeTrailingSpace)
        let accepted = session.text ?? ""
        guard let (toInsert, remainder) = session.accept(whole: whole, options: options) else { return false }

        // Accepting the last word: the lookahead (when ready) is what comes next.
        var next: String?
        if remainder.isEmpty, let ahead = lookahead, ahead.after.hasSuffix(accepted),
           let text = ahead.text, !text.isEmpty {
            next = text
            session.register(text, isNew: true)
            Statistics.shared.recordShown()
            Log.shared.debug("predict -> \"\(text)\" [lookahead] (0ms)")
        }
        let shownNext = next ?? remainder
        // Slide the rest of the ghost (or the next words) to where the inserted text
        // will end — no gap while the app catches up; the settled caret confirms it.
        if shownNext.isEmpty || !overlay.advance(typed: toInsert, remainder: shownNext) { overlay.hide() }
        if let next, let ahead = lookahead {
            startLookahead(after: next, input: ahead.input, request: ahead.request)
        }
        if session.isProtectingRemainder {
            // Tear down the prediction machinery armed by earlier real keystrokes,
            // or it fires on the just-inserted word and replaces the remainder:
            // the host-publish poll (scheduleToken), the debounce, and any
            // in-flight generation whose stale result would re-kick — but not a
            // lookahead still computing what follows this suggestion.
            debounceWork?.cancel()
            scheduleToken += 1
            if lookahead == nil || lookahead?.text != nil { router.cancelInFlight() }
        }
        buffer += toInsert
        let strategy = AppPolicyStore.policy(forBundleId: AccessibilityBridge.frontmostBundleId())
            .insertionStrategy
        let wordCount = toInsert.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        Statistics.shared.recordAccepted(wordCount: max(wordCount, toInsert.isEmpty ? 0 : 1))

        // Snapshot the pre-insertion field length so the speculative re-prediction
        // below can wait until the WHOLE insert has landed in the AX tree —
        // predicting on pre-insertion text regenerates the suggestion just accepted.
        let baselineLen = AccessibilityBridge.focusedElement()
            .flatMap { AccessibilityBridge.textLength(of: $0) }

        // Insert on the next tick so we return from the tap callback first.
        DispatchQueue.main.async {
            // Synthesized keystrokes are invisible to the tap (injected marker), so
            // stamp the keystroke clock manually — the settle gate must treat the
            // insertion like typing, or the remainder ghost paints at the
            // pre-insert caret and overlaps the inserted text.
            self.markEdit()
            self.applyPendingEdit(chars: toInsert, isDeletion: false)
            TextInserter.insert(toInsert, strategy: strategy)
            if let next {
                // Re-anchor at the settled caret — unless more Tabs already moved on.
                guard self.currentSuggestion == next else { return }
                self.presentWhenSettled(suggestion: next, isNewSuggestion: false,
                                        allowWrap: self.shownAllowWrap, earlyOnCaretMove: false)
                return
            }
            if remainder.isEmpty {
                // Suggestion exhausted with no lookahead ready — fetch the next
                // continuation as soon as the insert lands.
                guard self.currentSuggestion == nil else { return }
                self.hostBaselineLen = baselineLen
                self.hostExpectedLen = baselineLen.map { $0 + toInsert.utf16.count }
                self.schedulePrediction()
                return
            }
            // The synthesized keystrokes are processed by the target app slightly
            // after we post them — the settle gate re-reads the caret only after
            // things quiet down, so the remaining ghost lands at the new position.
            // A multi-character insert lands key by key: wait the full settle
            // instead of trusting the first caret move.
            // A quicker second Tab already took this remainder further: re-anchoring
            // it here would resurrect the older, longer text.
            guard self.currentSuggestion == remainder else { return }
            self.presentWhenSettled(suggestion: remainder, isNewSuggestion: false,
                                    allowWrap: self.shownAllowWrap, earlyOnCaretMove: false)
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

    /// `keepGeneration`: typing ahead — let a running generation finish so its
    /// result can be spliced (see `inFlight`).
    private func clearSuggestion(keepGeneration: Bool = false) {
        debounceWork?.cancel()
        scheduleToken += 1   // invalidate any in-flight host-publish poll
        if !keepGeneration { router.cancelInFlight() }
        session.clear()
        hostExpectedLen = nil
        alternatives.hide()
        overlay.hide()
    }
}
