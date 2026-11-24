// Spotify's Up Next, editable from the Touch Bar strip and the Library window.
// The Web API can read the queue and add to it, but has no remove/reorder/clear: edits (library.py
// spotify-replace) mute Spotify, skip through the queue to empty it, then play the edited list.
// That would interrupt the current song, so while Spotify plays, edits are shown straight away but only
// sent in the last moments of the song (`pending`), and then start the new list in place of the next song.
// While paused they're sent at once (silently, keeping the current song and its position). Needs Spotify Premium and the user-modify-playback-state scope.
import Foundation

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
    private var pendingTitle = ""
    private var pendingTimer: Timer?
    private var pausedSince: Date?, changedSince: Date?   // Now Playing blips for a moment; act only on steady states

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
        items.remove(at: i)
        replay(done)
    }

    func reorder(_ ids: [UUID], _ done: ((String?) -> Void)? = nil) {
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let new = ids.compactMap { byId[$0] }
        guard new.count == items.count, new.map(\.id) != items.map(\.id) else { return }
        guard canReplay(done) else { refreshSoon(); return }
        items = new
        replay(done)
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
        guard !items.isEmpty, canReplay(done) else { return }
        items = []
        replay(done)
    }

    private func replay(_ done: ((String?) -> Void)?) {
        if let s = DiscordPresence.shared.snapshot(), s.bundle == "com.spotify.client", s.playing {
            // playing: don't interrupt the song; send the edit when it's about to end
            if !pending { pendingTitle = s.title }
            pending = true
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
    }

    /// Sends the held edits when the song is about to end, when it changed anyway (skipped), or when paused.
    private func checkPending() {
        guard pending, !busy else { return }
        guard let s = DiscordPresence.shared.snapshot(), s.bundle == "com.spotify.client" else { return }
        let now = Date()
        pausedSince = s.playing ? nil : (pausedSince ?? now)
        changedSince = s.title == pendingTitle ? nil : (changedSince ?? now)
        let start: Bool
        if let p = pausedSince { guard now.timeIntervalSince(p) >= 2 else { return }; start = false }   // paused: apply silently
        else if let c = changedSince { guard now.timeIntervalSince(c) >= 0.4 else { return }; start = true }   // song changed
        else if s.duration > 0 && s.duration - s.elapsed <= 1.5 { start = true }
        else { return }
        NSLog("LyricsBar: sending held Spotify edits (%@)", pausedSince != nil ? "paused" : changedSince != nil ? "song changed" : "song ending")
        pausedSince = nil; changedSince = nil
        stopPending()
        if start {
            send(["spotify-replace", "--start"] + items.map(\.uri)) { [weak self] e in
                if e == nil, let self, !self.items.isEmpty { self.items.removeFirst() }   // it's playing now
                if let e { NotificationCenter.default.post(name: .lyricsBarToast, object: e) }
            }
        } else {
            sendReplay(nil)
        }
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
