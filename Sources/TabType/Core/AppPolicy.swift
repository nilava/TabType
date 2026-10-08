import Foundation

enum InsertionStrategy {
    case auto        // keystroke, upgrading to paste for long/multiline text
    case keystroke
    case paste
}

/// Per-app behavior overrides. Mirrors the per-app compatibility policies used by
/// cotabby/KeyType so TabType behaves well (and safely) across very different apps.
struct AppPolicy {
    var isEnabled: Bool = true
    /// Never show/insert in password fields.
    var excludesSecureField: Bool = true
    /// Whether to feed remembered on-screen context to the model for this app.
    var includesScreenContext: Bool = true
    /// When true, screen-memory context is used for this app even if the user hasn't
    /// globally turned on `useScreenContext` — for chat/messaging apps where reading
    /// recent conversation is the whole point, matching Cotypist-style behavior.
    var forceScreenContext: Bool = false
    /// Electron/web apps report caret bounds that lag ~0.3-0.5s behind the real
    /// caret during typing. Presentation there must wait for a typing pause (the
    /// Cotypist strategy — observed live): by idle time the bounds have caught up
    /// and inline ghosts place correctly.
    var laggyCaret: Bool = false
    /// Code editors: suggest only in short chat inputs (sidebar panels), never the
    /// main editor surface — prose autocomplete there fights code completion.
    var chatPanelsOnly: Bool = false
    /// Prefer extracting the conversation from the AX tree (chat apps) instead of
    /// OCR; falls back to OCR when the tree yields too little.
    var transcriptViaAX: Bool = false
    /// Overrides the default screen-context character budget for this app (nil = use
    /// the global default). Chat apps get a larger budget so more transcript survives.
    var screenContextCap: Int?
    var insertionStrategy: InsertionStrategy = .auto
    /// Ghost-text font size multiplier (some apps render at different metrics).
    var fontFactor: Double = 1.0
    /// Ghost-text vertical nudge in points.
    var verticalOffset: Double = 0
    /// Suggestions appear in a floating mirror of the line (Cotypist's text
    /// mirroring) — for apps where inline ghost text can't be placed reliably.
    var textMirror: Bool = false
    /// Suggest in fields of any size (normally small fields are skipped).
    var ignoreSizeThresholds: Bool = false
    /// Font-size-from-caret-height ratio, used only when the field's real AX font
    /// can't be read (common for web/Electron content). Web/Electron caret rects are
    /// padded CSS line boxes, so a tight-line-box ratio (0.72) undersizes the ghost;
    /// 0.83 matches the field text size observed in Claude Desktop (Cotypist's
    /// ghost renders at exactly the field size there).
    var fontSizeRatio: Double = 0.83
    /// Whether to show completions when there's text after the cursor on the same line.
    var allowsMidLine: Bool = true
    /// When true, Tab does not accept suggestions in this app (e.g. IDEs where Tab
    /// indents or switches fields).
    var disableTabKey: Bool = false
    /// Per-app autocorrect override; nil defers to the global setting.
    var autocorrectOverride: Bool?
    /// Extra instructions appended to the model persona for this app.
    var customInstructions: String = ""
    /// Long-form writing apps: the surrounding document is the context that
    /// matters — bigger caret window + document-head anchoring.
    var documentProfile: Bool = false
    /// Overrides how many chars before the caret are read (nil = the global
    /// `contextChars` setting). Document apps get a bigger window.
    var inputContextChars: Int?
}

// MARK: - Profile classification + plain-English summary (Settings transparency)

extension AppPolicy {
    enum Profile: String {
        case chat = "Chat"
        case document = "Document"
        case codeEditor = "Code editor"
        case disabled = "Disabled"
        case standard = "Standard"
    }

    /// The effective profile, derived from the RESOLVED policy (so user overrides
    /// show through) — powers the badge in the Apps list.
    var profile: Profile {
        if !isEnabled { return .disabled }
        if chatPanelsOnly { return .codeEditor }
        if transcriptViaAX || forceScreenContext { return .chat }
        if documentProfile { return .document }
        return .standard
    }

    /// Plain-English, always-true-to-the-resolved-policy description of what
    /// TabType does in this app — shown in the Apps pane so none of the per-app
    /// behavior is invisible "trickery".
    var summaryLines: [String] {
        guard isEnabled else { return ["Completions are turned off for this app."] }
        var lines: [String] = []
        switch profile {
        case .chat:
            lines.append(transcriptViaAX
                ? "Reads the visible conversation via the accessibility tree (no screenshots needed)."
                : "Reads nearby on-screen text for conversation context.")
        case .document:
            lines.append("Treats your document as the context — reads a large window around the cursor plus the document's opening lines.")
        case .codeEditor:
            lines.append("Suggests only in sidebar chat panels — never in the code editor itself.")
        case .standard:
            lines.append(includesScreenContext
                ? "Uses nearby on-screen text as context when screen context is enabled."
                : "Uses only the text you're typing as context.")
        case .disabled:
            break
        }
        let cap = screenContextCap ?? AppPolicyStore.defaultContextCap
        if includesScreenContext, profile != .codeEditor {
            lines.append("Context budget: up to \(cap.formatted()) characters\(forceScreenContext ? " (always on for this app)" : "").")
        }
        if laggyCaret {
            lines.append("Web-style text field: suggestions appear after a brief typing pause so they align correctly.")
        }
        if insertionStrategy == .paste {
            lines.append("Inserts accepted text via paste (most reliable in this app).")
        }
        if !allowsMidLine {
            lines.append("No suggestions mid-line (only at the end of what you've typed).")
        }
        if disableTabKey {
            lines.append("Tab is left alone here — accept with the alternative shortcut.")
        }
        if !customInstructions.isEmpty {
            lines.append("Custom instructions are active for this app.")
        }
        return lines
    }
}

/// A user-editable per-app behavior override. `nil` fields defer to TabType's
/// built-in default (or the global setting, for autocorrect).
struct AppOverride: Codable, Equatable {
    var enabled: Bool?
    var midLineEnabled: Bool?
    var autocorrectEnabled: Bool?
    var disableTabKey: Bool?
    var improveCompatibility: Bool = false
    var customInstructions: String = ""
    /// Promote/demote conversation reading (AX transcript + always-on screen
    /// context) for this app. nil = built-in default.
    var readConversation: Bool?
    /// "small" / "large" screen-context budget override; nil = default.
    var contextSize: String?
    /// Ghost text size multiplier (e.g. 0.95); nil = default.
    var ghostFontScale: Double?
    /// Ghost text vertical nudge in points (+ = down); nil = default.
    var ghostVerticalOffset: Double?
    /// Learn from what's written in this app; nil = follow the global setting.
    var learnFromWriting: Bool?
    /// Show suggestions in a floating mirror of the line instead of inline.
    var textMirror: Bool?
    /// Suggest even in small fields (search boxes etc.).
    var ignoreSizeThresholds: Bool?

    var isDefault: Bool {
        enabled == nil && midLineEnabled == nil && autocorrectEnabled == nil
            && disableTabKey == nil && !improveCompatibility && customInstructions.isEmpty
            && readConversation == nil && contextSize == nil
            && ghostFontScale == nil && ghostVerticalOffset == nil && learnFromWriting == nil
            && textMirror == nil && ignoreSizeThresholds == nil
    }
}

@MainActor
enum AppPolicyStore {
    /// User-configured per-app overrides, keyed by bundle id. Set by `AppSettings`.
    static var userOverrides: [String: AppOverride] = [:]
    /// Password managers — completions fully disabled (safety).
    private static let passwordManagers: Set<String> = [
        "com.1password.1password", "com.1password.1password7",
        "com.agilebits.onepassword7", "com.apple.Passwords",
        "com.bitwarden.desktop", "com.dashlane.Dashlane",
        "com.callpod.keepermac", "com.lastpass.LastPass",
    ]

    /// Terminals — autocomplete is disruptive; disabled by default.
    private static let terminals: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
        "com.mitchellh.ghostty", "io.alacritty", "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    /// Apps that need clipboard paste for reliable insertion.
    private static let pasteApps: Set<String> = [
        "com.tinyspeck.slackmacgap", "com.google.Chrome", "com.microsoft.VSCode",
        "notion.id", "md.obsidian",
    ]

    /// Code editors: prose autocomplete in the MAIN EDITOR collides with actual
    /// code completion — activate only in sidebar chat inputs (the Cotypist
    /// behavior documented on its compatibility page).
    private static let codeEditorApps: Set<String> = [
        "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92" /* Cursor */,
        "com.exafunction.windsurf", "com.apple.dt.Xcode",
    ]
    private static let codeEditorBundlePrefixes = ["com.jetbrains."]

    /// Electron/Chromium apps whose AX caret bounds lag the real caret while
    /// typing (observed ~0.5s in Claude Desktop) — inline ghost placement can't be
    /// trusted there; suggestions render as a bubble above the caret instead.
    private static let electronApps: Set<String> = [
        "com.anthropic.claudefordesktop", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "net.whatsapp.WhatsApp", "notion.id", "md.obsidian",
        "com.microsoft.VSCode", "com.spotify.client", "com.figma.Desktop",
        "com.microsoft.teams2", "us.zoom.xos",
        "org.whispersystems.signal-desktop", "im.riot.app", "im.beeper",
        "Mattermost.Desktop", "org.zulip.zulip-electron", "com.facebook.archon",
    ]

    /// Chat/messaging apps where recent conversation IS the context that matters —
    /// screen memory is force-enabled here regardless of the global toggle, with a
    /// larger character budget so more transcript survives into the prompt.
    private static let chatApps: Set<String> = [
        "com.anthropic.claudefordesktop", "com.tinyspeck.slackmacgap",
        "com.hnc.Discord", "com.apple.MobileSMS", "net.whatsapp.WhatsApp",
        "ru.keepcoder.Telegram", "org.whispersystems.signal-desktop",
        "com.microsoft.teams2", "com.facebook.archon" /* Messenger */,
        "im.riot.app" /* Element */, "im.beeper", "Mattermost.Desktop",
        "org.zulip.zulip-electron", "com.skype.skype", "com.google.Chat",
    ]

    /// Chat context budget (chars of transcript reaching the prompt).
    nonisolated static let chatContextCap = 1400
    /// Default screen-context budget for everything else.
    nonisolated static let defaultContextCap = 700

    /// Web chat services: a browser tab on one of these hosts gets the full chat
    /// treatment (AX transcript + always-on context) — the DOM exposes messages
    /// as accessibility static text, which reads far cleaner than OCR.
    static let chatDomains: Set<String> = [
        "claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com",
        "web.whatsapp.com", "web.telegram.org", "discord.com", "app.slack.com",
        "messenger.com", "chat.deepseek.com", "aistudio.google.com",
        "poe.com", "perplexity.ai",
    ]

    /// Long-form writing apps: the document itself is the context — read a much
    /// bigger window around the caret and anchor with the document's opening.
    private static let documentApps: Set<String> = [
        "com.apple.Notes", "com.apple.iWork.Pages", "com.microsoft.Word",
        "com.apple.TextEdit", "com.lukilabs.lukiapp" /* Craft */,
        "net.shinyfrog.bear", "com.ulyssesapp.mac", "pro.writer.mac" /* iA Writer */,
        "abnerworks.Typora", "com.literatureandlatte.scrivener3",
        "md.obsidian", "notion.id",
    ]

    static func policy(forBundleId id: String?) -> AppPolicy {
        guard let id else { return AppPolicy() }
        if passwordManagers.contains(id) || terminals.contains(id) {
            return AppPolicy(isEnabled: false)
        }
        var policy = AppPolicy()
        if pasteApps.contains(id) { policy.insertionStrategy = .paste }
        if chatApps.contains(id) {
            policy.forceScreenContext = true
            policy.screenContextCap = chatContextCap
            // Chat transcripts read far cleaner from the AX tree than from OCR.
            policy.transcriptViaAX = true
        }
        if documentApps.contains(id) {
            policy.documentProfile = true
            policy.inputContextChars = 2000
        }
        // Electron/web apps: AX caret bounds lag behind the real caret while
        // typing — present only after a typing pause, and never mid-line (the
        // after-text position can't be trusted enough to avoid overlap there).
        if electronApps.contains(id) {
            policy.laggyCaret = true
            policy.allowsMidLine = false
        }
        if codeEditorApps.contains(id)
            || codeEditorBundlePrefixes.contains(where: { id.hasPrefix($0) }) {
            policy.chatPanelsOnly = true
        }
        switch id {
        case "com.apple.Safari": policy.fontFactor = 0.98
        case "com.google.Chrome": policy.fontFactor = 1.0
        default: break
        }

        if let o = userOverrides[id] {
            if let e = o.enabled { policy.isEnabled = e }
            if let m = o.midLineEnabled { policy.allowsMidLine = m }
            if let d = o.disableTabKey { policy.disableTabKey = d }
            policy.autocorrectOverride = o.autocorrectEnabled
            if o.improveCompatibility { policy.insertionStrategy = .paste }
            policy.customInstructions = o.customInstructions
            if let scale = o.ghostFontScale { policy.fontFactor *= scale }
            if let offset = o.ghostVerticalOffset { policy.verticalOffset += offset }
            if let mirror = o.textMirror { policy.textMirror = mirror }
            if let ignore = o.ignoreSizeThresholds { policy.ignoreSizeThresholds = ignore }
            applyContextOverrides(o, to: &policy)
        }
        return policy
    }

    /// The BUILT-IN context budget for an app, ignoring the user's own context
    /// overrides — powers the honest "Default (N characters)" label in Settings.
    static func builtinContextCap(forBundleId id: String?) -> Int {
        guard let id else { return defaultContextCap }
        var stripped = userOverrides
        if var o = stripped[id] {
            o.readConversation = nil
            o.contextSize = nil
            stripped[id] = o
        }
        let saved = userOverrides
        userOverrides = stripped
        defer { userOverrides = saved }
        return policy(forBundleId: id).screenContextCap ?? defaultContextCap
    }

    /// The user-facing context knobs (Apps pane): promote any app to full chat
    /// treatment, or resize its context budget.
    private static func applyContextOverrides(_ o: AppOverride, to policy: inout AppPolicy) {
        if let read = o.readConversation {
            policy.transcriptViaAX = read
            policy.forceScreenContext = read
            if read, policy.screenContextCap == nil { policy.screenContextCap = chatContextCap }
        }
        switch o.contextSize {
        case "small": policy.screenContextCap = 300
        case "large": policy.screenContextCap = chatContextCap
        default: break
        }
    }

    /// Overrides keyed by website host use a `domain:` prefix in the same store.
    static func domainKey(_ host: String) -> String { "domain:" + host.lowercased() }

    /// Policy for a bundle id AND the current website — the domain override is
    /// applied last (most specific wins). `host` matches exactly or by suffix
    /// ("mail.google.com" matches an override for "google.com").
    static func policy(forBundleId id: String?, host: String?) -> AppPolicy {
        var policy = policy(forBundleId: id)
        guard let host = host?.lowercased() else { return policy }
        // Built-in web-chat services get the full chat treatment (before user
        // domain overrides, which stay the most specific and win last).
        if chatDomains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            policy.forceScreenContext = true
            policy.transcriptViaAX = true
            policy.screenContextCap = chatContextCap
        }
        let match = userOverrides.first { key, _ in
            guard key.hasPrefix("domain:") else { return false }
            let domain = String(key.dropFirst("domain:".count))
            return host == domain || host.hasSuffix("." + domain)
        }
        if let (_, o) = match {
            if let e = o.enabled { policy.isEnabled = e }
            if let m = o.midLineEnabled { policy.allowsMidLine = m }
            if !o.customInstructions.isEmpty {
                policy.customInstructions = policy.customInstructions.isEmpty
                    ? o.customInstructions
                    : policy.customInstructions + " " + o.customInstructions
            }
        }
        return policy
    }
}
