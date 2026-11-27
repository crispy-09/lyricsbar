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
    var currentSpeed: Double {
        if speedIsOwn { return StreamPlayer.shared.speed }
        // what the app reports while it plays; while paused, the last speed seen or asked for
        if isPlaying, elapsedAt.rate > 0, Date() >= speedAskedUntil { speedSeen = elapsedAt.rate }
        return speedSeen
    }
    var speedButtonWanted: Bool { !speedKey.isEmpty && (!cfg.speedPodcastsOnly || speedPodcast) }

    /// Called on every tick: finds out whether a new item is a podcast and keeps the button up to date.
    func refreshSpeed() {
        let key = speedKey
        if key != speedFor {
            speedFor = key
            if key.hasPrefix("own|") {
                speedPodcast = StreamPlayer.shared.currentIsPodcast
            } else {
                if key.isEmpty || !key.hasPrefix(speedBundle + "|") { speedSeen = 1 }   // another app: its speed isn't known yet
                speedBundle = bundleId
                speedPodcast = PlaybackSpeed.podcastApps.contains(bundleId)
                if !key.isEmpty {
                    PlaybackSpeed.detect(bundle: bundleId) { [weak self] yes in
                        guard let self, self.speedFor == key else { return }
                        self.speedPodcast = yes
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
            applyConfig()                       // the strip (and whether there is one at all) depends on it
        }
    }

    @objc func stepSpeed() {
        let v = PlaybackSpeed.next(after: currentSpeed)
        if speedIsOwn {
            let sp = StreamPlayer.shared
            sp.speed = v
            if sp.currentIsPodcast { ConfigStore.shared.c.podcastSpeed = v }
        } else {
            run(mediaControl, ["speed", String(v)])
            speedSeen = v
            speedAskedUntil = Date().addingTimeInterval(1.5)     // until the app reports back
            // an app that doesn't take the command still reports 1×: say so instead of showing a speed it isn't at
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, !self.speedIsOwn, self.isPlaying, abs(self.currentSpeed - v) > 0.01 else { return }
                self.toast("This app doesn't let the speed be changed", seconds: 3)
            }
        }
        refreshSpeed()
    }
}
