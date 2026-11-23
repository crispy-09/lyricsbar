// Direct scrobbling from LyricsBar's built-in player to Last.fm and ListenBrainz.
// (The alternative is letting Navidrome forward plays; see Settings → Providers → Scrobbling.)
// Credentials live in the login Keychain (see Keychain.swift).
import Foundation
import CryptoKit
import AppKit

struct ScrobbleTrack {
    let title, artist, album: String
    let duration: Double
}

enum Scrobbler {

    /// Called by the player: song started (nowPlaying) / song counted (scrobble).
    static func nowPlaying(_ t: ScrobbleTrack) {
        if cfg.scrobbleLastfm { Task { try? await LastFM.call("track.updateNowPlaying", params(t)) } }
        if cfg.scrobbleListenBrainz { Task { try? await ListenBrainz.submit("playing_now", t, at: nil) } }
    }
    /// A finished listen: queued per service (saved to disk), then sent. Failures stay queued and retry.
    static func scrobble(_ t: ScrobbleTrack, startedAt: Date, subsonicId: String? = nil) {
        var e: [ScrobbleQueue.Entry] = []
        func entry(_ svc: String) -> ScrobbleQueue.Entry {
            .init(svc: svc, title: t.title, artist: t.artist, album: t.album, duration: t.duration,
                  ts: startedAt.timeIntervalSince1970, sid: subsonicId)
        }
        if cfg.reportPlays, subsonicId != nil, Subsonic.auth != nil { e.append(entry("subsonic")) }
        if cfg.scrobbleLastfm, LastFM.creds?["session"] != nil { e.append(entry("lastfm")) }
        if cfg.scrobbleListenBrainz, ListenBrainz.token != nil { e.append(entry("listenbrainz")) }
        guard !e.isEmpty else { return }
        Task { await ScrobbleQueue.shared.add(e); await ScrobbleQueue.shared.flush() }
    }
    private static func params(_ t: ScrobbleTrack) -> [String: String] {
        var p = ["artist": t.artist, "track": t.title]
        if !t.album.isEmpty { p["album"] = t.album }
        if t.duration > 0 { p["duration"] = String(Int(t.duration)) }
        return p
    }
}

struct ScrobbleError: LocalizedError {
    let message: String
    var permanent = false          // the service rejected it for good → don't retry
    var errorDescription: String? { message }
}

// MARK: - Retry queue (~/.touchbar-lyrics/scrobble-queue.json; song info only, no credentials)

actor ScrobbleQueue {
    static let shared = ScrobbleQueue()
    struct Entry: Codable {
        var id = UUID()
        let svc: String            // "subsonic" | "lastfm" | "listenbrainz"
        let title, artist, album: String
        let duration: Double
        let ts: Double             // when the listen started (unix seconds)
        let sid: String?           // Subsonic song id
    }
    static let path = home + "/scrobble-queue.json"
    private var items: [Entry]
    private var flushing = false

    init() {
        items = FileManager.default.contents(atPath: ScrobbleQueue.path)
            .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    var count: Int { items.count }

    func add(_ e: [Entry]) {
        items += e
        if items.count > 2000 { items.removeFirst(items.count - 2000) }
        save()
    }

    private func save() {
        guard let d = try? JSONEncoder().encode(items) else { return }
        try? d.write(to: URL(fileURLWithPath: ScrobbleQueue.path), options: .atomic)
    }

    /// Sends everything queued, oldest first, in batches. Network/server hiccups leave entries for later.
    func flush() async {
        guard !flushing, !items.isEmpty else { return }
        flushing = true; defer { flushing = false }
        // Last.fm and ListenBrainz ignore listens older than ~2 weeks
        let cutoff = Date().timeIntervalSince1970 - 13 * 86400
        items.removeAll { $0.svc != "subsonic" && $0.ts < cutoff }
        for svc in ["subsonic", "lastfm", "listenbrainz"] {
            while true {
                let batch = Array(items.filter { $0.svc == svc }.prefix(50))
                if batch.isEmpty { break }
                do {
                    try await send(svc, batch)
                } catch let e as ScrobbleError where e.permanent {
                    NSLog("LyricsBar: scrobble rejected by \(svc): \(e.message)")
                } catch let e as SubsonicError where e.code != nil {
                    NSLog("LyricsBar: scrobble rejected by Subsonic: \(e.message)")
                } catch {
                    break                       // offline or temporary: try again later
                }
                let done = Set(batch.map(\.id))
                items.removeAll { done.contains($0.id) }
                save()
            }
        }
    }

    private func send(_ svc: String, _ b: [Entry]) async throws {
        switch svc {
        case "subsonic":
            var p: [(String, String)] = [("submission", "true")]
            for e in b { if let s = e.sid { p.append(("id", s)); p.append(("time", String(Int64(e.ts * 1000)))) } }
            _ = try await Subsonic.call("scrobble", p)
        case "lastfm":
            guard LastFM.creds?["session"] != nil else { throw URLError(.userAuthenticationRequired) }
            var p: [String: String] = [:]
            for (i, e) in b.enumerated() {
                p["artist[\(i)]"] = e.artist; p["track[\(i)]"] = e.title
                p["timestamp[\(i)]"] = String(Int(e.ts))
                if !e.album.isEmpty { p["album[\(i)]"] = e.album }
                if e.duration > 0 { p["duration[\(i)]"] = String(Int(e.duration)) }
            }
            try await LastFM.call("track.scrobble", p)
        default:
            guard ListenBrainz.token != nil else { throw URLError(.userAuthenticationRequired) }
            try await ListenBrainz.submitMany(b.map { (ScrobbleTrack(title: $0.title, artist: $0.artist, album: $0.album,
                                                                       duration: $0.duration), Date(timeIntervalSince1970: $0.ts)) })
        }
    }

    /// Retry on launch and every 5 minutes.
    static func startRetrying() {
        Task.detached {
            while true {
                await ScrobbleQueue.shared.flush()
                try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            }
        }
    }
}

// MARK: - Last.fm (desktop auth: token → approve in browser → session key)

enum LastFM {
    static let api = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    static var creds: [String: String]? { Creds.get("lastfm") }
    static var user: String? { creds?["user"] }

    static func sign(_ p: [String: String], secret: String) -> String {
        let base = p.keys.sorted().map { $0 + p[$0]! }.joined() + secret
        return Insecure.MD5.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Signed POST with the stored session (for scrobbles).
    @discardableResult
    static func call(_ method: String, _ extra: [String: String]) async throws -> [String: Any] {
        guard let c = creds, let key = c["api_key"], let secret = c["secret"], let sk = c["session"] else {
            throw ScrobbleError(message: "Last.fm isn't connected")
        }
        var p = extra; p["method"] = method; p["api_key"] = key; p["sk"] = sk
        p["api_sig"] = sign(p, secret: secret)
        p["format"] = "json"
        return try await post(p)
    }

    static func post(_ p: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: api)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("LyricsBar/1.0", forHTTPHeaderField: "User-Agent")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")  // ASCII only
        req.httpBody = p.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (d, r) = try await URLSession.shared.data(for: req)
        let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        if let msg = j["message"] as? String, let code = (j["error"] as? NSNumber)?.intValue {
            // 9 bad session, 11/16 service trouble, 29 rate limit → retry later; anything else is final
            throw ScrobbleError(message: "Last.fm: \(msg)", permanent: ![9, 11, 16, 29].contains(code))
        }
        if let code = (r as? HTTPURLResponse)?.statusCode, code >= 400 || j.isEmpty {
            // an HTML error page from a proxy / outage is not a success: keep the scrobbles for a retry
            throw ScrobbleError(message: "Last.fm: HTTP \(code)")
        }
        return j
    }

    /// Opens the browser for approval and waits (up to 3 minutes) for the session.
    static func connect(apiKey: String, secret: String) async throws -> String {
        var p = ["method": "auth.getToken", "api_key": apiKey]
        p["api_sig"] = sign(p, secret: secret); p["format"] = "json"
        guard let token = try await post(p)["token"] as? String else { throw ScrobbleError(message: "Last.fm didn't return a token") }
        var c = URLComponents(string: "https://www.last.fm/api/auth/")!
        c.queryItems = [URLQueryItem(name: "api_key", value: apiKey), URLQueryItem(name: "token", value: token)]
        guard let authURL = c.url else { throw ScrobbleError(message: "Invalid API key") }
        await MainActor.run { _ = NSWorkspace.shared.open(authURL) }
        for _ in 0..<90 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            var q = ["method": "auth.getSession", "api_key": apiKey, "token": token]
            q["api_sig"] = sign(q, secret: secret); q["format"] = "json"
            if let s = (try? await post(q))?["session"] as? [String: Any], let key = s["key"] as? String {
                let name = s["name"] as? String ?? ""
                Creds.set("lastfm", ["api_key": apiKey, "secret": secret, "session": key, "user": name])
                return name
            }
        }
        throw ScrobbleError(message: "Timed out waiting for approval in the browser")
    }

    static func disconnect() { Creds.set("lastfm", nil) }
}

// MARK: - ListenBrainz (user token)

enum ListenBrainz {
    static var token: String? { Creds.get("listenbrainz")?["token"] }
    static var user: String? { Creds.get("listenbrainz")?["user"] }

    static func request(_ path: String, body: Any? = nil, token t: String? = nil) async throws -> [String: Any] {
        guard let tok = t ?? token else { throw ScrobbleError(message: "ListenBrainz isn't connected") }
        var req = URLRequest(url: URL(string: "https://api.listenbrainz.org" + path)!)
        req.setValue("Token \(tok)", forHTTPHeaderField: "Authorization")
        req.setValue("LyricsBar/1.0", forHTTPHeaderField: "User-Agent")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (d, r) = try await URLSession.shared.data(for: req)
        let j = (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
        if let code = (r as? HTTPURLResponse)?.statusCode, code >= 400 {
            // 400 = the listen itself is invalid; 401/429/5xx can succeed later
            throw ScrobbleError(message: "ListenBrainz: \(j["error"] as? String ?? "HTTP \(code)")", permanent: code == 400)
        }
        return j
    }

    static func submitMany(_ listens: [(ScrobbleTrack, Date)]) async throws {
        let payload: [[String: Any]] = listens.map { t, at in
            var meta: [String: Any] = ["artist_name": t.artist, "track_name": t.title,
                                       "additional_info": ["media_player": "LyricsBar", "submission_client": "LyricsBar",
                                                           "duration_ms": Int(t.duration * 1000)]]
            if !t.album.isEmpty { meta["release_name"] = t.album }
            return ["track_metadata": meta, "listened_at": Int(at.timeIntervalSince1970)]
        }
        _ = try await request("/1/submit-listens", body: ["listen_type": listens.count == 1 ? "single" : "import", "payload": payload])
    }

    static func submit(_ type: String, _ t: ScrobbleTrack, at: Date?) async throws {
        var meta: [String: Any] = ["artist_name": t.artist, "track_name": t.title,
                                   "additional_info": ["media_player": "LyricsBar", "submission_client": "LyricsBar",
                                                       "duration_ms": Int(t.duration * 1000)]]
        if !t.album.isEmpty { meta["release_name"] = t.album }
        var listen: [String: Any] = ["track_metadata": meta]
        if let at { listen["listened_at"] = Int(at.timeIntervalSince1970) }
        _ = try await request("/1/submit-listens", body: ["listen_type": type, "payload": [listen]])
    }

    /// Checks the token and saves it with the account name.
    static func connect(token t: String) async throws -> String {
        let j = try await request("/1/validate-token", token: t)
        guard j["valid"] as? Bool == true, let name = j["user_name"] as? String else {
            throw ScrobbleError(message: "That token isn't valid")
        }
        Creds.set("listenbrainz", ["token": t, "user": name])
        return name
    }

    static func disconnect() { Creds.set("listenbrainz", nil) }
}
