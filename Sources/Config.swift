// Shared settings, stored in ~/.touchbar-lyrics/config.json (lyricsd.py reads it too).
import Foundation
import Combine

struct PinnedPlaylist: Codable, Hashable, Identifiable {
    var provider: String      // "subsonic" | "spotify"
    var playlistId: String
    var name: String
    var id: String { provider + ":" + playlistId }
}

struct Config: Codable, Equatable {
    // Lyrics
    var lyricOffset = 0.35            // seconds of look-ahead
    var lyricFontSize = 15.0
    var showTitleWhenNoLyrics = true
    var titleCardSeconds = 3.0        // show "Title · Artist" when a song starts
    var outroSeconds = 8.0            // bring the title back (with "next") this long before a song ends
    var lyricTransition = "slide"     // "slide" | "fade" | "none"
    var lyricAlignment = "left"       // "left" | "center"
    // Appearance
    var backgroundStyle = "wallpaper" // "wallpaper" | "solid"
    var solidColor = "#1C1C1E"
    var blurAmount = 18.0
    var targetBrightness = 0.28
    var saturation = 1.35
    var dimAmount = 0.12
    var showProgress = true           // thin progress line along the bottom
    // Visualizer
    var visualizerStyle = "background" // "off" | "background" | "compact"
    var visualizerColor = "album"      // "white" | "album"
    var visualizerSensitivity = 1.0
    var visualizerOpacity = 0.3
    // Touch Bar
    var showBrightness = true
    var showVolume = true
    var showApps = true
    var mediaAutoHide = 8.0
    var pickerAutoHide = 15.0
    var panelAutoHide = 6.0
    var showMenuBarIcon = true
    var buttonStyle = "minimal"       // "minimal" | "pill"
    // Playback
    var showSubsonic = true
    var showSpotify = true
    var defaultShuffle = false
    var pauseOthers = true
    var crossfadeSeconds = 4.0        // built-in Subsonic player only; 0 = off
    var repeatMode = "off"            // "off" | "all" | "one"  (built-in player)
    var resumeQueue = true            // reload the built-in player's queue (paused) after a restart
    var showAppleMusic = false
    var reportPlays = true            // scrobble LyricsBar's Subsonic plays to the server
    var scrobbleLastfm = false        // scrobble directly from LyricsBar (needs lastfm.json)
    var scrobbleListenBrainz = false  // scrobble directly from LyricsBar (needs listenbrainz.json)
    var defaultApp = "subsonic"       // ▶ with nothing loaded: "subsonic" | "spotify" | "applemusic" | "ask"
    var lyricTapAction = "pause"      // tap on the lyrics: "pause" | "controls" | "none"
    var lyricHoldAction = "controls"  // long-press on the lyrics: same choices
    var pinned: [PinnedPlaylist] = []
}

extension Notification.Name {
    static let lyricsBarConfigChanged = Notification.Name("lyricsBarConfigChanged")
}

final class ConfigStore: ObservableObject {
    static let shared = ConfigStore()
    static let path = home + "/config.json"

    @Published var c: Config {
        didSet {
            guard c != oldValue else { return }
            save()
            NotificationCenter.default.post(name: .lyricsBarConfigChanged, object: nil)
        }
    }

    private init() { c = ConfigStore.load() }

    /// Missing keys fall back to defaults, so older config files keep working.
    static func load() -> Config {
        let defaults = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Config()))) as? [String: Any] ?? [:]
        var merged = defaults
        if let d = FileManager.default.contents(atPath: path),
           let file = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in file where defaults[k] != nil { merged[k] = v }
            // older configs only had the tap choice (hold did the other one): keep that behaviour
            if file["lyricHoldAction"] == nil, (file["lyricTapAction"] as? String) == "controls" { merged["lyricHoldAction"] = "pause" }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return cfg
    }

    func save() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(c) else { return }
        try? d.write(to: URL(fileURLWithPath: ConfigStore.path), options: .atomic)
    }

    func isPinned(_ provider: String, _ id: String) -> Bool {
        c.pinned.contains { $0.provider == provider && $0.playlistId == id }
    }

    func togglePin(_ provider: String, _ id: String, _ name: String) {
        if isPinned(provider, id) { c.pinned.removeAll { $0.provider == provider && $0.playlistId == id } }
        else { c.pinned.append(.init(provider: provider, playlistId: id, name: name)) }
    }
}

var cfg: Config { ConfigStore.shared.c }
