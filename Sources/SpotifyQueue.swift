// Spotify's Up Next, editable from the Touch Bar strip and the Library window.
// The Web API can read the queue and add to it, but has no remove/reorder/clear: edits (library.py
// spotify-replace) mute Spotify, skip through the queue to empty it, then play the edited list.
// That would interrupt the current song, so while Spotify plays, edits are shown straight away but only
// sent in the last moments of the song (`pending`), and then start the new list in place of the next song.
// While paused they're sent at once (silently, keeping the current song and its position). Needs Spotify Premium and the user-modify-playback-state scope.
import AppKit

final class SpotifyQueue: ObservableObject {
    static let shared = SpotifyQueue()

    struct Item: Identifiable {
        let id: UUID                 // stable across refreshes (same song in the same slot keeps its id)
        let uri: String, title: String, artist: String, album: String, duration: Double
        let image: URL?
        let rawIndex: Int            // position in Spotify's own queue (local files included)
        var replayable: Bool { SpotifyQueue.validURI(uri) }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var error: String?
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    /// Edits are waiting for the current song to end.
    @Published private(set) var pending = false
    private var pendingTitle = ""               // the song the edits wait for ("" = learn it once things settle)
    private var expectedNext: String?           // what Spotify itself would play next (its real queue's first song)
    private var lastRemaining = Double.infinity // seconds left in pendingTitle when last seen
    private var settleUntil = Date.distantPast  // right after a send, Now Playing is still catching up
    private var pendingTimer: Timer?
    private var pausedSince: Date?, changedSince: Date?, awaySince: Date?   // act only on steady states

    private var gen = 0                         // only the newest refresh may publish
    private var waiting: [() -> Void] = []      // refresh callers; all called when the newest one lands
    private var ids: [String: UUID] = [:]       // "uri#n" (n-th time that song is queued) → id
    private var replayPending = false           // edits made while one was being sent: send the latest list after it
    private var pendingDone: [(String?) -> Void] = []

    /// Songs and episodes; the only kinds Spotify lets us put back into a play list.
    static func validURI(_ u: String) -> Bool {
        let parts = u.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "spotify" && (parts[1] == "track" || parts[1] == "episode")
            && parts[2].count == 22 && parts[2].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    /// Anything Spotify lists (local files too), checked before it goes to the helper as an argument.
    static func listedURI(_ u: String) -> Bool {
        u.hasPrefix("spotify:") && u.count < 400 && u.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 32 }
    }

    func refresh(_ done: (() -> Void)? = nil) {
        if let done { waiting.append(done) }
        gen += 1; let g = gen
        libraryJSON(["queue", "spotify"]) { [weak self] obj, err in
            DispatchQueue.main.async {
                guard let self, g == self.gen else { return }          // a newer refresh will call `waiting`
                self.loaded = true
                if self.pending {                       // Spotify still has the old queue: keep showing the edited one
                } else if let list = obj as? [[String: Any]] {
                    self.error = nil
                    var seen: [String: Int] = [:], newIds: [String: UUID] = [:]
                    self.items = list.enumerated().compactMap { i, d in
                        let uri = d["uri"] as? String ?? ""
                        guard Self.listedURI(uri) else { return nil }
                        let n = seen[uri, default: 0]; seen[uri] = n + 1
                        let key = "\(uri)#\(n)"
                        let id = self.ids[key] ?? UUID(); newIds[key] = id
                        let img = (d["image"] as? String).flatMap { $0.hasPrefix("https://") ? URL(string: $0) : nil }
                        return Item(id: id, uri: uri, title: d["title"] as? String ?? "?", artist: d["artist"] as? String ?? "",
                                    album: d["album"] as? String ?? "", duration: d["duration"] as? Double ?? 0,
                                    image: img, rawIndex: i)
                    }
                    self.ids = newIds
                } else {
                    self.error = Self.friendly(err)
                }
                let w = self.waiting; self.waiting = []
                w.forEach { $0() }
            }
        }
    }

    static func friendly(_ err: String?) -> String {
        let e = err ?? ""
        if e.contains("scope") || e.contains("401") || e.lowercased().contains("reconnect") {
            return "Reconnect Spotify in Settings → Providers to edit Up Next"
        }
        return e.isEmpty ? "Couldn't load Spotify's queue" : e
    }

    /// Play a queued song now: the helper finds it in Spotify's current queue and skips exactly to it.
    func jump(id: UUID, _ done: ((String?) -> Void)? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { done?("That song isn't in the queue any more"); return }
        guard !busy else { done?("Still saving the last change…"); return }
        let t = items[i]
        if pending {                            // Spotify's queue isn't the one shown: start the shown list from here
            let list = Array(items[i...])
            guard list.allSatisfy(\.replayable) else { done?("Spotify can't re-queue local files"); return }
            stopPending()
            items.removeFirst(i + 1)
            send(["spotify-replace", "--start"] + list.map(\.uri), done)
            return
        }
        items.removeFirst(i + 1)                // optimistic
        send(["spotify-jump", t.uri, String(t.rawIndex)], done)
    }

    func remove(id: UUID, _ done: ((String?) -> Void)? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { done?("That song isn't in the queue any more"); return }
        guard canReplay(done) else { return }
        let next = items.first?.title
        items.remove(at: i)
        replay(next, done)
    }

    func reorder(_ ids: [UUID], _ done: ((String?) -> Void)? = nil) {
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let new = ids.compactMap { byId[$0] }
        guard new.count == items.count, new.map(\.id) != items.map(\.id) else { return }
        guard canReplay(done) else { refreshSoon(); return }
        let next = items.first?.title
        items = new
        replay(next, done)
    }

    private func canReplay(_ done: ((String?) -> Void)?) -> Bool {
        if items.contains(where: { !$0.replayable }) {
            done?("Spotify can't re-queue local files, so this queue can't be edited")
            return false
        }
        return true
    }

    /// Leaves only the current song (and Spotify's autoplay after it).
    func clear(_ done: ((String?) -> Void)? = nil) {
        guard !items.isEmpty else { done?("Up Next is already empty"); return }
        guard canReplay(done) else { return }
        let next = items.first?.title
        items = []
        replay(next, done)
    }

    /// Forget edits that are still waiting (the user started other music) and show Spotify's real queue.
    func cancelPending() {
        guard pending else { return }
        stopPending()
        refreshSoon()
    }

    /// `realNext`: the song Spotify itself would play next, before this edit (nil if unknown).
    private func replay(_ realNext: String? = nil, _ done: ((String?) -> Void)?) {
        if let s = DiscordPresence.shared.snapshot(), s.bundle == "com.spotify.client", s.playing {
            // playing: don't interrupt the song; send the edit when it's about to end
            if !pending {
                // while a send is landing, Now Playing may still show the old song: learn it later
                pendingTitle = busy ? "" : s.title
                expectedNext = busy ? nil : realNext
                lastRemaining = .infinity
                pausedSince = nil; changedSince = nil; awaySince = nil
            }
            pending = true
            savePending()
            if pendingTimer == nil {
                let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkPending() }
                RunLoop.main.add(t, forMode: .common)
                pendingTimer = t
            }
            done?(nil)
            return
        }
        stopPending()
        sendReplay(done)
    }

    private func stopPending() {
        pending = false
        pendingTimer?.invalidate(); pendingTimer = nil
        try? FileManager.default.removeItem(atPath: Self.pendingFile)
    }

    // MARK: held edits survive a restart (song names and Spotify links only, nothing secret)

    private static let pendingFile = home + "/spotify-pending.json"

    private func savePending() {
        let list: [[String: Any]] = items.map { ["uri": $0.uri, "title": $0.title, "artist": $0.artist, "album": $0.album,
                                                  "duration": $0.duration, "image": $0.image?.absoluteString ?? ""] }
        let obj: [String: Any] = ["title": pendingTitle, "next": expectedNext ?? "", "items": list]
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        FileManager.default.createFile(atPath: Self.pendingFile, contents: d, attributes: [.posixPermissions: 0o600])
    }

    /// At launch: pick held edits back up if the song they were waiting for is still the one in Spotify.
    func restorePending() {
        guard let d = FileManager.default.contents(atPath: Self.pendingFile),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let title = o["title"] as? String, !title.isEmpty,
              let list = o["items"] as? [[String: Any]] else {
            try? FileManager.default.removeItem(atPath: Self.pendingFile); return
        }
        guard let s = DiscordPresence.shared.snapshot(), s.bundle == "com.spotify.client", s.title == title else {
            try? FileManager.default.removeItem(atPath: Self.pendingFile); return   // the song moved on: too late
        }
        items = list.enumerated().compactMap { i, d in
            guard let uri = d["uri"] as? String, Self.validURI(uri) else { return nil }
            let img = (d["image"] as? String).flatMap { $0.hasPrefix("https://") ? URL(string: $0) : nil }
            return Item(id: UUID(), uri: uri, title: d["title"] as? String ?? "?", artist: d["artist"] as? String ?? "",
                        album: d["album"] as? String ?? "", duration: d["duration"] as? Double ?? 0, image: img, rawIndex: i)
        }
        loaded = true
        pendingTitle = title
        expectedNext = (o["next"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        lastRemaining = .infinity
        pausedSince = nil; changedSince = nil; awaySince = nil
        pending = true
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkPending() }
        RunLoop.main.add(t, forMode: .common)
        pendingTimer = t
        log("picked up held edits after a restart (waiting for \(title))")
    }

    // MARK: song timing when Now Playing doesn't report a length

    private var appTiming: (duration: Double, position: Double, at: Date)?
    private var appTimingAsked = Date.distantPast
    /// Asks the Spotify app (already running: it's what's playing) for its song length and position.
    private func askAppTiming() {
        guard Date().timeIntervalSince(appTimingAsked) >= 2 else { return }
        appTimingAsked = Date()
        DispatchQueue.global(qos: .utility).async {
            let p = Process(); let out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"Spotify\" to return ((duration of current track) / 1000 as text) & \",\" & (player position as text)"]
            p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            p.waitUntilExit()
            let parts = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: " ")
                .split(separator: " ").compactMap { Double($0) }
            guard parts.count >= 2 else { return }
            DispatchQueue.main.async { self.appTiming = (parts[0], parts[parts.count - 1], Date()) }
        }
    }

    /// Sends the held edits when the song is about to end, when it changed anyway (skipped), or when paused.
    private enum Trigger: String { case paused = "paused", changed = "song changed", ending = "song ending" }
    private var confirming = false

    private func checkPending() {
        guard pending, !busy, !confirming else { return }
        let now = Date()
        guard now >= settleUntil else { return }
        guard let s = DiscordPresence.shared.snapshot(), s.bundle == "com.spotify.client" else {
            // the user moved to another player: the held edits no longer apply
            awaySince = awaySince ?? now
            if now.timeIntervalSince(awaySince!) >= 5 { log("other player for 5 s: dropped"); cancelPending() }
            return
        }
        awaySince = nil
        if pendingTitle.isEmpty { pendingTitle = s.title; return }
        pausedSince = s.playing ? nil : (pausedSince ?? now)
        changedSince = s.title == pendingTitle ? nil : (changedSince ?? now)
        // seconds left in the song; if Now Playing has no length, ask the Spotify app itself
        var remaining: Double?
        if s.duration > 0 { remaining = s.duration - s.elapsed }
        else if s.title == pendingTitle {
            askAppTiming()
            if let t = appTiming, now.timeIntervalSince(t.at) < 5 {
                remaining = t.duration - t.position - (s.playing ? now.timeIntervalSince(t.at) : 0)
            }
        }
        if s.title == pendingTitle, let r = remaining { lastRemaining = r }
        let trigger: Trigger
        if let p = pausedSince { guard now.timeIntervalSince(p) >= 2 else { return }; trigger = .paused }
        else if let c = changedSince { guard now.timeIntervalSince(c) >= 0.4 else { return }; trigger = .changed }
        else if let r = remaining, r <= 1.5 { trigger = .ending }
        else { return }
        let seen = String(format: "now playing: %@ %@ %.1f/%.1f s", s.title, s.playing ? "playing" : "paused", s.elapsed, s.duration)
        // Now Playing has fired false alarms mid-song: check with the Spotify app itself before acting
        confirming = true
        Self.appState { [weak self] app in
            guard let self else { return }
            self.confirming = false
            guard self.pending, !self.busy else { return }
            self.decide(trigger, app, snapshotTitle: s.title, seen: seen)
        }
    }

    private func decide(_ trigger: Trigger, _ app: AppState?, snapshotTitle: String, seen: String) {
        let appText = app.map { String(format: "app: %@ %@ %.1f/%.1f s", $0.name, $0.playing ? "playing" : "paused", $0.position, $0.duration) } ?? "app: unknown"
        let falseAlarm = { (why: String) in
            self.log("\(trigger.rawValue)? \(seen) | \(appText) → ignored (\(why))")
            self.pausedSince = nil; self.changedSince = nil
        }
        var start = true
        var title = snapshotTitle
        switch trigger {
        case .paused:
            if let app, app.playing { return falseAlarm("still playing") }
            start = false
        case .changed, .ending:
            if let app {
                title = app.name
                if app.name == pendingTitle {
                    let left = app.duration - app.position
                    guard left <= 2.5 else { return falseAlarm("same song, \(Int(left)) s left") }
                    lastRemaining = left
                }
            }
            if title != pendingTitle {
                // the song ended, or the user pressed Next: Spotify moved on to its own next song. Anything else
                // means they started other music, which the held edits must not take over.
                guard title == expectedNext || lastRemaining <= 4 else {
                    log("\(trigger.rawValue): \(seen) | \(appText) → other music started, dropped the held edits")
                    pausedSince = nil; changedSince = nil
                    cancelPending()
                    return
                }
            }
        }
        log("\(trigger.rawValue): \(seen) | \(appText) → sending \(start ? "as the next songs" : "now (paused)")")
        pausedSince = nil; changedSince = nil
        stopPending()
        if start {
            let first = items.first?.id
            send(["spotify-replace", "--start"] + items.map(\.uri)) { [weak self] e in
                guard let self else { return }
                self.settleUntil = Date().addingTimeInterval(2.5)
                // the first song is playing now (unless the user already removed or moved it meanwhile)
                if e == nil, let first, self.items.first?.id == first { self.items.removeFirst() }
                if let e { self.log("send failed: \(e)"); NotificationCenter.default.post(name: .lyricsBarToast, object: e) }
            }
        } else {
            sendReplay(nil)
        }
    }

    struct AppState { let name: String; let playing: Bool; let duration: Double; let position: Double }

    /// The Spotify app's own view (song, state, length, position). nil if it isn't running or didn't answer.
    static func appState(_ done: @escaping (AppState?) -> Void) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").isEmpty else { done(nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(); let out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", """
                tell application "Spotify" to return (name of current track) & tab & (player state as text) & tab & ((duration of current track) / 1000 as text) & tab & (player position as text)
                """]
            p.standardOutput = out; p.standardError = FileHandle.nullDevice
            var r: AppState?
            if (try? p.run()) != nil {
                p.waitUntilExit()
                let f = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    .trimmingCharacters(in: .newlines).components(separatedBy: "\t")
                let num = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) }
                if p.terminationStatus == 0, f.count == 4, let d = num(f[2]), let pos = num(f[3]) {
                    r = AppState(name: f[0], playing: f[1] == "playing", duration: d, position: pos)
                }
            }
            DispatchQueue.main.async { done(r) }
        }
    }

    /// ~/.touchbar-lyrics/spotify-queue.log: what triggered held edits (song names only), kept short.
    private func log(_ line: String) {
        let path = home + "/spotify-queue.log"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append(df.string(from: Date()) + "  " + line)
        let text = lines.suffix(200).joined(separator: "\n") + "\n"
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    }

    private func sendReplay(_ done: ((String?) -> Void)?) {
        if busy {                               // one edit at a time: the latest list goes out next
            replayPending = true
            if let done { pendingDone.append(done) }
            return
        }
        send(["spotify-replace"] + items.map(\.uri), done)
    }

    private func send(_ args: [String], _ done: ((String?) -> Void)?) {
        gen += 1                                // anything already loading is now out of date
        busy = true
        libraryJSON(args) { [weak self] obj, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                let failed = obj == nil ? Self.friendly(err) : nil
                done?(failed)
                if self.replayPending, failed == nil {
                    self.replayPending = false
                    let ds = self.pendingDone; self.pendingDone = []
                    self.replay { e in ds.forEach { $0(e) } }   // held for the song's end again if it's playing
                    return
                }
                self.replayPending = false
                let ds = self.pendingDone; self.pendingDone = []
                ds.forEach { $0(failed) }
                // let Spotify settle, then show what it really has
                DispatchQueue.main.asyncAfter(deadline: .now() + (failed == nil ? 1.2 : 0)) { self.refresh() }
            }
        }
    }

    private func refreshSoon() { DispatchQueue.main.async { self.refresh() } }
}
