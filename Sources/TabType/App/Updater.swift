import AppKit
import CryptoKit

/// In-app updates from GitHub Releases (Cotypist auto-updates with Sparkle;
/// TabType has no notarization or appcast signing key, so it does the same job
/// itself): check the latest release, and on request download the DMG, verify it
/// (the SHA-256 published in the release notes, and the same signing identity
/// as the running app), swap the app in place and relaunch. When the app can't
/// be replaced in place, the verified DMG is opened instead.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    struct Release: Equatable {
        var version: String
        var page: URL
        var dmg: URL
        var sha256: String?
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case installing(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private let defaults = UserDefaults.standard
    private static let autoKey = "checkForUpdates"
    private static let lastCheckKey = "lastUpdateCheck"
    /// The release list, not /latest: TabType's releases are marked pre-release,
    /// which /latest skips.
    private static let api = URL(string: "https://api.github.com/repos/nilava/TabType/releases?per_page=10")!

    var automatic: Bool {
        get { defaults.object(forKey: Self.autoKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.autoKey); objectWillChange.send() }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private init() {}

    /// At launch and daily, when automatic checks are on.
    func checkIfDue() {
        guard automatic else { return }
        let last = defaults.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 20 * 3600 else { return }
        Task { await check() }
    }

    func check() async {
        state = .checking
        defaults.set(Date(), forKey: Self.lastCheckKey)
        do {
            var request = URLRequest(url: Self.api)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: request)
            let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            guard let json = list.first(where: { ($0["draft"] as? Bool) != true }),
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
                  let assets = json["assets"] as? [[String: Any]],
                  let dmg = assets.compactMap({ ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) })
                      .first(where: { $0.pathExtension == "dmg" })
            else { state = .failed("No release found"); return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let release = Release(version: version, page: page, dmg: dmg,
                                  sha256: Self.sha256(inNotes: json["body"] as? String ?? ""))
            state = Self.isNewer(version, than: currentVersion) ? .available(release) : .upToDate
            Log.shared.info("updates: latest \(version), running \(currentVersion)")
        } catch {
            state = .failed("Couldn't check for updates")
            Log.shared.info("updates: check failed: \(error)")
        }
    }

    /// "1.10.0" > "1.9.2"; pre-release suffixes are ignored.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// The release notes' "**SHA-256** `…`" line.
    nonisolated static func sha256(inNotes notes: String) -> String? {
        guard let range = notes.range(of: #"SHA-256\**\s*`([0-9a-fA-F]{64})`"#, options: .regularExpression)
        else { return nil }
        let match = String(notes[range])
        return match.range(of: #"[0-9a-fA-F]{64}"#, options: .regularExpression).map { String(match[$0]).lowercased() }
    }

    func install(_ release: Release) {
        state = .installing("Downloading \(release.version)…")
        Task {
            do {
                let (tmp, _) = try await URLSession.shared.download(from: release.dmg)
                let dmg = FileManager.default.temporaryDirectory.appendingPathComponent("TabType-\(release.version).dmg")
                try? FileManager.default.removeItem(at: dmg)
                try FileManager.default.moveItem(at: tmp, to: dmg)

                state = .installing("Verifying…")
                guard let expected = release.sha256 else { throw UpdateError("The release doesn't publish a checksum") }
                let digest = try await Task.detached {
                    SHA256.hash(data: try Data(contentsOf: dmg)).map { String(format: "%02x", $0) }.joined()
                }.value
                guard digest == expected else { throw UpdateError("Checksum mismatch — download discarded") }

                let mount = FileManager.default.temporaryDirectory.appendingPathComponent("TabType-update-\(UUID().uuidString)")
                try await Self.background { try Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-mountpoint", mount.path]) }
                defer { try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
                let newApp = mount.appendingPathComponent("TabType.app")
                let bundlePath = Bundle.main.bundlePath
                let same = try await Self.background {
                    try Self.signingAuthority(newApp.path) == Self.signingAuthority(bundlePath)
                }
                guard same else {
                    throw UpdateError("The update isn't signed like this copy of TabType — not installed")
                }

                state = .installing("Installing…")
                let current = URL(fileURLWithPath: Bundle.main.bundlePath)
                let staged = current.deletingLastPathComponent().appendingPathComponent(".TabType-update.app")
                do {
                    try? FileManager.default.removeItem(at: staged)
                    try await Self.background { try Self.run("/usr/bin/ditto", [newApp.path, staged.path]) }
                    _ = try FileManager.default.replaceItemAt(current, withItemAt: staged)
                } catch {
                    // Can't write next to the app (e.g. admin-owned folder): hand the
                    // verified DMG to the user.
                    NSWorkspace.shared.open(dmg)
                    throw UpdateError("Couldn't replace the app — drag the new TabType from the opened disk image")
                }
                Log.shared.info("updates: installed \(release.version), relaunching")
                let path = current.path
                try Self.run("/bin/sh", ["-c", "(sleep 1; /usr/bin/open \"\(path)\") >/dev/null 2>&1 &"])
                NSApp.terminate(nil)
            } catch {
                state = .failed("\(error)")
                Log.shared.info("updates: install failed: \(error)")
            }
        }
    }

    // MARK: Helpers

    struct UpdateError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// Run blocking work (disk images, codesign, copying) off the main thread.
    @discardableResult
    nonisolated private static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated) { try work() }.value
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard p.terminationStatus == 0 else { throw UpdateError("\(URL(fileURLWithPath: tool).lastPathComponent) failed: \(text)") }
        return text
    }

    /// The leaf signing authority ("TabType Dev"), after a strict verification.
    nonisolated private static func signingAuthority(_ path: String) throws -> String {
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", path])
        let info = try run("/usr/bin/codesign", ["-dvv", path])
        guard let line = info.split(separator: "\n").first(where: { $0.hasPrefix("Authority=") }) else {
            throw UpdateError("Unsigned app")
        }
        return String(line.dropFirst("Authority=".count))
    }
}
