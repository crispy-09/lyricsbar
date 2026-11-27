// "Which one?": when ▶ is pressed while more than one player was playing recently and all are paused now
// (say a video in the browser and a song in the queue), the bar asks instead of guessing. Each choice shows
// its cover (or the app's icon) and the title.
import AppKit

enum RecentPlayers {
    struct Entry { var title: String; var at: Date; var heard: Bool }
    static let window: TimeInterval = 15 * 60
    static var seen: [String: Entry] = [:]            // bundle id → what it last played, and when
    private static var heardCheck = Date.distantPast

    /// Called on every tick for whatever is playing right now.
    static func note(bundle: String, title: String) {
        guard !bundle.isEmpty, !title.isEmpty else { return }
        var e = seen[bundle] ?? Entry(title: title, at: Date(), heard: false)
        if e.title != title { e.heard = false }
        e.title = title; e.at = Date()
        // a browser also "plays" silent thumbnail previews: it only counts once it's heard
        if DiscordPresence.isBrowser(bundle) {
            if !e.heard, Date().timeIntervalSince(heardCheck) > 1.5 {
                heardCheck = Date()
                e.heard = AudioTap.isAudible(bundle)
            }
        } else { e.heard = true }
        seen[bundle] = e
    }
    static func recent(_ bundle: String) -> Entry? {
        guard let e = seen[bundle], e.heard, Date().timeIntervalSince(e.at) < window else { return nil }
        return e
    }
    static func appIcon(_ bundle: String) -> NSImage? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}

extension BarView {
    /// The paused players ▶ could mean. `raw` is the system's Now Playing item as it stands (even if the bar ignores it).
    func playCandidates(raw: [String: Any]) -> [TBPicker.Item] {
        var items: [TBPicker.Item] = []
        let own = Bundle.main.bundleIdentifier ?? ""
        let sp = StreamPlayer.shared
        let npBundle = raw["bundle"] as? String ?? "", npTitle = raw["title"] as? String ?? ""
        if sp.active, sp.tracks.indices.contains(sp.index), RecentPlayers.recent(own) != nil || npTitle.isEmpty || npBundle == own {
            items.append(.init(title: sp.tracks[sp.index].title, image: sp.artwork ?? RecentPlayers.appIcon(own)) { [weak self] in
                self?.closePicker(); StreamPlayer.shared.play()
            })
        }
        // the system's Now Playing app: ▶ can be sent to it as it is
        if !npTitle.isEmpty, npBundle != own, let e = RecentPlayers.recent(npBundle), e.title == npTitle {
            let art = (raw["artwork"] as? String).flatMap { $0.isEmpty ? nil : NSImage(contentsOfFile: $0) }
            items.append(.init(title: npTitle, image: art ?? RecentPlayers.appIcon(npBundle)) { [weak self] in
                self?.closePicker(); run(mediaControl, ["toggle-play-pause"])
            })
        }
        // Spotify and Music can be told to play even when another app holds Now Playing
        for (bundle, app) in [("com.spotify.client", "Spotify"), ("com.apple.Music", "Music")] where bundle != npBundle {
            guard let e = RecentPlayers.recent(bundle),
                  !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { continue }
            items.append(.init(title: e.title, image: RecentPlayers.appIcon(bundle)) { [weak self] in
                self?.closePicker(); run("/usr/bin/osascript", ["-e", "tell application \"\(app)\" to play"])
            })
        }
        return items
    }

    /// Shows the choice if there is one to make. False: nothing to ask, carry on as usual.
    func askWhichPlayer(raw: [String: Any]) -> Bool {
        guard cfg.askWhichPlayer, !isPlaying, !(raw["playing"] as? Bool ?? false), !StreamPlayer.shared.isPlaying else { return false }
        let items = playCandidates(raw: raw)
        if items.count == 1 {
            // one thing was playing a moment ago. If the bar no longer shows it (a browser video that left the bar
            // after it was paused), ▶ still means that one, not the queue or the default player.
            let np = raw["title"] as? String ?? ""
            let own = StreamPlayer.shared
            let ownIsIt = own.active && own.tracks.indices.contains(own.index) && items[0].title == own.tracks[own.index].title
            if !ownIsIt, !np.isEmpty, items[0].title == np, currentTitle != np { items[0].action?(); return true }
            return false
        }
        guard items.count > 1 else { return false }
        if mediaMode { setMediaMode(false) }
        if stripExpanded { setStripExpanded(false, restore: false) }
        pickerMode = true
        pickerPage += 1
        showingUpNext = false
        extras.isHidden = true
        setPickerTransport(false)
        useQueueStrip(false)
        setBack { [weak self] in self?.closePicker() }
        picker.items = items
        show(pickerRow, true); show(lyric, false)
        bumpPickerTimer()
        return true
    }
}
