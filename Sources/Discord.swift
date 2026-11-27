// Discord Rich Presence: shows what's playing (any player LyricsBar follows) on your Discord profile.
// Text is built from templates set in Settings → Discord. Talks to Discord / Vesktop through DiscordIPC.
import AppKit

final class DiscordPresence: ObservableObject {
    static let shared = DiscordPresence()
    static let placeholders = ["{title}", "{artist}", "{album}", "{lyric}", "{player}"]

    struct Snapshot {
        var title = "", artist = "", album = "", lyric = "", player = "", bundle = ""
        var playing = false
        var elapsed = 0.0, duration = 0.0
    }

    private let q = DispatchQueue(label: "lyricsbar.discord")
    private let ipc = DiscordIPC()
    // touched only on q
    private var lastKey = ""
    private var lastSent = Date.distantPast
    private var retryAt = Date.distantPast
    // main thread
    private var lastEval = Date.distantPast
    private var wasOn = false
    private var heard = ""                       // the browser item (bundle|title) last heard making sound
    private var art: [String: String] = [:]        // "artist|album" → artwork URL ("" = none found)
    private var artLoading = Set<String>()
    private var artFailedAt: [String: Date] = [:]  // network errors: try again after a minute
    /// Shown in Settings.
    @Published private(set) var status = "Off"
    var socketOverride: [String]?                  // tests

    // MARK: what's playing

    /// The same sources the Touch Bar uses: the system Now Playing feed, else LyricsBar's own (paused) queue.
    func snapshot() -> Snapshot? {
        var s = Snapshot()
        if let d = FileManager.default.contents(atPath: home + "/state.json"),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            s.title = j["title"] as? String ?? ""; s.artist = j["artist"] as? String ?? ""
            s.album = j["album"] as? String ?? ""; s.bundle = j["bundle"] as? String ?? ""
            s.playing = j["playing"] as? Bool ?? false
            let el = j["elapsed"] as? Double ?? 0, anchor = j["anchor"] as? Double ?? 0, rate = j["rate"] as? Double ?? 0
            s.elapsed = el + (s.playing ? (Date().timeIntervalSince1970 - anchor) * rate : 0)
            s.duration = j["duration"] as? Double ?? 0
        }
        // A browser also announces the silent previews that play while the mouse rests on a thumbnail. Those never
        // go on the profile: a browser's item counts once the browser is heard, and then for as long as it stays up.
        if Self.isBrowser(s.bundle), !s.title.isEmpty {
            let item = s.bundle + "|" + s.title
            if s.playing, AudioTap.isAudible(s.bundle) { heard = item }
            if heard != item { s = Snapshot() }
        }
        let sp = StreamPlayer.shared
        if (s.title.isEmpty || s.bundle == Bundle.main.bundleIdentifier), sp.active, sp.tracks.indices.contains(sp.index) {
            let t = sp.tracks[sp.index]
            s.title = t.title; s.artist = t.artist; s.album = t.album; s.duration = t.duration
            s.bundle = Bundle.main.bundleIdentifier ?? ""
            s.playing = sp.player.timeControlStatus == .playing
            let e = sp.player.currentTime().seconds
            s.elapsed = e.isFinite ? e : 0
        }
        guard !s.title.isEmpty else { return nil }
        if let l = try? String(contentsOfFile: home + "/current.txt", encoding: .utf8),
           !l.hasPrefix("♪") { s.lyric = l.trimmingCharacters(in: .whitespacesAndNewlines) }
        s.player = s.bundle == Bundle.main.bundleIdentifier ? "LyricsBar"
            : NSRunningApplication.runningApplications(withBundleIdentifier: s.bundle).first?.localizedName
            ?? (s.bundle.isEmpty ? "" : s.bundle)
        return s
    }

    static func fill(_ template: String, _ s: Snapshot) -> String {
        var out = template
        for (k, v) in [("{title}", s.title), ("{artist}", s.artist), ("{album}", s.album),
                       ("{lyric}", s.lyric), ("{player}", s.player)] {
            out = out.replacingOccurrences(of: k, with: v)
        }
        out = out.split(whereSeparator: \.isWhitespace).joined(separator: " ")   // tidy gaps left by empty fields
        // drop a dangling joiner when a field was empty ("by ", " · ", "— ")
        for j in ["by", "·", "—", "-", "|", "•", "on", "from"] {
            if out == j { return "" }
            if out.hasSuffix(" " + j) { out = String(out.dropLast(j.count + 1)) }
            if out.hasPrefix(j + " ") && j != "by" && j != "on" && j != "from" { out = String(out.dropFirst(j.count + 1)) }
        }
        return out
    }

    static func isBrowser(_ bundle: String) -> Bool {
        let b = bundle.lowercased()
        return ["com.apple.safari", "com.apple.webkit", "com.google.chrome", "org.chromium", "org.mozilla", "company.thebrowser",
                "com.microsoft.edgemac", "com.brave.browser", "com.operasoftware", "com.vivaldi", "app.zen-browser",
                "com.kagi.kagimacos", "org.torproject", "net.imput.helium", "ai.perplexity.comet", "com.openai.atlas"]
            .contains { b.hasPrefix($0) }
    }

    /// Discord wants 2–128 characters per text field.
    private static func field(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2 else { return nil }
        return t.count > 128 ? String(t.prefix(127)) + "…" : t
    }

    /// The activity to show (nil = show nothing). Pure: used by the Settings preview too.
    func activity(for snap: Snapshot?, _ c: Config, now: Date = Date()) -> [String: Any]? {
        guard let s = snap else { return nil }
        switch c.discordPlayers {
        case "own": if s.bundle != Bundle.main.bundleIdentifier { return nil }
        case "noSpotify": if s.bundle == "com.spotify.client" { return nil }   // Spotify shows its own presence
        default: break
        }
        // a browser's Now Playing is whatever tab makes sound (videos, calls): not for a public profile unless asked
        if !c.discordBrowsers, Self.isBrowser(s.bundle) { return nil }
        if !s.playing && c.discordWhenPaused == "hide" { return nil }
        var a: [String: Any] = ["type": c.discordType == "playing" ? 0 : 2]
        // "Listening to <name>": Vesktop/arRPC uses this name if given, else your Discord application's name
        if let n = Self.field(Self.fill(c.discordName, s)) { a["name"] = n }
        if let d = Self.field(Self.fill(c.discordLine1, s)) { a["details"] = d }
        var line2 = Self.fill(c.discordLine2, s)
        if !s.playing { line2 = line2.isEmpty ? "Paused" : "Paused · " + line2 }
        if let st = Self.field(line2) { a["state"] = st }
        if a["details"] == nil && a["state"] == nil { a["details"] = Self.field(s.title) ?? "Listening" }
        if c.discordTimestamps, s.playing, s.duration > 0 {
            let start = now.timeIntervalSince1970 - min(s.elapsed, s.duration)
            a["timestamps"] = ["start": Int64(start * 1000), "end": Int64((start + s.duration) * 1000)]
        }
        var assets: [String: Any] = [:]
        if let hover = Self.field(Self.fill(c.discordHover, s)) { assets["large_text"] = hover }
        if c.discordAlbumArt, let u = art[artKey(s)], !u.isEmpty { assets["large_image"] = u }
        else if !c.discordImage.isEmpty { assets["large_image"] = c.discordImage }
        if assets["large_image"] != nil { a["assets"] = assets }
        // which text Discord puts in the member list ("Listening to …")
        a["status_display_type"] = ["details": 2, "state": 1][c.discordStatusDisplay] ?? 0
        return a
    }

    // MARK: album art (optional, from Apple's public iTunes Search API — no account, no key)

    private func artKey(_ s: Snapshot) -> String { (s.artist + "|" + (s.album.isEmpty ? s.title : s.album)).lowercased() }

    private func lookUpArt(_ s: Snapshot) {
        let key = artKey(s)
        guard art[key] == nil, !artLoading.contains(key), !s.artist.isEmpty else { return }
        if let t = artFailedAt[key], Date().timeIntervalSince(t) < 60 { return }
        artLoading.insert(key)
        var u = URLComponents(string: "https://itunes.apple.com/search")!
        u.queryItems = [.init(name: "term", value: s.artist + " " + (s.album.isEmpty ? s.title : s.album)),
                        .init(name: "entity", value: s.album.isEmpty ? "song" : "album"),
                        .init(name: "limit", value: "1")]
        URLSession.shared.dataTask(with: u.url!) { [weak self] d, resp, _ in
            let j = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200 && j?["results"] != nil
            let first = (j?["results"] as? [[String: Any]])?.first
            let url = (first?["artworkUrl100"] as? String)?.replacingOccurrences(of: "100x100bb", with: "512x512bb") ?? ""
            DispatchQueue.main.async {
                self?.artLoading.remove(key)
                // a network error is retried on a later tick; "" only means Apple really has no cover
                guard ok else { self?.artFailedAt[key] = Date(); return }
                // only keep https URLs from Apple's image CDN
                self?.art[key] = (url.hasPrefix("https://") && url.contains(".mzstatic.com/")) ? url : ""
            }
        }.resume()
    }

    // MARK: sending

    /// Called from the app's main tick; does real work at most once a second.
    func tick() {
        let now = Date()
        guard now.timeIntervalSince(lastEval) >= 1 else { return }
        lastEval = now
        let c = cfg
        let appId = c.discordAppId.trimmingCharacters(in: .whitespaces)
        guard c.discordEnabled, !appId.isEmpty, appId.allSatisfy(\.isNumber) else {
            if wasOn { wasOn = false; q.async { _ = self.ipc.setActivity(nil); self.ipc.close(); self.lastKey = "" } }
            setStatus(c.discordEnabled ? "Add your Application ID below" : "Off")
            return
        }
        wasOn = true
        let snap = snapshot()
        if c.discordAlbumArt, let s = snap { lookUpArt(s) }
        let act = activity(for: snap, c, now: now)
        // what counts as "changed": everything except the timestamps' drift (unless it moved by > 3 s, i.e. a seek)
        var keyObj = act ?? [:]
        if let ts = keyObj["timestamps"] as? [String: Int64] { keyObj["timestamps"] = (ts["start"] ?? 0) / 3000 }
        let key = appId + ((try? JSONSerialization.data(withJSONObject: keyObj, options: .sortedKeys))
            .map { String(decoding: $0, as: UTF8.self) } ?? "")
        let summary = (act?["details"] as? String) ?? ""
        q.async { self.send(act, key: key, appId: appId, summary: summary) }
    }

    private func send(_ act: [String: Any]?, key: String, appId: String, summary: String) {
        let now = Date()
        // unchanged: nothing to send, except a refresh every minute (a dead socket is only noticed on write,
        // so this is how presence comes back after Discord restarts)
        if key == lastKey && ipc.isConnected && now.timeIntervalSince(lastSent) < 60 { return }
        if now.timeIntervalSince(lastSent) < 4 { return }          // Discord allows ~5 updates / 20 s; next tick retries
        if !ipc.isConnected || ipc.clientId != appId {
            guard now >= retryAt else { return }
            guard ipc.connect(clientId: appId, paths: socketOverride) else {
                retryAt = now.addingTimeInterval(15)
                setStatus("Discord isn't running (or Rich Presence is off in it)")
                return
            }
        }
        guard let reply = ipc.setActivity(act) else {
            setStatus("Lost the connection to Discord; retrying")
            retryAt = now.addingTimeInterval(5)
            return
        }
        lastSent = now
        if (reply["evt"] as? String) == "ERROR" {
            let msg = (reply["data"] as? [String: Any])?["message"] as? String ?? "unknown error"
            setStatus("Discord refused it: \(msg)")
            lastKey = key                                          // don't hammer it with the same bad payload
            return
        }
        lastKey = key
        setStatus(act == nil ? "Connected (nothing shown right now)" : "Showing: \(summary)")
    }

    private func setStatus(_ s: String) {
        DispatchQueue.main.async { if self.status != s { self.status = s } }
    }
}

