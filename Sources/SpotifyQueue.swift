// Spotify's Up Next, editable from the Touch Bar strip and the Library window.
// The Web API can read the queue and skip, but has no remove/reorder: edits replay the current song
// (same position) followed by the edited list. Needs Spotify Premium and the user-modify-playback-state scope.
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
                if let list = obj as? [[String: Any]] {
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
                    self.send(["spotify-replace"] + self.items.map(\.uri)) { e in ds.forEach { $0(e) } }
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
