// Spotify's Up Next, editable from the Touch Bar strip and the Library window.
// Spotify's Web API can read the queue and add to it, but can't remove, reorder or clear. So once Up Next
// is edited here, LyricsBar keeps the list itself ("managed") and edits never touch Spotify:
//  • about 10 s before the current song ends, the first song of the list is handed to Spotify
//    (library.py spotify-feed), which then plays it next by itself, without a gap;
//  • if something else is ahead of it in Spotify's own queue (songs added in the Spotify app), or the next
//    song changed after it was handed over, LyricsBar switches songs itself at the end of the song
//    (AppleScript `play track`), which cuts the last fraction of a second;
//  • Next from LyricsBar plays the list's first song directly; Next pressed elsewhere is corrected.
// Until the first edit the strip simply shows Spotify's own queue. When the list runs out, or other music
// is started, Spotify gets Up Next back. Needs Spotify Premium and the user-modify-playback-state scope.
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
    @Published private(set) var busy = false     // a jump within Spotify's own queue is being sent
    /// The list shown is LyricsBar's own (it was edited here); Spotify is handed one song at a time from it.
    @Published private(set) var managed = false

    private var fed: Item?                       // Spotify plays this next by itself (handed over, or its own next anyway)
    private var fedAdded = false                 // …because we added it to Spotify's queue (it can't be taken back)
    private var feeding = false
    private var feedTried: UUID?                 // one hand-over attempt per song
    private var boundary = false                 // Spotify's queue can't be relied on: switch songs here at the end
    private var stopAfter = false                // the list was emptied by hand: stop when this song ends
    private var trackedTitle = ""                // the song playing as far as the list knows ("" = learn it)
    private var realNext: String?                // what Spotify itself would play next (tells Next from other music)
    private var recent: [String] = []            // songs played lately: going back to one isn't "other music"
    private var lastRemaining = Double.infinity  // seconds left in the tracked song when last seen
    private var settleUntil = Date.distantPast   // right after a switch, Now Playing is still catching up
    private var timer: Timer?
    private var changedSince: Date?, awaySince: Date?
    private var switching = false                // a switch (or stop) at the end of this song is scheduled
    private var confirming = false

    private var gen = 0                          // only the newest refresh may publish
    private var waiting: [() -> Void] = []       // refresh callers; all called when the newest one lands
    private var ids: [String: UUID] = [:]        // "uri#n" (n-th time that song is queued) → id

    private static let spotify = "com.spotify.client"

    /// Songs and episodes; the only kinds that can be handed to Spotify or played by link.
    static func validURI(_ u: String) -> Bool {
        let parts = u.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "spotify" && (parts[1] == "track" || parts[1] == "episode")
            && parts[2].count == 22 && parts[2].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    /// Anything Spotify lists (local files too), checked before it goes to the helper as an argument.
    static func listedURI(_ u: String) -> Bool {
        u.hasPrefix("spotify:") && u.count < 400 && u.unicodeScalars.allSatisfy { $0.isASCII && $0.value > 32 }
    }

    // MARK: Spotify's own queue

    func refresh(_ done: (() -> Void)? = nil) {
        if let done { waiting.append(done) }
        gen += 1; let g = gen
        libraryJSON(["queue", "spotify"]) { [weak self] obj, err in
            DispatchQueue.main.async {
                guard let self, g == self.gen else { return }          // a newer refresh will call `waiting`
                self.loaded = true
                if self.managed {
                    // the list shown is ours; from Spotify's we only learn what it would play next by itself
                    if self.fed == nil, let list = obj as? [[String: Any]] { self.realNext = list.first?["uri"] as? String }
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

    // MARK: edits (all local: nothing is sent to Spotify until a song is about to end)

    /// Play a queued song now.
    func jump(id: UUID, _ done: ((String?) -> Void)? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { done?("That song isn't in the queue any more"); return }
        let t = items[i]
        if managed {
            guard t.replayable else { done?("Spotify can't start local files from here"); return }
            if i == 0, fed?.id == t.id {            // Spotify already has it as its next song
                Self.tell("next track")
            } else {
                items.removeFirst(i)                // the songs before it are skipped
                play(t, why: "Play Now")
            }
            done?(nil)
            return
        }
        // Spotify's own queue, untouched so far: skip to the song inside it (keeps its queue and playlist intact)
        guard !busy else { done?("Still skipping to the last song you picked…"); return }
        items.removeFirst(i + 1)                    // optimistic
        gen += 1                                    // anything already loading is now out of date
        busy = true
        libraryJSON(["spotify-jump", t.uri, String(t.rawIndex)]) { [weak self] obj, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                let failed = obj == nil ? Self.friendly(err) : nil
                done?(failed)
                // let Spotify settle, then show what it really has
                DispatchQueue.main.asyncAfter(deadline: .now() + (failed == nil ? 1.2 : 0)) { self.refresh() }
            }
        }
    }

    func remove(id: UUID, _ done: ((String?) -> Void)? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { done?("That song isn't in the queue any more"); return }
        guard canEdit(done) else { return }
        manage()
        items.remove(at: i)
        edited(); done?(nil)
    }

    func reorder(_ ids: [UUID], _ done: ((String?) -> Void)? = nil) {
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let new = ids.compactMap { byId[$0] }
        guard new.count == items.count, new.map(\.id) != items.map(\.id) else { return }
        guard canEdit(done) else { refreshSoon(); return }
        manage()
        items = new
        edited(); done?(nil)
    }

    /// Nothing follows: Spotify stops when the current song ends.
    func clear(_ done: ((String?) -> Void)? = nil) {
        guard !items.isEmpty else { done?("Up Next is already empty"); return }
        guard canEdit(done) else { return }
        manage()
        items = []
        edited(); done?(nil)
    }

    private func canEdit(_ done: ((String?) -> Void)?) -> Bool {
        if items.contains(where: { !$0.replayable }) {
            done?("Spotify can't re-queue local files, so this queue can't be edited")
            return false
        }
        return true
    }

    /// Takes Up Next over from Spotify (at the first edit).
    private func manage() {
        guard !managed else { return }
        managed = true
        fed = nil; fedAdded = false; feeding = false; feedTried = nil; boundary = false; stopAfter = false; switching = false
        realNext = items.first?.uri                 // before the edit: what Spotify itself plays next
        let s = DiscordPresence.shared.snapshot()
        trackedTitle = s?.bundle == Self.spotify ? (s?.title ?? "") : ""
        lastRemaining = .infinity; changedSince = nil; awaySince = nil
        startTimer()
        log("Up Next is now kept by LyricsBar (\(items.count) songs)")
    }

    private func edited() {
        if let f = fed, items.first?.id != f.id {
            fed = nil; feedTried = nil
            if fedAdded {
                // it can't be taken back out of Spotify's queue: from here on, switch songs ourselves at the end
                boundary = true
                log("the next song changed after \(f.title) was handed to Spotify → switching songs here from now on")
            }
        }
        stopAfter = items.isEmpty
        save()
    }

    /// Gives Up Next back to Spotify (other music was started, the list ran out, another player took over).
    func release() {
        guard managed else { return }
        managed = false
        fed = nil; feeding = false; boundary = false; stopAfter = false; switching = false
        timer?.invalidate(); timer = nil
        try? FileManager.default.removeItem(atPath: Self.savedFile)
        refreshSoon()
    }

    // MARK: the kept list survives a restart (song names and Spotify links only, nothing secret)

    private static let savedFile = home + "/spotify-pending.json"

    private func save() {
        guard managed else { return }               // given back to Spotify: nothing to keep
        let list: [[String: Any]] = items.map { ["uri": $0.uri, "title": $0.title, "artist": $0.artist, "album": $0.album,
                                                  "duration": $0.duration, "image": $0.image?.absoluteString ?? ""] }
        let obj: [String: Any] = ["title": trackedTitle, "stop": stopAfter, "items": list]
        guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
        FileManager.default.createFile(atPath: Self.savedFile, contents: d, attributes: [.posixPermissions: 0o600])
    }

    /// At launch: pick the kept list back up if the song it belonged to is still the one in Spotify.
    func restore() {
        guard let d = FileManager.default.contents(atPath: Self.savedFile),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let title = o["title"] as? String, !title.isEmpty,
              let list = o["items"] as? [[String: Any]] else {
            try? FileManager.default.removeItem(atPath: Self.savedFile); return
        }
        guard let s = DiscordPresence.shared.snapshot(), s.bundle == Self.spotify, s.title == title else {
            try? FileManager.default.removeItem(atPath: Self.savedFile); return   // the song moved on: too late
        }
        items = list.enumerated().compactMap { i, d in
            guard let uri = d["uri"] as? String, Self.validURI(uri) else { return nil }
            let img = (d["image"] as? String).flatMap { $0.hasPrefix("https://") ? URL(string: $0) : nil }
            return Item(id: UUID(), uri: uri, title: d["title"] as? String ?? "?", artist: d["artist"] as? String ?? "",
                        album: d["album"] as? String ?? "", duration: d["duration"] as? Double ?? 0, image: img, rawIndex: i)
        }
        loaded = true
        managed = true
        fed = nil; feeding = false; feedTried = nil; switching = false
        boundary = true                             // whether a song was already handed over isn't known: don't rely on it
        stopAfter = o["stop"] as? Bool ?? items.isEmpty
        trackedTitle = title
        lastRemaining = .infinity; changedSince = nil; awaySince = nil
        startTimer()
        log("picked the kept list back up after a restart (\(items.count) songs, playing \(title))")
    }

    // MARK: following the song

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var appTiming: (duration: Double, position: Double, at: Date)?
    private var appTimingAsked = Date.distantPast
    /// Asks the Spotify app (already running: it's what's playing) for its song length and position.
    private func askAppTiming() {
        guard Date().timeIntervalSince(appTimingAsked) >= 2 else { return }
        appTimingAsked = Date()
        Self.appState { [weak self] a in
            guard let self, let a else { return }
            self.appTiming = (a.duration, a.position, Date())
        }
    }

    private func tick() {
        guard managed, !confirming else { return }
        let now = Date()
        guard now >= settleUntil else { return }
        guard let s = DiscordPresence.shared.snapshot(), s.bundle == Self.spotify else {
            // another player took over: the kept list no longer applies
            awaySince = awaySince ?? now
            if now.timeIntervalSince(awaySince!) >= 5 { log("another player for 5 s → Up Next given back to Spotify"); release() }
            return
        }
        awaySince = nil
        if trackedTitle.isEmpty { trackedTitle = s.title; save(); return }
        if s.title != trackedTitle {
            changedSince = changedSince ?? now
            guard now.timeIntervalSince(changedSince!) >= 0.4 else { return }
            // Now Playing has fired false alarms mid-song: ask the Spotify app itself what's on
            confirming = true
            let seen = s.title
            Self.appState { [weak self] app in
                guard let self else { return }
                self.confirming = false
                guard self.managed else { return }
                self.songChanged(app, seen: seen)
            }
            return
        }
        changedSince = nil
        guard s.playing, !switching else { return }
        // seconds left in the song; if Now Playing has no length, ask the Spotify app itself
        var remaining: Double?
        if s.duration > 0 { remaining = s.duration - s.elapsed }
        else {
            askAppTiming()
            if let t = appTiming, now.timeIntervalSince(t.at) < 5 { remaining = t.duration - t.position - now.timeIntervalSince(t.at) }
        }
        guard let r = remaining else { return }
        lastRemaining = r
        if let first = items.first {
            if fed == nil, !feeding, feedTried != first.id, r <= 10, r > 2.5 { feed(first); return }
            if fed == nil, r <= 1.6 { switchAtEnd(to: first) }
        } else if stopAfter, r <= 1.6 {
            switchAtEnd(to: nil)
        }
    }

    /// Hands Spotify the next song, so it plays it by itself when this one ends.
    private func feed(_ item: Item) {
        feeding = true; feedTried = item.id
        // once Spotify's queue holds something of ours that shouldn't play, nothing more is added to it: only
        // check whether Spotify's own next happens to be the right song
        libraryJSON(["spotify-feed"] + (boundary ? ["--peek"] : []) + [item.uri]) { [weak self] obj, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.feeding = false
                guard self.managed else { return }
                guard let d = obj as? [String: Any] else {
                    self.log("couldn't hand \(item.title) to Spotify (\(Self.friendly(err))) → switching to it here at the end")
                    return
                }
                let added = d["added"] as? Bool ?? false
                if self.items.first?.id != item.id {
                    // the list changed while this was on its way
                    if added {
                        self.boundary = true        // it's in Spotify's queue now, but no longer what should play next
                        self.log("\(item.title) was handed to Spotify but the list changed meanwhile → switching songs here from now on")
                    }
                } else if d["first"] as? String == item.uri {
                    self.fed = item; self.fedAdded = added; self.realNext = item.uri
                    self.log(added ? "handed \(item.title) to Spotify as its next song" : "Spotify plays \(item.title) next anyway: nothing to hand over")
                } else if added {
                    self.boundary = true
                    self.log("something else is ahead of \(item.title) in Spotify's own queue → switching songs here from now on")
                } else {
                    self.log("Spotify's own next isn't \(item.title) → switching to it here at the end")
                }
            }
        }
    }

    /// The song is about to end and Spotify doesn't have ours as its next: start it ourselves (nil = stop).
    private func switchAtEnd(to item: Item?) {
        switching = true
        let tracked = trackedTitle
        Self.appState { [weak self] app in
            guard let self, self.managed, self.switching else { return }
            var left = self.lastRemaining
            if let app {
                guard app.name == tracked else { self.switching = false; return }     // it changed already: tick handles it
                left = app.duration - app.position
                guard app.playing, left <= 2.5 else { self.switching = false; return }   // false alarm (seeked back, paused)
            }
            // a touch before the end: Spotify would otherwise start its own next song first
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, left - 0.35)) { [weak self] in
                guard let self, self.managed, self.switching, self.trackedTitle == tracked else { return }
                self.switching = false
                if let item {
                    guard self.items.first?.id == item.id else { return }             // edited in the last second: next tick
                    self.play(item, why: "end of \(tracked)")
                } else if self.items.isEmpty, self.stopAfter {
                    Self.tell("pause")
                    self.log("end of \(tracked): Up Next was cleared → paused; Up Next given back to Spotify")
                    self.release()
                }
            }
        }
    }

    /// Starts a song from the list right now and takes it off the list.
    private func play(_ item: Item, why: String) {
        guard item.replayable else { return }
        if let i = items.firstIndex(where: { $0.id == item.id }) { items.remove(at: i) }
        if fed != nil {                                 // a song we added stays in Spotify's queue, unused
            if fedAdded { boundary = true }
            fed = nil
        }
        remember(item.uri)
        trackedTitle = item.title
        lastRemaining = .infinity; changedSince = nil; switching = false
        settleUntil = Date().addingTimeInterval(2)
        Self.tell("play track \"\(item.uri)\"")
        log("\(why) → started \(item.title) (\(items.count) left)")
        stopAfter = false
        save()
        confirmStarted(item, tries: 2)
        if items.isEmpty { log("that was the last song of the list → Up Next given back to Spotify"); release() }
    }

    /// Spotify can swallow a `play track` (it was still loading its own next song): check it took, and ask again.
    private func confirmStarted(_ item: Item, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, self.trackedTitle == item.title else { return }      // moved on since
            Self.appState { [weak self] app in
                guard let self, let app, self.trackedTitle == item.title, app.uri != item.uri else { return }
                guard tries > 0 else {
                    self.log("Spotify didn't start \(item.title) (still on \(app.name))")
                    return                          // the next tick sees the other song and decides
                }
                self.log("Spotify is on \(app.name), not \(item.title) → asking again")
                self.settleUntil = Date().addingTimeInterval(2)
                Self.tell("play track \"\(item.uri)\"")
                self.confirmStarted(item, tries: tries - 1)
            }
        }
    }

    private func remember(_ uri: String?) {
        guard let uri else { return }
        recent.append(uri); if recent.count > 8 { recent.removeFirst() }
    }

    /// Spotify is on another song than the one the list was following.
    private func songChanged(_ app: AppState?, seen: String) {
        changedSince = nil
        if let app, app.name == trackedTitle { return }             // Now Playing was wrong: still the same song
        let name = app?.name ?? seen, uri = app?.uri
        let wasEnding = lastRemaining <= 4
        let from = trackedTitle
        trackedTitle = name; lastRemaining = .infinity; switching = false
        defer {
            remember(uri); save()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.refresh() }   // learn Spotify's own next
        }
        func matches(_ i: Item) -> Bool { uri != nil ? uri == i.uri : name == i.title }
        if let f = fed, matches(f) {
            fed = nil
            if let i = items.firstIndex(where: { $0.id == f.id }) { items.remove(at: i) }
            log("\(from) → \(name): Spotify played the song it was handed (\(items.count) left)")
            if items.isEmpty { log("that was the last song of the list → Up Next given back to Spotify"); release() }
        } else if let first = items.first, matches(first) {
            items.removeFirst()                     // Spotify's own order happened to agree
            log("\(from) → \(name): the next song of the list (\(items.count) left)")
            if items.isEmpty { release() }
        } else if let uri, recent.contains(uri) {
            log("\(from) → \(name): back to an earlier song; the list stays")
        } else if wasEnding || (uri != nil && uri == realNext) {
            // the song ended, or Next was pressed outside LyricsBar, and Spotify played its own next
            // (songs queued in the Spotify app come before ours): put the list's next song on
            if fed != nil { if fedAdded { boundary = true }; fed = nil }
            if let first = items.first {
                log("\(from) → \(name): Spotify played its own next song → switching to the list")
                play(first, why: "correcting")
            } else if stopAfter {
                Self.tell("pause")
                log("\(from) → \(name): Up Next was cleared → paused; Up Next given back to Spotify")
                release()
            }
        } else {
            log("\(from) → \(name): other music was started → Up Next given back to Spotify")
            release()
        }
    }

    /// Next pressed in LyricsBar: true if the list's first song was started here (Spotify's own Next isn't needed).
    func handleNext() -> Bool {
        guard managed, let first = items.first, first.replayable,
              let s = DiscordPresence.shared.snapshot(), s.bundle == Self.spotify else { return false }
        if fed?.id == first.id { return false }     // Spotify has it as its next song: its own Next goes there
        play(first, why: "Next")
        return true
    }

    /// The song after this one, when the list is LyricsBar's (for "NEXT" and the swipe preview).
    var managedNext: (String, String)? { managed ? items.first.map { ($0.title, $0.artist) } : nil }

    /// State for the `spq state` debug hook.
    var debugState: String {
        "managed=\(managed) fed=\(fed?.title ?? "-") boundary=\(boundary) stopAfter=\(stopAfter) tracked=\(trackedTitle) "
            + "remaining=\(lastRemaining.isFinite ? String(format: "%.1f", lastRemaining) : "?") feeding=\(feeding) switching=\(switching)"
    }

    /// A one-line command to the Spotify app (only ever built from checked song links).
    private static func tell(_ command: String) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: spotify).isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"Spotify\" to \(command)"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }

    struct AppState { let name: String; let playing: Bool; let duration: Double; let position: Double; let uri: String }

    /// The Spotify app's own view (song, state, length, position, link). nil if it isn't running or didn't answer.
    static func appState(_ done: @escaping (AppState?) -> Void) {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: spotify).isEmpty else { done(nil); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process(); let out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", """
                tell application "Spotify" to return (name of current track) & tab & (player state as text) & tab & ((duration of current track) / 1000 as text) & tab & (player position as text) & tab & (id of current track)
                """]
            p.standardOutput = out; p.standardError = FileHandle.nullDevice
            var r: AppState?
            if (try? p.run()) != nil {
                // an unresponsive Spotify must not hold this up for the Apple Event timeout (2 minutes)
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let f = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines).components(separatedBy: "\t")
                let num = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) }
                if p.terminationStatus == 0, f.count == 5, let d = num(f[2]), let pos = num(f[3]) {
                    r = AppState(name: f[0], playing: f[1] == "playing", duration: d, position: pos, uri: f[4])
                }
            }
            DispatchQueue.main.async { done(r) }
        }
    }

    /// ~/.touchbar-lyrics/spotify-queue.log: what the kept list did and why (song names only), kept short.
    private func log(_ line: String) {
        let path = home + "/spotify-queue.log"
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        lines.append(df.string(from: Date()) + "  " + line)
        let text = lines.suffix(200).joined(separator: "\n") + "\n"
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
    }

    private func refreshSoon() { DispatchQueue.main.async { self.refresh() } }
}
