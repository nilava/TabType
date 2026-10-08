import SwiftUI
import AppKit

struct SettingsView: View {
    enum Section: String, CaseIterable, Identifiable {
        case setup = "Setup"
        case general = "General"
        case engine = "Engine & Model"
        case context = "Context"
        case personalization = "Personalization"
        case textTools = "Text Tools"
        case emoji = "Emoji"
        case shortcuts = "Shortcuts"
        case battery = "Battery"
        case apps = "Apps"
        case advanced = "Advanced"
        case statistics = "Statistics"
        case about = "About"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .setup: return "checkmark.seal"
            case .general: return "gearshape"
            case .engine: return "cpu"
            case .context: return "doc.text.magnifyingglass"
            case .personalization: return "person.crop.circle"
            case .textTools: return "character.cursor.ibeam"
            case .emoji: return "face.smiling"
            case .shortcuts: return "keyboard"
            case .battery: return "battery.100"
            case .apps: return "app.badge"
            case .advanced: return "slider.horizontal.3"
            case .statistics: return "chart.bar"
            case .about: return "info.circle"
            }
        }
    }

    @State private var selection: Section? = .setup
    @ObservedObject private var navigator = SettingsNavigator.shared

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                HStack(spacing: 8) {
                    SidebarIconBadge(systemImage: section.icon, color: SectionAccent.color(for: section))
                    Text(section.rawValue)
                }
                .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 230)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle((selection ?? .general).rawValue)
        .frame(minWidth: 680, minHeight: 460)
        .onAppear {
            if let pending = navigator.pendingSection {
                selection = pending
                navigator.pendingSection = nil
            }
            navigator.desiredContentWidth = Self.contentWidth(for: selection ?? .general)
        }
        .onChange(of: navigator.pendingSection) { _, pending in
            guard let pending else { return }
            selection = pending
            navigator.pendingSection = nil
        }
        .onChange(of: selection) { _, newValue in
            navigator.desiredContentWidth = Self.contentWidth(for: newValue ?? .general)
        }
    }

    /// The Apps pane hosts a nested HSplitView (app list + detail) that needs more
    /// room; every other pane is a single column and reads better narrower.
    static func contentWidth(for section: Section) -> CGFloat {
        section == .apps ? 980 : 760
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .setup {
        case .setup: SetupPane()
        case .general: GeneralSettingsView()
        case .engine: ModelSettingsView()
        case .context: ContextPane()
        case .personalization: PersonalizationPane()
        case .textTools: TextToolsPane()
        case .emoji: EmojiPane()
        case .shortcuts: ShortcutsPane()
        case .battery: BatteryPane()
        case .apps: AppsSettingsView()
        case .advanced: AdvancedSettingsView()
        case .statistics: StatisticsPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - Live ghost-text preview

private struct GhostPreview: View {
    let opacity: Double
    var body: some View {
        HStack(spacing: 0) {
            Text("I'll send the report ")
            Text("by end of day.")
                .foregroundStyle(.secondary.opacity(opacity))
        }
        .font(.system(size: 15))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle("Enable suggestions", isOn: $settings.isEnabled)
                Toggle("Launch TabType at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in LaunchAtLogin.set(on) }
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
                Toggle("Show floating accessory button", isOn: $settings.showAccessoryButton)
                Toggle("Disable macOS predictive text", isOn: $settings.disableMacOSPredictiveText)
                if settings.disableMacOSPredictiveText {
                    Text("Prevents conflicts with macOS's built-in inline suggestions. Log out and back in to fully apply.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Accepting") {
                Picker("On Tab, insert", selection: $settings.acceptWholeLine) {
                    Text("One word at a time").tag(false)
                    Text("The whole suggestion").tag(true)
                }
                .pickerStyle(.radioGroup)
                Picker("Completion length", selection: $settings.completionLength) {
                    Text("Short (~3 words)").tag("short")
                    Text("Medium (~8 words)").tag("medium")
                    Text("Long (~14 words)").tag("long")
                }
            }

            Section("Appearance") {
                GhostPreview(opacity: settings.ghostOpacity)
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, 4)
                HStack {
                    Text("Ghost text opacity")
                    Slider(value: $settings.ghostOpacity, in: 0.2...1.0)
                }
                Toggle("Text mirroring in web apps", isOn: $settings.textMirroring)
                Text("Redraws your last word together with the suggestion on a matching backdrop, so both align perfectly in apps like Slack or Claude. Turn off to use plain ghost text everywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Timing") {
                Toggle("Suggest continuously while typing", isOn: $settings.continuousGeneration)
                Text(settings.continuousGeneration
                     ? "Requests a suggestion on nearly every keystroke, so completions keep pace with fast typing. Uses more CPU while actively typing. Web apps like Slack or Claude always wait for a brief pause regardless."
                     : "Waits for a pause in typing before requesting a suggestion.")
                    .font(.caption).foregroundStyle(.secondary)
                if !settings.continuousGeneration {
                    HStack {
                        Text("Suggestion delay")
                        Slider(value: Binding(
                            get: { Double(settings.debounceMs) },
                            set: { settings.debounceMs = Int($0) }), in: 40...600, step: 20)
                        Text("\(settings.debounceMs) ms").monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Model manager

struct ModelSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var provider: ModelProvider
    @State private var customId = ""
    @State private var storageTick = 0   // bump to refresh installed sizes

    var body: some View {
        Form {
            Section("Engine") {
                Picker("Suggestions from", selection: $settings.engineChoice) {
                    Text("Local model (recommended)").tag(EngineChoice.llama)
                    Text("Local model — classic MLX engine").tag(EngineChoice.local)
                    Text("Apple Intelligence").tag(EngineChoice.appleIntelligence)
                    Text("Automatic").tag(EngineChoice.auto)
                }
                .pickerStyle(.radioGroup)
                Label("The local model runs entirely on this Mac and never needs a network connection. It shows a suggestion only when it's confident, and completes half-typed words. The classic MLX engine is kept for comparison.",
                      systemImage: "cpu")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if settings.engineChoice != .local {
                LlamaModelSections()
            } else {
                classicModelSections
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var classicModelSections: some View {
        Group {

            Section("Local model") {
                HStack {
                    statusIcon
                    Text(statusText).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if case .downloading(_, let p) = provider.state {
                        ProgressView(value: p).frame(width: 120)
                        Text("\(Int(p * 100))%").font(.caption).foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                    if case .finalizing = provider.state {
                        ProgressView().controlSize(.small)
                    }
                    if case .failed(let modelId, _) = provider.state {
                        Button("Retry") { provider.retry(modelId: modelId) }
                    }
                }
                if case .failed(_, let message) = provider.state {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                ForEach(ModelCatalog.recommended) { model in modelRow(model) }
            } header: {
                Text("Recommended")
            } footer: {
                Text("Recommended for this Mac: \(HardwareInfo.recommendationReason).")
                    .font(.caption)
            }

            Section {
                ForEach(ModelCatalog.other) { model in modelRow(model) }
            } header: {
                Text("Other Models")
            } footer: {
                Text("Instruct models continue text well but may occasionally reply instead of continuing it. Models on disk: \(ModelStorage.formatted(ModelStorage.totalUsed())).")
                    .font(.caption)
                    .id(storageTick)
            }

            Section("Custom Hugging Face model") {
                HStack {
                    TextField("mlx-community/…", text: $customId)
                        .textFieldStyle(.roundedBorder)
                    Button("Load") { select(customId) }
                        .disabled(customId.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Any MLX-format text model from Hugging Face.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Model files") {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [ModelStorage.revealDir(for: settings.modelId)])
                    }
                }
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch provider.state {
        case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .downloading: Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
        case .finalizing: Image(systemName: "gearshape.2").foregroundStyle(.secondary)
        case .idle: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        switch provider.state {
        case .idle: return "Idle"
        case .downloading(let modelId, _): return "Downloading \(modelId.split(separator: "/").last.map(String.init) ?? modelId)…"
        case .finalizing(let modelId): return "Loading \(modelId.split(separator: "/").last.map(String.init) ?? modelId) into memory…"
        case .ready(let id): return id
        case .failed(let modelId, _): return "Failed: \(modelId.split(separator: "/").last.map(String.init) ?? modelId)"
        }
    }

    private func installed(_ id: String) -> Bool {
        _ = storageTick   // re-evaluate when storage changes
        return ModelStorage.isInstalled(id)
    }

    @ViewBuilder
    private func modelRow(_ model: CatalogModel) -> some View {
        Button { select(model.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: settings.modelId == model.id
                      ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(settings.modelId == model.id ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(model.name).fontWeight(.medium)
                        if ModelCatalog.isRecommended(model.id) {
                            Text("Best for you")
                                .font(.caption2).fontWeight(.semibold)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                                .foregroundStyle(Color.accentColor)
                        }
                        if installed(model.id) {
                            Text("Installed · \(ModelStorage.formatted(ModelStorage.size(model.id)))")
                                .font(.caption2)
                                .foregroundStyle(.green)
                        }
                    }
                    Text("\(model.approxSize) · \(model.note)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if installed(model.id) {
                    Button {
                        ModelStorage.delete(model.id)
                        storageTick += 1
                    } label: { Image(systemName: "trash").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .help("Delete downloaded files")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func select(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Don't persist settings.modelId yet — ModelProvider only reports it via
        // onReady once the download/load actually succeeds, so a failed switch never
        // leaves settings pointing at a model that isn't actually loaded.
        provider.load(modelId: trimmed)
    }
}

// MARK: - Apps

/// Per-app override editor: a searchable app list on the left, a detail form of
/// tri-state overrides on the right — matching Cotypist's App Settings pane.
struct AppsSettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @State private var apps: [RunningApp] = []
    @State private var search = ""
    @State private var selected: String?
    @State private var showingDomains = false

    struct RunningApp: Identifiable {
        let id: String       // bundle id
        let name: String
        let icon: NSImage?
    }

    private var filteredApps: [RunningApp] {
        search.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $search).textFieldStyle(.plain)
                }
                .padding(8)
                Divider()
                List(selection: $selected) {
                    Section("Apps") {
                        ForEach(filteredApps) { app in
                            HStack(spacing: 8) {
                                if let icon = app.icon {
                                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                                }
                                Text(app.name)
                                Spacer()
                                if !(settings.appOverrides[app.id]?.isDefault ?? true) {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.caption2).foregroundStyle(Color.accentColor)
                                }
                                ProfileBadge(profile: AppPolicyStore.policy(forBundleId: app.id).profile)
                            }
                            .tag(app.id)
                        }
                    }
                    Section {
                        Label("Websites", systemImage: "globe")
                            .tag("__domains__")
                    }
                }
                .listStyle(.sidebar)
            }
            // Narrow, capped list column so the detail pane always has room — the
            // whole Apps pane must fit at the base window width WITHOUT relying on
            // the window growing (sidebar ~200 + list ~220 + detail ≥300 ≤ 760).
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 280, maxHeight: .infinity)

            Group {
                if selected == "__domains__" {
                    DomainsPane()
                } else if let id = selected, let app = apps.first(where: { $0.id == id }) {
                    AppOverrideDetail(app: app, override: overrideBinding(for: id))
                } else {
                    ContentUnavailableView("Select an app",
                        systemImage: "app.badge",
                        description: Text("Choose an app to customize TabType for it."))
                }
            }
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: reload)
    }

    private func overrideBinding(for id: String) -> Binding<AppOverride> {
        Binding(
            get: { settings.appOverrides[id] ?? AppOverride() },
            set: { newValue in
                if newValue.isDefault { settings.appOverrides.removeValue(forKey: id) }
                else { settings.appOverrides[id] = newValue }
            }
        )
    }

    private func reload() {
        apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .map { RunningApp(id: $0.bundleIdentifier!, name: $0.localizedName ?? $0.bundleIdentifier!, icon: $0.icon) }
            .reduce(into: [RunningApp]()) { acc, app in
                if !acc.contains(where: { $0.id == app.id }) { acc.append(app) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// Small colored tag showing the app's effective context profile — makes the
/// per-app behavior visible at a glance instead of buried in code.
private struct ProfileBadge: View {
    let profile: AppPolicy.Profile

    private var color: Color {
        switch profile {
        case .chat: return .blue
        case .document: return .purple
        case .codeEditor: return .orange
        case .disabled: return .gray
        case .standard: return .secondary.opacity(0.6)
        }
    }

    var body: some View {
        if profile != .standard {
            Text(profile.rawValue)
                .font(.caption2).fontWeight(.medium)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(color.opacity(0.18), in: Capsule())
                .foregroundStyle(color)
        }
    }
}

/// Tri-state: nil = "Default", true = "On", false = "Off".
private struct TriStatePicker: View {
    let title: String
    @Binding var value: Bool?
    var onLabel = "On"
    var offLabel = "Off"

    var body: some View {
        Picker(title, selection: Binding(
            get: { value == nil ? "default" : (value! ? "on" : "off") },
            set: { s in value = s == "default" ? nil : (s == "on") }
        )) {
            Text("Default").tag("default")
            Text(onLabel).tag("on")
            Text(offLabel).tag("off")
        }
    }
}

/// Detail form for one app's override.
private struct AppOverrideDetail: View {
    let app: AppsSettingsView.RunningApp
    @Binding var override: AppOverride

    /// The RESOLVED policy (built-ins + this override) — the card below always
    /// tells the truth, including the effect of edits made right here.
    private var resolved: AppPolicy { AppPolicyStore.policy(forBundleId: app.id) }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable().frame(width: 32, height: 32)
                    }
                    VStack(alignment: .leading) {
                        Text(app.name).font(.title3).bold()
                        Text(app.id).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProfileBadge(profile: resolved.profile)
                }
            }
            Section("How TabType works here") {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(resolved.summaryLines, id: \.self) { line in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(.secondary)
                            Text(line).font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Section("Context") {
                TriStatePicker(title: "Read conversation (accessibility)",
                               value: $override.readConversation)
                Text("Reads the visible conversation via the accessibility tree and keeps context always on — the treatment chat apps get. Turn on for any messaging-like app TabType doesn't recognize.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Context size", selection: Binding(
                    get: { override.contextSize ?? "default" },
                    set: { override.contextSize = $0 == "default" ? nil : $0 }
                )) {
                    Text("Default (\(AppPolicyStore.builtinContextCap(forBundleId: app.id).formatted()) characters)")
                        .tag("default")
                    Text("Small (\(300.formatted()) characters)").tag("small")
                    Text("Large (\(AppPolicyStore.chatContextCap.formatted()) characters)").tag("large")
                }
                Text("How much surrounding text (conversation/screen) is given to the model in this app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Completions") {
                TriStatePicker(title: "Enable completions", value: $override.enabled)
                TriStatePicker(title: "Mid-line completions", value: $override.midLineEnabled)
                Text("Mid-line: show completions even when there's text after the cursor on the same line.")
                    .font(.caption).foregroundStyle(.secondary)
                TriStatePicker(title: "Autocorrect", value: $override.autocorrectEnabled)
                TriStatePicker(title: "Learn from my writing here", value: $override.learnFromWriting)
                TriStatePicker(title: "Disable Tab key", value: $override.disableTabKey,
                              onLabel: "Disabled", offLabel: "Enabled")
                Text("Turn this on for apps where Tab has important native functionality (e.g. indenting, switching fields).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Appearance") {
                LabeledContent("Ghost text size") {
                    HStack {
                        Slider(value: Binding(
                            get: { override.ghostFontScale ?? 1 },
                            set: { override.ghostFontScale = abs($0 - 1) < 0.005 ? nil : $0 }
                        ), in: 0.8...1.2, step: 0.01)
                        Text("\(Int(((override.ghostFontScale ?? 1) * 100).rounded()))%")
                            .monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Vertical offset") {
                    Stepper(value: Binding(
                        get: { override.ghostVerticalOffset ?? 0 },
                        set: { override.ghostVerticalOffset = $0 == 0 ? nil : $0 }
                    ), in: -6...6, step: 0.5) {
                        Text(String(format: "%+.1f pt", override.ghostVerticalOffset ?? 0)).monospacedDigit()
                    }
                }
                Text("Fine-tune the suggestion text if it doesn't line up with this app's text. TabType normally measures the app's font automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Troubleshooting") {
                Toggle("Improve compatibility with this app", isOn: $override.improveCompatibility)
                Text("If completions don't appear reliably in this app, try turning this on — it switches to clipboard-paste insertion.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Custom instructions") {
                TextField("e.g. Use technical, concise language.", text: $override.customInstructions, axis: .vertical)
                    .lineLimit(2...5)
                Text("Additional instructions for the model when completing text in this app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !override.isDefault {
                Section {
                    Button("Reset to Default", role: .destructive) { override = AppOverride() }
                }
            }
        }
        .formStyle(.grouped)
        .id(app.id)
    }
}

/// Per-domain (browser website) disable list.
private struct DomainsPane: View {
    @EnvironmentObject var settings: AppSettings
    @State private var newDomain = ""

    var body: some View {
        Form {
            Section {
                Text("Suggestions are disabled on these domains (and subdomains) in browsers.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Built-in chat websites") {
                Text("On these sites, TabType reads the visible conversation via the accessibility tree (like a chat app) so suggestions follow the discussion. Add a rule below to disable a site instead.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(AppPolicyStore.chatDomains).sorted(), id: \.self) { domain in
                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .foregroundStyle(.blue)
                        Text(domain)
                        Spacer()
                        Text("Chat").font(.caption2).fontWeight(.medium)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.blue.opacity(0.18), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
            }
            Section("Disabled websites") {
                HStack {
                    TextField("e.g. mail.google.com", text: $newDomain)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addDomain)
                    Button("Add", action: addDomain)
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(Array(settings.disabledDomains).sorted(), id: \.self) { domain in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(.secondary)
                        Text(domain)
                        Spacer()
                        Button {
                            settings.disabledDomains.remove(domain)
                        } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Section("Website instructions") {
                Text("Tune suggestions per website — e.g. a different language or tone on a specific site. Applied on top of app settings.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Domain (e.g. linkedin.com)", text: $newInstructionDomain)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                    TextField("Instructions (e.g. Formal tone, no emoji)", text: $newInstructionText)
                        .textFieldStyle(.roundedBorder)
                    Button("Add", action: addDomainInstructions)
                        .disabled(newInstructionDomain.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newInstructionText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(domainInstructionKeys, id: \.self) { key in
                    let host = String(key.dropFirst("domain:".count))
                    HStack(alignment: .top) {
                        Image(systemName: "text.bubble").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(host).fontWeight(.medium)
                            Text(settings.appOverrides[key]?.customInstructions ?? "")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            settings.appOverrides.removeValue(forKey: key)
                        } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @State private var newInstructionDomain = ""
    @State private var newInstructionText = ""

    private var domainInstructionKeys: [String] {
        settings.appOverrides.keys.filter { $0.hasPrefix("domain:") }.sorted()
    }

    private func addDomainInstructions() {
        var d = newInstructionDomain.trimmingCharacters(in: .whitespaces).lowercased()
        d = d.replacingOccurrences(of: "https://", with: "")
             .replacingOccurrences(of: "http://", with: "")
        if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
        let text = newInstructionText.trimmingCharacters(in: .whitespaces)
        guard !d.isEmpty, !text.isEmpty else { return }
        var override = settings.appOverrides[AppPolicyStore.domainKey(d)] ?? AppOverride()
        override.customInstructions = text
        settings.appOverrides[AppPolicyStore.domainKey(d)] = override
        newInstructionDomain = ""
        newInstructionText = ""
    }

    private func addDomain() {
        var d = newDomain.trimmingCharacters(in: .whitespaces).lowercased()
        d = d.replacingOccurrences(of: "https://", with: "")
             .replacingOccurrences(of: "http://", with: "")
        if let slash = d.firstIndex(of: "/") { d = String(d[..<slash]) }
        guard !d.isEmpty else { return }
        settings.disabledDomains.insert(d)
        newDomain = ""
    }
}

// MARK: - Advanced

struct AdvancedSettingsView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Generation") {
                HStack {
                    Text("Creativity (temperature)")
                    Slider(value: $settings.temperature, in: 0.0...1.0, step: 0.05)
                    Text(String(format: "%.2f", settings.temperature)).monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }
                Stepper(value: $settings.maxTokens, in: 6...48, step: 2) {
                    LabeledContent("Max tokens generated", value: "\(settings.maxTokens)")
                }
                Text("A hard ceiling on generation length — General's \"Completion length\" already controls the typical suggestion length you'll see; you usually don't need to change this.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Context window")
                    Slider(value: Binding(
                        get: { Double(settings.contextChars) },
                        set: { settings.contextChars = Int($0) }), in: 100...2400, step: 50)
                    Text("\(settings.contextChars)").monospacedDigit()
                        .foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }
            }
            Section("Diagnostics") {
                Toggle("Verbose logging", isOn: $settings.verboseLog)
                Button("Open Log in Console") {
                    NSWorkspace.shared.open(Log.fileURL)
                }
            }
            Section {
                Label("TabType runs 100% locally. Your text never leaves this Mac.",
                      systemImage: "lock.shield")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset to Defaults", role: .destructive) {
                    settings.temperature = 0.1
                    settings.maxTokens = 28
                    settings.contextChars = 1200
                    settings.verboseLog = false
                }
            }
        }
        .formStyle(.grouped)
    }
}
