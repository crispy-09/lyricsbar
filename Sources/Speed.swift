// Playback speed: a button on the bar that steps through 1× … 2×. With "Only for podcasts" on (the default) it
// only shows while a podcast plays.
//  • LyricsBar's own player: AVPlayer's rate (pitch is kept). Podcasts remember their speed.
//  • Other apps: the system's "change playback rate" command (media-control speed). Apps that don't take it
//    (most music players, browsers) simply stay at 1×, and the button says so.
import AppKit

enum PlaybackSpeed {
    static let steps: [Double] = [1, 1.25, 1.5, 1.75, 2]
    /// Apps that only play podcasts.
    static let podcastApps: Set<String> = ["com.apple.podcasts", "au.com.shiftyjelly.podcasts", "fm.overcast.overcast",
                                           "com.castro.Castro", "com.pocketcasts.PocketCasts"]
    static func label(_ v: Double) -> String {
        (v == v.rounded() ? String(Int(v)) : String(format: "%g", v)) + "×"
    }
    static func next(after v: Double) -> Double { steps.first { $0 > v + 0.01 } ?? steps[0] }

    /// Is the thing another app plays a podcast? Spotify says so in the item's link, Music in its genre.
    static func detect(bundle: String, _ done: @escaping (Bool) -> Void) {
        if podcastApps.contains(bundle) { done(true); return }
        if bundle == "com.spotify.client" {
            SpotifyQueue.appState { s in
                let yes = s?.uri.hasPrefix("spotify:episode:") ?? false
                DispatchQueue.main.async { done(yes) }
            }
            return
        }
        guard bundle == "com.apple.Music", !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else {
            done(false); return
        }
        DispatchQueue.global(qos: .utility).async {
            let p = Process(), out = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"Music\" to return (genre of current track) & tab & (media kind of current track as text)"]
            p.standardOutput = out; p.standardError = FileHandle.nullDevice
            var yes = false
            if (try? p.run()) != nil {
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
                let s = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).lowercased()
                p.waitUntilExit()
                yes = s.contains("podcast")
            }
            DispatchQueue.main.async { done(yes) }
        }
    }
}

/// Spotify takes no speed command from outside (not the system's, not AppleScript, not its Web API), so its own
/// speed menu is used through Accessibility: the "Speed 1×" button next to the transport, then the menu item.
/// Works with the window in the background, but the window has to exist. Needs the Accessibility permission.
enum SpotifySpeed {
    static let steps: [Double] = [1, 1.2, 1.5, 1.8, 2]          // Spotify's menu goes in tenths
    private static let q = DispatchQueue(label: "lyricsbar.spotifyspeed")

    private static func attr(_ e: AXUIElement, _ a: String) -> Any? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    /// The speed an element is labelled with ("Speed 1.5×", in any language: the number before the ×).
    private static func speed(of e: AXUIElement) -> Double? {
        for a in ["AXTitle", "AXDescription"] {
            guard let s = attr(e, a) as? String, s.hasSuffix("×"),
                  let r = s.range(of: #"\d+([.,]\d+)?(?=\s?×$)"#, options: .regularExpression) else { continue }
            return Double(s[r].replacingOccurrences(of: ",", with: "."))
        }
        return nil
    }
    private static func find(_ e: AXUIElement, role: String, depth: Int = 0, _ ok: (Double) -> Bool) -> AXUIElement? {
        if depth > 60 { return nil }
        if attr(e, "AXRole") as? String == role, let v = speed(of: e), ok(v) { return e }
        for c in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] {
            if let r = find(c, role: role, depth: depth + 1, ok) { return r }
        }
        return nil
    }
    private static func search(role: String, _ ok: (Double) -> Bool) -> AXUIElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").first else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 2)
        for w in (attr(ax, "AXWindows") as? [AXUIElement]) ?? [] {
            if let r = find(w, role: role, ok) { return r }
        }
        return nil
    }

    /// The speed Spotify is set to; nil if it can't be read (no permission, no window, not a podcast).
    static func read(_ done: @escaping (Double?) -> Void) {
        guard AXIsProcessTrusted() else { done(nil); return }
        q.async {
            let v = search(role: "AXButton") { _ in true }.flatMap { speed(of: $0) }
            DispatchQueue.main.async { done(v) }
        }
    }
    static func set(_ v: Double, _ done: @escaping (Bool) -> Void) {
        q.async {
            var ok = false
            if let button = search(role: "AXButton", { _ in true }),
               AXUIElementPerformAction(button, kAXPressAction as CFString) == .success {
                for _ in 0..<10 {                                  // the menu takes a moment to appear
                    usleep(100_000)
                    if let item = search(role: "AXMenuItem", { abs($0 - v) < 0.01 }) {
                        ok = AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                        break
                    }
                }
                if !ok { AXUIElementPerformAction(button, kAXPressAction as CFString) }   // close the menu again
            }
            DispatchQueue.main.async { done(ok) }
        }
    }
}

extension BarView {
    /// What the speed applies to: the own player's song, or another app's item.
    private var speedKey: String {
        let sp = StreamPlayer.shared
        if ownPlayerActive || (currentTitle.isEmpty && sp.active) {
            return "own|" + (sp.tracks.indices.contains(sp.index) ? sp.tracks[sp.index].uid.uuidString : "")
        }
        return currentTitle.isEmpty ? "" : bundleId + "|" + currentTitle
    }
    var speedIsOwn: Bool { speedKey.hasPrefix("own|") }
    var speedIsSpotify: Bool { !speedIsOwn && bundleId == "com.spotify.client" }
    var currentSpeed: Double {
        if speedIsOwn { return StreamPlayer.shared.speed }
        // what the app reports while it plays; while paused, the last speed seen or asked for
        // (Spotify always reports 1: its speed is read from its window instead)
        if !speedIsSpotify, isPlaying, elapsedAt.rate > 0, Date() >= speedAskedUntil { speedSeen = elapsedAt.rate }
        return speedSeen
    }
    var speedSlotOn: Bool { StripSlot.normalized(cfg.stripLayout).contains { $0.id == "speed" && $0.place != "off" } }
    var speedButtonWanted: Bool { !speedKey.isEmpty && (!cfg.speedPodcastsOnly || speedPodcast) }

    /// Called on every tick: finds out whether a new item is a podcast and keeps the button up to date.
    func refreshSpeed() {
        let key = speedSlotOn ? speedKey : ""
        if key != speedFor {
            speedFor = key
            if key.hasPrefix("own|") {
                speedPodcast = StreamPlayer.shared.currentIsPodcast
            } else {
                if key.isEmpty || !key.hasPrefix(speedBundle + "|") { speedSeen = 1 }   // another app: its speed isn't known yet
                speedBundle = bundleId
                speedPodcast = PlaybackSpeed.podcastApps.contains(bundleId)
                if !key.isEmpty, speedSlotOn {
                    PlaybackSpeed.detect(bundle: bundleId) { [weak self] yes in
                        guard let self, self.speedFor == key else { return }
                        self.speedPodcast = yes
                        if !yes, self.speedIsSpotify { self.speedSeen = 1 }      // Spotify only speeds up episodes
                        if yes, self.speedIsSpotify {
                            SpotifySpeed.read { [weak self] v in
                                guard let self, let v, self.speedFor == key, Date() >= self.speedAskedUntil else { return }
                                self.speedSeen = v
                            }
                        }
                    }
                }
            }
        }
        // the button is hidden for music: music must not stay sped up with no way to see or undo it
        if speedIsOwn, cfg.speedPodcastsOnly, !speedPodcast, StreamPlayer.shared.speed != 1 { StreamPlayer.shared.speed = 1 }
        let text = PlaybackSpeed.label(currentSpeed)
        if speedBtn.title != text {
            speedBtn.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white])
        }
        if speedButtonWanted != speedShown {
            speedShown = speedButtonWanted
            applyStripButtons()                 // the strip, and whether there is one at all, depends on it
            strip.isHidden = panelMode != .none || !anyStripButton
        }
    }

    @objc func stepSpeed() {
        let v = PlaybackSpeed.next(after: currentSpeed)
        if speedIsOwn {
            let sp = StreamPlayer.shared
            sp.speed = v
            if sp.currentIsPodcast { ConfigStore.shared.c.podcastSpeed = v }
        } else if speedIsSpotify {
            guard AXIsProcessTrusted() else {
                ControlCenterSound.askPermission()
                toast("Allow LyricsBar under Privacy & Security → Accessibility to change Spotify's speed", seconds: 4)
                return
            }
            let from = speedSeen
            let v = SpotifySpeed.steps.first { $0 > from + 0.01 } ?? SpotifySpeed.steps[0]
            speedSeen = v                                        // shown right away; taken back if it didn't work
            speedAskedUntil = Date().addingTimeInterval(3)
            SpotifySpeed.set(v) { [weak self] ok in
                guard let self, !ok else { return }
                self.speedSeen = from
                self.toast(self.speedPodcast ? "Couldn't reach Spotify's speed menu (its window has to be open)"
                                             : "Spotify only changes speed for podcasts", seconds: 3)
            }
        } else {
            // the system command (as media-control sends it) only takes whole speeds
            let v: Double = currentSpeed < 1.5 ? 2 : 1
            let key = speedFor
            run(mediaControl, ["speed", String(Int(v))])
            speedSeen = v
            speedAsked = v
            speedAskedUntil = Date().addingTimeInterval(1.5)     // until the app reports back
            // an app that doesn't take the command still reports 1×: say so instead of showing a speed it isn't at
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.speedFor == key, self.speedAsked == v, self.isPlaying,
                      abs(self.currentSpeed - v) > 0.01 else { return }
                self.toast("This app doesn't let the speed be changed", seconds: 3)
            }
        }
        refreshSpeed()
    }
}
