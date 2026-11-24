// All LyricsBar credentials (Subsonic token, Spotify tokens, Last.fm session, ListenBrainz token) live in ONE
// login-Keychain item, so macOS asks at most once per new build ("Always Allow" covers that build).
// Older ~/.touchbar-lyrics/*.json credential files are imported on first launch and then deleted.
import Foundation
import Security

enum Creds {
    static let service = "com.crispy.lyricsbar"
    static let account = "credentials"
    private static var cache: [String: [String: String]]?
    private static let lock = NSLock()

    private enum Load { case ok([String: [String: String]]), failed(OSStatus) }

    /// Reads the item. Must be called with `lock` held. A failed read (prompt denied, locked keychain…)
    /// is NOT treated as "empty" — otherwise the next write would wipe every other credential.
    private static func loadLocked() -> Load {
        if let c = cache { return .ok(c) }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        switch st {
        case errSecSuccess:
            guard let d = out as? Data, let j = try? JSONSerialization.jsonObject(with: d) as? [String: [String: String]]
            else { return .failed(errSecDecode) }
            cache = j
            return .ok(j)
        case errSecItemNotFound:
            cache = [:]
            return .ok([:])
        default:
            return .failed(st)       // not cached: try again next time
        }
    }

    /// Everything, e.g. ["subsonic": [...], "spotify": [...]] (empty if the Keychain can't be read right now)
    static var all: [String: [String: String]] {
        lock.lock(); defer { lock.unlock() }
        if case .ok(let c) = loadLocked() { return c }
        return [:]
    }

    static func get(_ key: String) -> [String: String]? { all[key] }

    /// Saves one entry. Returns false (and changes nothing) if the Keychain couldn't be read or written.
    @discardableResult
    static func set(_ key: String, _ value: [String: String]?) -> Bool {
        lock.lock(); defer { lock.unlock() }          // whole read-modify-write under one lock
        guard case .ok(var c) = loadLocked() else { NSLog("LyricsBar: Keychain unavailable, not saving \(key)"); return false }
        c[key] = value
        guard let d = try? JSONSerialization.data(withJSONObject: c) else { return false }
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        var st = SecItemUpdate(base as CFDictionary, [kSecValueData as String: d] as CFDictionary)
        if st == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = d
            add[kSecAttrLabel as String] = "LyricsBar credentials"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            st = SecItemAdd(add as CFDictionary, nil)
        }
        guard st == errSecSuccess else { NSLog("LyricsBar: Keychain write failed (\(st))"); return false }
        cache = c
        return true
    }

    /// One-time move of the old plaintext files into the Keychain.
    static func migrateFiles() {
        for (key, file) in [("subsonic", "subsonic.json"), ("spotify", "spotify.json"),
                            ("lastfm", "lastfm.json"), ("listenbrainz", "listenbrainz.json")] {
            let path = home + "/" + file
            guard let d = FileManager.default.contents(atPath: path),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            var stored = get(key) != nil
            if !stored {
                stored = set(key, j.mapValues { v in (v as? String) ?? (v as? NSNumber)?.stringValue ?? "\(v)" })
            }
            if stored {                  // only delete once the Keychain write actually succeeded
                if let h = FileHandle(forWritingAtPath: path) {    // overwrite before unlinking
                    h.write(Data(repeating: 0, count: d.count)); try? h.synchronize(); try? h.close()
                }
                try? FileManager.default.removeItem(atPath: path)
            }
        }
    }

    /// Credentials the Python helper needs, passed on its stdin (never on the command line or in files).
    static var forHelper: Data {
        let pick = all.filter { ["subsonic", "spotify"].contains($0.key) }
        return (try? JSONSerialization.data(withJSONObject: pick)) ?? Data("{}".utf8)
    }

    /// The helper reports refreshed tokens back as {"__creds": {...}}.
    /// Saves tokens the helper refreshed. Returns false if any of them couldn't be written to the Keychain.
    @discardableResult
    static func absorb(fromHelper j: [String: Any]) -> Bool {
        guard let c = j["__creds"] as? [String: [String: Any]] else { return true }
        var ok = true
        for (k, v) in c { ok = set(k, v.mapValues { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue ?? "\($0)" }) && ok }
        return ok
    }
}
