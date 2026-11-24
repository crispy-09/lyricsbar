// Spotify's Up Next, editable from the Touch Bar strip and the Library window.
// The Web API can read the queue and skip, but has no remove/reorder: edits replay the current song
// (same position) followed by the edited list. Needs Spotify Premium and the user-modify-playback-state scope.
import Foundation

final class SpotifyQueue: ObservableObject {
    static let shared = SpotifyQueue()

    struct Item: Identifiable {
        let id = UUID()
        let uri: String, title: String, artist: String, album: String, duration: Double
        let image: URL?
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var error: String?
    @Published private(set) var loaded = false
    @Published private(set) var busy = false
    private var gen = 0                         // ignore stale refreshes that land after an edit

    static func validURI(_ u: String) -> Bool {
        let parts = u.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == "spotify" && (parts[1] == "track" || parts[1] == "episode")
            && parts[2].count == 22 && parts[2].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    func refresh(_ done: (() -> Void)? = nil) {
        gen += 1; let g = gen
        libraryJSON(["queue", "spotify"]) { [weak self] obj, err in
            DispatchQueue.main.async {
                guard let self, g == self.gen else { return }
                self.loaded = true
                if let list = obj as? [[String: Any]] {
                    self.error = nil
                    self.items = list.compactMap { d in
                        let uri = d["uri"] as? String ?? ""
                        guard Self.validURI(uri) else { return nil }
                        let img = (d["image"] as? String).flatMap { $0.hasPrefix("https://") ? URL(string: $0) : nil }
                        return Item(uri: uri, title: d["title"] as? String ?? "?", artist: d["artist"] as? String ?? "",
                                    album: d["album"] as? String ?? "", duration: d["duration"] as? Double ?? 0, image: img)
                    }
                } else {
                    self.error = Self.friendly(err)
                }
                done?()
            }
        }
    }

    static func friendly(_ err: String?) -> String {
        let e = err ?? ""
        if e.contains("scope") || e.contains("401") { return "Reconnect Spotify in Settings → Providers to edit Up Next" }
        return e.isEmpty ? "Couldn't load Spotify's queue" : e
    }

    /// Play a queued song now: skip forward to it.
    func jump(id: UUID, _ done: ((String?) -> Void)? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items.removeFirst(i + 1)                // optimistic
        run(["spotify-skip", String(i + 1)], done)
    }

    func remove(id: UUID, _ done: ((String?) -> Void)? = nil) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: i)
        replay(done)
    }

    func reorder(_ ids: [UUID], _ done: ((String?) -> Void)? = nil) {
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let new = ids.compactMap { byId[$0] }
        guard new.count == items.count, new.map(\.id) != items.map(\.id) else { return }
        items = new
        replay(done)
    }

    private func replay(_ done: ((String?) -> Void)?) {
        guard !items.isEmpty else { done?("Spotify can't empty its queue; skip instead"); refresh(); return }
        run(["spotify-replace"] + items.map(\.uri), done)
    }

    private func run(_ args: [String], _ done: ((String?) -> Void)?) {
        gen += 1                                // drop any refresh already in flight
        busy = true
        libraryJSON(args) { [weak self] obj, err in
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
}
