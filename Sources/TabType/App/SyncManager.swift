import Combine
import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Sync between Macs through iCloud Drive, end-to-end encrypted (Cotypist syncs
/// over iCloud too; CloudKit needs a paid developer account, iCloud Drive
/// doesn't). Each Mac writes one AES-GCM-sealed file to
/// iCloud Drive/TabType Sync/ with its settings and learned writing; the key is
/// derived from a passphrase the user sets on every Mac, so Apple only ever
/// stores ciphertext. Merge: the newest settings win; writing is combined.
@MainActor
final class SyncManager: ObservableObject {
    static let shared = SyncManager()

    @Published private(set) var status = ""
    @Published private(set) var otherMacs = 0

    private let defaults = UserDefaults.standard
    private let settings = AppSettings.shared
    private var settingsWatch: AnyCancellable?
    private var timer: Timer?
    private var pendingSync: DispatchWorkItem?
    private var applyingRemote = false

    private static let enabledKey = "syncEnabled"
    private static let machineKey = "syncMachineID"
    private static let settingsChangedKey = "syncSettingsChangedAt"
    private static let keychainService = "app.tabtype.sync"

    var enabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set {
            defaults.set(newValue, forKey: Self.enabledKey)
            objectWillChange.send()
            if newValue { start() } else { stop(); status = "" }
        }
    }

    var hasPassphrase: Bool { Self.readPassphrase() != nil }

    /// iCloud Drive's folder for TabType (nil when iCloud Drive is off).
    var folder: URL? {
        let drive = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
        return drive.appendingPathComponent("TabType Sync", isDirectory: true)
    }

    private var machineID: String {
        if let id = defaults.string(forKey: Self.machineKey) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.machineKey)
        return id
    }

    private var settingsChangedAt: Date {
        get { defaults.object(forKey: Self.settingsChangedKey) as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: Self.settingsChangedKey) }
    }

    private init() {}

    func start() {
        guard enabled else { return }
        settingsWatch = settings.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.applyingRemote else { return }
                self.settingsChangedAt = Date()
                self.scheduleSync(after: 5)
            }
        }
        WritingStore.shared.onSyncNeeded = { [weak self] in self?.scheduleSync(after: 30) }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 10 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { SyncManager.shared.syncNow() }
        }
        syncNow()
    }

    func stop() {
        settingsWatch = nil
        timer?.invalidate()
        timer = nil
        WritingStore.shared.onSyncNeeded = nil
    }

    func setPassphrase(_ passphrase: String) {
        guard passphrase.count >= 8 else { status = "Use at least 8 characters"; return }
        Self.storePassphrase(passphrase)
        objectWillChange.send()
        syncNow()
    }

    private func scheduleSync(after delay: TimeInterval) {
        pendingSync?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        pendingSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Sync

    struct Payload: Codable {
        var machine: String
        var written: Date
        var settingsChangedAt: Date
        var settings: SyncedSettings
        var writing: [WritingStore.Document]
    }

    func syncNow() {
        guard enabled else { return }
        guard let folder else { status = "Turn on iCloud Drive to sync"; return }
        guard let passphrase = Self.readPassphrase() else { status = "Set a sync passphrase"; return }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let key = try Self.key(passphrase: passphrase, salt: try Self.salt(in: folder))

            // Read the other Macs first, then write ours with the merged result.
            var others = 0
            var unreadable = 0
            for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            where file.pathExtension == "tabtypesync" && file.deletingPathExtension().lastPathComponent != machineID {
                guard let sealed = try? Data(contentsOf: file),
                      let box = try? AES.GCM.SealedBox(combined: sealed),
                      let data = try? AES.GCM.open(box, using: key),
                      let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
                    unreadable += 1
                    continue
                }
                others += 1
                WritingStore.shared.merge(payload.writing)
                if payload.settingsChangedAt > settingsChangedAt {
                    applyingRemote = true
                    settings.apply(payload.settings)
                    applyingRemote = false
                    settingsChangedAt = payload.settingsChangedAt
                }
            }

            let mine = Payload(machine: Host.current().localizedName ?? "Mac", written: Date(),
                               settingsChangedAt: settingsChangedAt, settings: settings.syncSnapshot,
                               writing: WritingStore.shared.allDocuments)
            let sealed = try AES.GCM.seal(try JSONEncoder().encode(mine), using: key).combined!
            try sealed.write(to: folder.appendingPathComponent("\(machineID).tabtypesync"), options: .atomic)

            otherMacs = others
            let time = Date().formatted(date: .omitted, time: .shortened)
            status = unreadable > 0
                ? "Synced at \(time) — \(unreadable) Mac(s) use a different passphrase"
                : "Synced at \(time) with \(others) other Mac\(others == 1 ? "" : "s")"
        } catch {
            status = "Sync failed: \(error.localizedDescription)"
            Log.shared.info("sync: \(error)")
        }
    }

    // MARK: Keys

    /// The folder's shared random salt (made by the first Mac to sync).
    private static func salt(in folder: URL) throws -> Data {
        let url = folder.appendingPathComponent("salt")
        if let salt = try? Data(contentsOf: url), salt.count == 16 { return salt }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, 16, &bytes) == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        let salt = Data(bytes)
        try salt.write(to: url, options: .atomic)
        return salt
    }

    /// PBKDF2-HMAC-SHA256, 200k rounds.
    nonisolated static func key(passphrase: String, salt: Data) throws -> SymmetricKey {
        var derived = [UInt8](repeating: 0, count: 32)
        let pw = Array(passphrase.utf8)
        let status = salt.withUnsafeBytes { saltPtr in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { Int8(bitPattern: $0) }, pw.count,
                                 saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 200_000, &derived, derived.count)
        }
        guard status == kCCSuccess else { throw CocoaError(.coderInvalidValue) }
        return SymmetricKey(data: derived)
    }

    private static func readPassphrase() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func storePassphrase(_ passphrase: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: keychainService]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(passphrase.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}
