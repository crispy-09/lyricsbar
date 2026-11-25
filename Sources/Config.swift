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
    /// The right-hand buttons, in order. place: "bar" (always shown), "more" (behind the ‹ button), "off".
    var stripLayout: [StripSlot] = StripSlot.defaults
    var stripExpand = "outward"       // ‹ opens "outward" (extras appear to its left) | "inline" (in list order) | "off"
    var barHidden = false             // LyricsBar is off the Touch Bar (the ♪ in the Control Strip brings it back)
    var playingShows = "lyrics"       // while playing: "lyrics" | "controls" | "title"
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
    var noCrossfadeInAlbums = true    // songs from the same album play back to back without a fade
    var repeatMode = "off"            // "off" | "all" | "one"  (built-in player)
    var resumeQueue = true            // reload the built-in player's queue (paused) after a restart
    var showAppleMusic = false
    var reportPlays = true            // scrobble LyricsBar's Subsonic plays to the server
    var scrobbleLastfm = false        // scrobble directly from LyricsBar (needs lastfm.json)
    var scrobbleListenBrainz = false  // scrobble directly from LyricsBar (needs listenbrainz.json)
    var defaultApp = "subsonic"       // ▶ with nothing loaded: "subsonic" | "spotify" | "applemusic" | "ask"
    var lyricTapAction = "pause"      // tap on the lyrics: "pause" | "controls" | "none"
    var lyricHoldAction = "controls"  // long-press on the lyrics: same choices
    // While paused (Settings → General)
    var pausedShows = "lyrics"        // "lyrics" | "controls" | "title" | "quotes" | "phrase"
    var pausedDelay = 2.0             // seconds paused before switching (quick pauses don't flicker)
    var pausedPhrase = "Paused · {title}"
    var pausedQuotes = ""             // your own quotes, one per line ("text — author")
    var pausedBuiltinQuotes = true
    var pausedQuoteSeconds = 60.0     // whole minutes, at least 1
    var artLinger = 10.0              // the cover (button + album background) stays this long after pausing (-1 = keep it)
    // Discord Rich Presence (Settings → Discord)
    var discordEnabled = false
    var discordAppId = ""             // your Discord application's ID (public, not a secret)
    var discordType = "listening"     // "listening" | "playing"
    var discordName = "{artist}"      // top line: "Listening to <this>" (Vesktop/arRPC; the official app shows the app name)
    var discordLine1 = "{title}"
    var discordLine2 = "by {artist}"
    var discordHover = "{album}"      // tooltip on the picture
    var discordTimestamps = true      // progress bar / time left
    var discordWhenPaused = "hide"    // "hide" | "show"
    var discordPlayers = "noSpotify"  // "all" | "own" | "noSpotify" (Spotify already shows its own presence)
    var discordAlbumArt = false       // look up cover art on Apple's public iTunes Search
    var discordImage = ""             // fallback picture: an asset name from your Discord app, or an https URL
    var discordStatusDisplay = "app"  // member list says "Listening to <app name | line 1 | line 2>"
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
            if decode(merged) == nil {
                // one value of the wrong type would reset everything: keep each value that decodes on its own
                merged = defaults
                for (k, v) in file where defaults[k] != nil {
                    var trial = merged; trial[k] = v
                    if decode(trial) != nil { merged = trial } else { NSLog("LyricsBar: ignoring bad setting \(k)") }
                }
            }
            // older configs only had the tap choice (hold did the other one): keep that behaviour
            if file["lyricHoldAction"] == nil, (file["lyricTapAction"] as? String) == "controls" { merged["lyricHoldAction"] = "pause" }
            // 2 s was the old default, never a choice: move it to the new 10 s default
            if (file["artLinger"] as? Double) == 2 { merged["artLinger"] = 10.0 }
            // the separate show-button switches became one orderable layout
            if file["stripLayout"] == nil {
                let on = { (k: String, d: Bool) in (file[k] as? Bool) ?? d }
                merged["stripLayout"] = [("brightness", on("showBrightness", true) ? "bar" : "off"),
                                         ("volume", on("showVolume", true) ? "bar" : "off"),
                                         ("library", on("showApps", true) ? "bar" : "off"),
                                         ("keyboard", on("showKeyboardLight", false) ? "more" : "off"),
                                         ("siri", on("showSiri", false) ? "more" : "off"),
                                         ("screenshot", on("showScreenshot", false) ? "more" : "off"),
                                         ("regular", on("showRegularBar", false) ? "more" : "off")]
                    .map { ["id": $0.0, "place": $0.1] }
            }
            // quote rotation is now whole minutes, at least one
            if let q = file["pausedQuoteSeconds"] as? Double { merged["pausedQuoteSeconds"] = max(60, (q / 60).rounded() * 60) }
        }
        return decode(merged) ?? Config()
    }

    private static func decode(_ d: [String: Any]) -> Config? {
        guard let data = try? JSONSerialization.data(withJSONObject: d) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
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

/// One right-hand Touch Bar button and where it goes.
struct StripSlot: Codable, Equatable, Identifiable {
    var id: String
    var place: String                  // "bar" | "more" | "off"

    static let names: [String: String] = ["brightness": "Brightness", "volume": "Volume", "library": "Library",
                                          "keyboard": "Keyboard brightness", "siri": "Siri", "screenshot": "Screenshot",
                                          "regular": "Switch to the regular Touch Bar"]
    static let icons: [String: String] = ["brightness": "sun.max.fill", "volume": "speaker.wave.2.fill",
                                          "library": "books.vertical.fill", "keyboard": "light.max", "siri": "siri",
                                          "screenshot": "camera.viewfinder", "regular": "rectangle.badge.xmark"]
    static let order = ["brightness", "volume", "library", "keyboard", "siri", "screenshot", "regular"]
    static let defaults: [StripSlot] = order.map {
        StripSlot(id: $0, place: ["brightness", "volume", "library"].contains($0) ? "bar" : "off")
    }

    /// Known buttons only, each once, missing ones appended (off).
    static func normalized(_ l: [StripSlot]) -> [StripSlot] {
        var seen = Set<String>(), out: [StripSlot] = []
        for s in l where names[s.id] != nil && !seen.contains(s.id) && ["bar", "more", "off"].contains(s.place) {
            seen.insert(s.id); out.append(s)
        }
        for id in order where !seen.contains(id) { out.append(StripSlot(id: id, place: "off")) }
        return out
    }
}
