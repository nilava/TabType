import SwiftUI

/// What TabType is allowed to read for extra context, grouped the way Cotypist's own
/// Context pane is (Screenshot Settings / Clipboard Settings) rather than folded into
/// Personalization.
struct ContextPane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Screen Context") {
                Toggle("Read on-screen context", isOn: $settings.useScreenContext)
                Text("Reads the conversation or document around your cursor — via the accessibility tree in chat apps, or an on-device screenshot elsewhere — so suggestions match what you're working on. Chat apps like Slack and Claude always use this.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("TabType picks a context recipe per app: the conversation in chat apps and chat websites (accessibility tree, no screenshots), your document in writing apps, and nearby on-screen text elsewhere. Open the Apps section to see exactly what applies to each app — and to change it.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Use screenshots to improve suggestion appearance", isOn: $settings.useScreenshotAppearance)
                Text("Samples the color around the caret so ghost text blends with the field's real text. May occasionally show a Screen Recording indicator in the menu bar.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Clipboard Settings") {
                Toggle("Use clipboard for context", isOn: $settings.useClipboardContext)
                Text("Reads your clipboard to understand what you're working with. Processed locally; never stored or sent anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// Toggles for the inline text tools (autocorrect + macros). Emoji has its own
/// dedicated sidebar section (`EmojiPane`).
struct TextToolsPane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Autocorrect") {
                Toggle("Fix typos automatically", isOn: $settings.autocorrectEnabled)
                    .onChange(of: settings.autocorrectEnabled) { _, on in
                        if on { SpellChecker.shared.loadIfNeeded(language: settings.autocorrectLanguage) }
                    }
                Picker("Language", selection: $settings.autocorrectLanguage) {
                    Section("Western") {
                        ForEach(["en", "es", "fr", "de", "it", "pt"], id: \.self) {
                            Text(SpellChecker.displayName($0)).tag($0)
                        }
                    }
                    Section("Indian") {
                        ForEach(["hi", "bn", "ta", "te", "ml", "ur"], id: \.self) {
                            Text(SpellChecker.displayName($0)).tag($0)
                        }
                    }
                }
                .disabled(!settings.autocorrectEnabled)
                .onChange(of: settings.autocorrectLanguage) { _, lang in
                    SpellChecker.shared.loadIfNeeded(language: lang)
                }
                Text("When you finish a word, clear typos are corrected in place (e.g. \"teh\" → \"the\"). Never in password fields.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Don't suggest while a word is misspelled", isOn: $settings.skipOnTypo)
                    .onChange(of: settings.skipOnTypo) { _, on in
                        if on { SpellChecker.shared.loadIfNeeded(language: settings.autocorrectLanguage) }
                    }
                Text("Pauses completions when the word at the cursor looks like a typo, instead of suggesting its corrected form.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Macros") {
                Toggle("Inline macros", isOn: $settings.macrosEnabled)
                Text("Type `/` then a command and press Tab:")
                    .font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    macroRow("/date, /time, /now", "current date / time")
                    macroRow("/uuid, /dice, /coin", "random value")
                    macroRow("/random 100", "random 0–100")
                    macroRow("10km->mi", "unit conversion")
                    macroRow("2+2*3", "arithmetic")
                }
                .font(.caption)
                .padding(.top, 2)
            }
        }
        .formStyle(.grouped)
    }

    private func macroRow(_ cmd: String, _ desc: String) -> some View {
        GridRow {
            Text(cmd).monospaced().foregroundStyle(.primary)
            Text(desc).foregroundStyle(.secondary)
        }
    }
}

struct ShortcutsPane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Shortcuts") {
                KeyRecorderRow(title: "Accept word", binding: $settings.acceptWordKey)
                KeyRecorderRow(title: "Accept whole suggestion", binding: $settings.acceptAllKey)
                KeyRecorderRow(title: "Dismiss", binding: $settings.dismissKey)
                KeyRecorderRow(title: "Word alternatives", binding: $settings.wordAlternativesKey)
                KeyRecorderRow(title: "Force a suggestion", binding: $settings.forceActivateKey)
                KeyRecorderRow(title: "Pause in current app (5 min)", binding: $settings.appPauseKey)
                KeyRecorderRow(title: "Enable/disable TabType", binding: $settings.toggleKey, allowNone: true)
                Text("Hold ⌥ with the accept key to send the real key to the app (e.g. ⌥Tab moves between form fields while a suggestion is shown).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Accepting a word") {
                Toggle("Include trailing space", isOn: $settings.includeTrailingSpace)
                Toggle("Include trailing punctuation", isOn: $settings.includeTrailingPunctuation)
                Text("When off, punctuation attached to a word (like a period or ?) is left for a separate press.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Behavior") {
                Picker("When you press Escape", selection: $settings.escapeBehavior) {
                    Text("Dismiss the suggestion").tag("dismiss")
                    Text("Pause completions briefly").tag("pause")
                }
            }
            Section {
                Text("Click a shortcut, then press the key combination you want. Changes take effect immediately.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// A row that records a key combination when focused.
private struct KeyRecorderRow: View {
    let title: String
    @Binding var binding: KeyBinding
    var allowNone: Bool = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                KeyRecorder(binding: $binding)
                if allowNone && binding.isSet {
                    Button("Clear") { binding = .unset }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
        }
    }
}

/// An NSView-backed recorder that captures the next key + modifiers.
private struct KeyRecorder: NSViewRepresentable {
    @Binding var binding: KeyBinding

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton()
        b.onCapture = { self.binding = $0 }
        b.binding = binding
        return b
    }
    func updateNSView(_ nsView: RecorderButton, context: Context) {
        nsView.binding = binding
        nsView.refreshTitle()
    }

    final class RecorderButton: NSButton {
        var binding: KeyBinding = .unset
        var onCapture: ((KeyBinding) -> Void)?
        private var recording = false

        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded
            setButtonType(.momentaryPushIn)
            target = self
            action = #selector(startRecording)
            refreshTitle()
        }
        required init?(coder: NSCoder) { fatalError() }

        func refreshTitle() {
            title = recording ? "Press keys…" : binding.displayString
        }

        @objc private func startRecording() {
            recording = true
            refreshTitle()
            window?.makeFirstResponder(self)
        }

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            let b = KeyBinding(keyCode: Int(event.keyCode),
                               flags: cgFlags(from: event.modifierFlags))
            recording = false
            binding = b
            onCapture?(b)
            refreshTitle()
        }

        private func cgFlags(from m: NSEvent.ModifierFlags) -> CGEventFlags {
            var f: CGEventFlags = []
            if m.contains(.command) { f.insert(.maskCommand) }
            if m.contains(.shift) { f.insert(.maskShift) }
            if m.contains(.option) { f.insert(.maskAlternate) }
            if m.contains(.control) { f.insert(.maskControl) }
            return f
        }
    }
}

/// Author name / voice / custom instructions that shape suggestions to sound like you.
struct PersonalizationPane: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Learn from your writing") {
                Toggle("Learn from what I write", isOn: $settings.collectTypingHistory)
                Text("TabType keeps the messages you send and the text you write (passwords, keys and card numbers are removed first) so suggestions can reuse your own phrasing — your sign-offs, names and recurring sentences. Everything is encrypted and stays on your Mac. You can turn this on or off per app in Settings ▸ Apps.")
                    .font(.caption).foregroundStyle(.secondary)
                LearnedWritingRow()
            }
            Section {
                HStack {
                    Text("Custom AI Instructions").font(.headline)
                    Spacer()
                    Button("Reset to Default") {
                        settings.authorName = NSFullUserName()
                        settings.writingStyle = ""
                        settings.customInstructions = ""
                    }
                }
                TextField("Your name (optional)", text: $settings.authorName)
                    .textFieldStyle(.roundedBorder)
                VStack(alignment: .leading) {
                    Text("Writing style").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g. concise, friendly, British spelling", text: $settings.writingStyle, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                }
                VStack(alignment: .leading) {
                    Text("Custom instructions").font(.caption).foregroundStyle(.secondary)
                    TextField("e.g. Avoid exclamation marks. Prefer plain words.", text: $settings.customInstructions, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...5)
                }
                Text("These shape suggestions to match your voice. Sent only to the on-device model.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}


/// Emoji suggestions + customization.
struct EmojiPane: View {
    @EnvironmentObject var settings: AppSettings
    var body: some View {
        Form {
            Section {
                Toggle("Enable emoji suggestions", isOn: $settings.emojiEnabled)
                Toggle("Suggest emoji from emoticons", isOn: $settings.emoticonsEnabled)
                Text("Type `:name` and Tab to insert 🚀, or common emoticons like :-) ;-) <3 which convert automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Customization") {
                Picker("Preferred skin tone", selection: $settings.emojiSkinTone) {
                    ForEach(SkinTone.allCases, id: \.rawValue) { tone in
                        Text(tone.label).tag(tone.rawValue)
                    }
                }
                Text("Applied to emoji that support skin-tone modifiers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}


/// Local usage counters: words completed and suggestion acceptance rate.
struct StatisticsPane: View {
    @ObservedObject var stats = Statistics.shared

    var body: some View {
        Form {
            Section {
                Text("These numbers are stored only on your Mac and never leave it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Usage") {
                LabeledContent("Words completed", value: "\(stats.wordsCompleted)")
                LabeledContent("Suggestions shown", value: "\(stats.suggestionsShown)")
                LabeledContent("Suggestions accepted", value: "\(stats.suggestionsAccepted)")
                LabeledContent("Acceptance rate", value: percent(stats.acceptanceRate))
                LabeledContent("Accepted one word / several words",
                               value: "\(stats.singleWordAccepts) / \(stats.multiWordAccepts)")
                LabeledContent("Response time (typical / slowest 5%)",
                               value: stats.latencyPercentiles.map { "\($0.p50) ms / \($0.p95) ms" } ?? "—")
            }
            Section("Suggestion Funnel") {
                LabeledContent("Show rate", value: percent(stats.showRate))
                ForEach(Statistics.FunnelEvent.allCases, id: \.rawValue) { event in
                    LabeledContent(event.label, value: "\(stats.funnel[event] ?? 0)")
                }
                Text("Where suggestions die between a model request and the ghost text on screen. A low show rate with high rejection counts points at over-aggressive filtering; high \"input changed\" counts point at latency.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset Statistics", role: .destructive) { stats.reset() }
            }
        }
        .formStyle(.grouped)
    }

    private func percent(_ v: Double) -> String {
        String(format: "%.0f%%", v * 100)
    }
}

/// Experimental, opt-in features that may change or be removed.


struct AboutPane: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Image(systemName: "text.cursor")
                            .font(.system(size: 28)).foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text("TabType").font(.title2).bold()
                            Text("Free, open-source, on-device autocomplete for macOS.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Privacy") {
                Label("Runs 100% on your Mac. No cloud, no account, no telemetry.",
                      systemImage: "lock.shield")
                Label("Your text and screen content never leave the device.",
                      systemImage: "hand.raised")
                Label("Password fields are never autocompleted.",
                      systemImage: "key.slash")
            }
            Section("Open source") {
                Text("MIT licensed. Inspired by Cotypist; built in the open, more permissive than AGPL alternatives.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Third-party acknowledgments") {
                ForEach(Self.acknowledgments, id: \.name) { ack in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ack.name).fontWeight(.medium)
                        Text(ack.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private static let acknowledgments: [(name: String, detail: String)] = [
        ("Apple Foundation Models & Vision", "On-device AI completions and OCR — Apple Inc."),
        ("MLX Swift", "Local model inference on Apple silicon — Apple / ml-explore"),
        ("mlx-swift-lm", "LLM model implementations — ml-explore"),
        ("swift-transformers", "Hugging Face model download — Hugging Face"),
        ("Qwen2.5", "Local base models — Alibaba (Apache-2.0)"),
        ("gemoji", "Emoji shortcode dataset — GitHub (MIT)"),
        ("FrequencyWords", "Autocorrect frequency lists — Hermit Dave (MIT)"),
        ("SymSpell algorithm", "Symmetric-delete spelling correction — Wolf Garbe (MIT)"),
    ]
}


/// How much writing TabType has learned from, with an erase button.
private struct LearnedWritingRow: View {
    @ObservedObject private var store = WritingStore.shared
    @State private var confirming = false

    var body: some View {
        HStack {
            Text(store.documentCount == 0
                 ? "Nothing learned yet."
                 : "Learned from \(store.documentCount) pieces of writing (\(ByteCountFormatter.string(fromByteCount: Int64(store.characterCount), countStyle: .file))).")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Erase…", role: .destructive) { confirming = true }
                .disabled(store.documentCount == 0)
        }
        .confirmationDialog("Erase everything TabType learned from your writing?", isPresented: $confirming) {
            Button("Erase", role: .destructive) { store.eraseAll() }
        }
    }
}
