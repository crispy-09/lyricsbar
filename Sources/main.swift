// LyricsBar — full-width Touch Bar with blurred wallpaper, synced lyrics and media controls.
// Reads ~/.touchbar-lyrics/{current.txt,state.json,artwork.jpg} written by lyricsd.py.
import AppKit
import CoreImage
import QuartzCore
import CoreAudio
import AudioToolbox
import AVFoundation
import MediaPlayer
import Combine
import IOKit
import IOKit.pwr_mgt

let home = (NSHomeDirectory() as NSString).appendingPathComponent(".touchbar-lyrics")
let mediaControl = "/opt/homebrew/bin/media-control"
let barSize = NSSize(width: 1000, height: 30)

// MARK: - Private DFR / NSTouchBar API (same approach as MTMR / Pock)

let dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW)

func dfrSetControlStripPresence(_ id: String, _ on: Bool) {
    typealias F = @convention(c) (NSString, Bool) -> Void
    if let s = dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier") {
        unsafeBitCast(s, to: F.self)(id as NSString, on)
    }
}

func dfrShowCloseBox(_ on: Bool) {
    typealias F = @convention(c) (Bool) -> Void
    if let s = dlsym(dfr, "DFRSystemModalShowsCloseBoxWhenFrontMost") {
        unsafeBitCast(s, to: F.self)(on)
    }
}

func presentSystemModal(_ bar: NSTouchBar, trayId: String) {
    typealias F = @convention(c) (AnyObject, Selector, NSTouchBar, Int64, NSString) -> Void
    let cls: AnyClass = NSTouchBar.self
    for name in ["presentSystemModalTouchBar:placement:systemTrayItemIdentifier:",
                 "presentSystemModalFunctionBar:placement:systemTrayItemIdentifier:"] {
        let sel = NSSelectorFromString(name)
        if let m = class_getClassMethod(cls, sel) {
            unsafeBitCast(method_getImplementation(m), to: F.self)(cls, sel, bar, 1, trayId as NSString)
            return
        }
    }
}

func addSystemTrayItem(_ item: NSTouchBarItem) {
    let sel = NSSelectorFromString("addSystemTrayItem:")
    if NSTouchBarItem.responds(to: sel) { NSTouchBarItem.perform(sel, with: item) }
}

// MARK: - Helpers

func run(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    try? p.run()
}

/// The ♪ character as an image (placeholder when there's no album art).
func noteImage() -> NSImage {
    let size = NSSize(width: 26, height: 26)
    return NSImage(size: size, flipped: false) { r in
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 21, weight: .semibold),
                                                    .foregroundColor: NSColor.white]
        let s = "♪" as NSString, ts = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: (r.width - ts.width) / 2, y: (r.height - ts.height) / 2), withAttributes: attrs)
        return true
    }
}

func symbol(_ name: String, _ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))
}

/// The whole wallpaper squashed into the Touch Bar's shape and heavily blurred,
/// so its overall colours carry over. Dark wallpapers get lifted so the bar isn't black.
func blurredStrip(from url: URL) -> NSImage? {
    guard var img = CIImage(contentsOf: url) else { return nil }
    let outW = barSize.width * 2, outH = barSize.height * 2
    img = img.transformed(by: .init(scaleX: outW / img.extent.width, y: outH / img.extent.height))
    img = img.clampedToExtent().applyingGaussianBlur(sigma: max(0.1, cfg.blurAmount))
        .cropped(to: CGRect(x: 0, y: 0, width: outW, height: outH))
    let ctx = CIContext()
    // average brightness -> exposure boost toward a pleasant mid-dark level
    var px = [UInt8](repeating: 0, count: 4)
    let avg = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: img.extent)])
    ctx.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
               format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    let lum = max(0.02, (0.2126 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.0722 * Double(px[2])) / 255)
    let ev = max(-1.5, min(2.5, log2(cfg.targetBrightness / lum)))
    img = img.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
        .applyingFilter("CIColorControls", parameters: ["inputSaturation": cfg.saturation])
    guard let cg = ctx.createCGImage(img, from: CGRect(x: 0, y: 0, width: outW, height: outH)) else { return nil }
    return NSImage(cgImage: cg, size: barSize)
}

func currentWallpaperURL() -> URL? {
    let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
    if let s = screen, let u = NSWorkspace.shared.desktopImageURL(for: s) {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), !isDir.boolValue { return u }
    }
    return nil
}

/// A rotating wallpaper (a folder of pictures): macOS reports the folder, not the picture on screen.
func wallpaperIsRotating() -> Bool {
    let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main
    guard let s = screen, let u = NSWorkspace.shared.desktopImageURL(for: s) else { return false }
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue
}

// MARK: - System controls (no permissions needed)

enum Sys {
    static let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
    typealias GetB = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetB = @convention(c) (UInt32, Float) -> Int32

    static var brightness: Float {
        get {
            var b: Float = 0.5
            if let f = dlsym(ds, "DisplayServicesGetBrightness") { _ = unsafeBitCast(f, to: GetB.self)(CGMainDisplayID(), &b) }
            return b
        }
        set {
            if let f = dlsym(ds, "DisplayServicesSetBrightness") {
                _ = unsafeBitCast(f, to: SetB.self)(CGMainDisplayID(), max(0, min(1, newValue)))
            }
        }
    }

    static var outputDevice: AudioObjectID {
        var id = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }
    static func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        .init(mSelector: sel, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    static var volume: Float {
        get {
            var v: Float32 = 0, size = UInt32(MemoryLayout<Float32>.size)
            var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            AudioObjectGetPropertyData(outputDevice, &a, 0, nil, &size, &v)
            return v
        }
        set {
            var v = Float32(max(0, min(1, newValue)))
            var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
            AudioObjectSetPropertyData(outputDevice, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
            if v > 0 && muted { muted = false }
        }
    }
    static var muted: Bool {
        get {
            var m: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            var a = addr(kAudioDevicePropertyMute)
            AudioObjectGetPropertyData(outputDevice, &a, 0, nil, &size, &m)
            return m != 0
        }
        set {
            var m: UInt32 = newValue ? 1 : 0
            var a = addr(kAudioDevicePropertyMute)
            AudioObjectSetPropertyData(outputDevice, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        }
    }
    static var volumeSymbol: String {
        let v = volume
        if muted || v == 0 { return "speaker.slash.fill" }
        return v < 0.34 ? "speaker.wave.1.fill" : v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

// MARK: - Views

/// Symbol with its colour baked in (Touch Bar buttons ignore contentTintColor).
func coloredSymbol(_ name: String, _ size: CGFloat, _ color: NSColor) -> NSImage? {
    let img = symbol(name, size)?.withSymbolConfiguration(.init(paletteColors: [color]))
    img?.isTemplate = false
    return img
}

final class PillButton: NSButton {
    convenience init(_ img: NSImage?, _ target: AnyObject, _ action: Selector, width: CGFloat = 46) {
        self.init(frame: .zero)
        image = img
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .white
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        wantsLayer = true
    }
    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.22).cgColor
        layer?.cornerRadius = 7
        super.mouseDown(with: event)
        NSAnimationContext.runAnimationGroup { _ in layer?.backgroundColor = NSColor.clear.cgColor }
    }
}

/// Album art / ♪ icon. Tap → onTap, hold ~0.6s → onHold (touch-tracked so the two don't collide).
final class ArtView: NSImageView {
    var onTap: (() -> Void)?
    var onHold: (() -> Void)?
    private var holdTimer: Timer?
    private var held = false
    private var downAt = Date.distantPast
    static let holdTime = 0.6
    var baseAlpha: CGFloat = 1 { didSet { alphaValue = baseAlpha } }

    private func fireHold() {
        guard !held else { return }
        held = true
        alphaValue = baseAlpha
        onHold?()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.direct]
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.masksToBounds = true
        imageScaling = .scaleProportionallyUpOrDown
    }
    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(with event: NSEvent) {
        held = false
        downAt = Date()
        alphaValue = baseAlpha * 0.6
        holdTimer?.invalidate()
        // .common so it also fires while the touch is being tracked (the default mode is paused then)
        let t = Timer(timeInterval: ArtView.holdTime, repeats: false) { [weak self] _ in self?.fireHold() }
        RunLoop.main.add(t, forMode: .common)
        holdTimer = t
    }
    override func touchesEnded(with event: NSEvent) {
        holdTimer?.invalidate()
        alphaValue = baseAlpha
        if held { return }
        if Date().timeIntervalSince(downAt) >= ArtView.holdTime { fireHold() } else { onTap?() }
    }
    override func touchesCancelled(with event: NSEvent) {
        holdTimer?.invalidate()
        alphaValue = baseAlpha
    }
}

final class Capsule: NSView {
    let stack: NSStackView
    init(_ views: [NSView], spacing: CGFloat = 0) {
        stack = NSStackView(views: views)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        applyStyle()
        NotificationCenter.default.addObserver(forName: .lyricsBarConfigChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyStyle()
        }
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// "pill": frosted rounded group. "minimal": no background, icons float on the bar.
    func applyStyle() {
        let pill = cfg.buttonStyle == "pill"
        layer?.backgroundColor = NSColor.white.withAlphaComponent(pill ? 0.14 : 0).cgColor
        layer?.borderWidth = pill ? 0.5 : 0
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
    }
}

func timeLabel(_ align: NSTextAlignment) -> NSTextField {
    let l = NSTextField(labelWithString: "0:00")
    l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    l.textColor = NSColor.white.withAlphaComponent(0.85)
    l.alignment = align
    l.translatesAutoresizingMaskIntoConstraints = false
    l.widthAnchor.constraint(equalToConstant: 40).isActive = true
    return l
}

func fmt(_ t: Double) -> String {
    let s = max(0, Int(t.rounded(.down)))
    return String(format: "%d:%02d", s / 60, s % 60)
}

func fill(_ v: NSView, in p: NSView) {
    v.translatesAutoresizingMaskIntoConstraints = false
    p.addSubview(v)
    NSLayoutConstraint.activate([
        v.leadingAnchor.constraint(equalTo: p.leadingAnchor), v.trailingAnchor.constraint(equalTo: p.trailingAnchor),
        v.topAnchor.constraint(equalTo: p.topAnchor), v.bottomAnchor.constraint(equalTo: p.bottomAnchor),
    ])
}

enum Panel { case none, brightness, volume }

// MARK: - Library helper (library.py)

/// Spotify URIs are "spotify:<type>:<base62>"; keep only those characters before putting one in AppleScript.
/// (Legacy user IDs can also contain . _ -). ASCII only: nothing that could end an AppleScript string survives.
func spotifySafe(_ s: String) -> String {
    String(s.unicodeScalars.filter { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ":._-".unicodeScalars.contains($0)) })
}

func libraryJSON(_ args: [String], _ done: @escaping (Any?, String?) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", home + "/library.py"] + args
        let pipe = Pipe(), input = Pipe()
        p.standardOutput = pipe
        p.standardInput = input           // credentials go in on stdin, never argv/env/files
        p.standardError = FileHandle.nullDevice
        var data = Data()
        if (try? p.run()) != nil {
            input.fileHandleForWriting.write(Creds.forHelper)
            try? input.fileHandleForWriting.close()
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
        }
        var obj = try? JSONSerialization.jsonObject(with: data)
        if let d = obj as? [String: Any] {                              // refreshed tokens → Keychain
            if d["__creds"] != nil { Creds.absorb(fromHelper: d) }
            if let r = d["__result"] { obj = r }
        }
        DispatchQueue.main.async {
            if let d = obj as? [String: Any], let e = d["error"] as? String { done(nil, e) }
            else if obj == nil { done(nil, "No response") }
            else { done(obj, nil) }
        }
    }
}

// MARK: - Built-in stream player (Subsonic playlists)

struct StreamTrack {
    let uid = UUID()               // stable identity for queue edits (the same song can be queued twice)
    let id, title, artist, album: String
    let duration: Double
    let stream: URL
    let cover: URL?
    var coverId: String? = nil
}

final class StreamPlayer: NSObject, ObservableObject {
    static let shared = StreamPlayer()
    // two players so the next song can fade in while the current one fades out
    private let pa = AVPlayer(), pb = AVPlayer()
    private var cur: AVPlayer
    private var other: AVPlayer { cur === pa ? pb : pa }
    var player: AVPlayer { cur }
    var tracks: [StreamTrack] = []
    var index = 0
    var artwork: NSImage?
    var startedAt = Date.distantPast
    private var obs: [NSKeyValueObservation] = []
    private var timeObs: [Any] = []
    private var fade: Timer?
    private var monitor: Timer?

    var active: Bool { !tracks.isEmpty }
    var isPlaying: Bool { cur.timeControlStatus != .paused }

    override init() {
        cur = pa
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(ended(_:)),
                                               name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(failed(_:)),
                                               name: .AVPlayerItemFailedToPlayToEndTime, object: nil)
        for p in [pa, pb] {
            obs.append(p.observe(\.timeControlStatus) { [weak self] p, _ in
                DispatchQueue.main.async { if p === self?.cur { self?.objectWillChange.send(); self?.updateInfo() } }
            })
            timeObs.append(p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) {
                [weak self, weak p] _ in if p === self?.cur { self?.updateInfo(); self?.save() }
            })
        }
        let m = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.checkCrossfade(); self?.trackListening() }
        RunLoop.main.add(m, forMode: .common)
        monitor = m
        let rc = MPRemoteCommandCenter.shared()
        rc.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        rc.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        rc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        rc.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        rc.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
        rc.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(e.positionTime); return .success
        }
        setCommands(false)
    }

    func setCommands(_ on: Bool) {
        let rc = MPRemoteCommandCenter.shared()
        for c in [rc.playCommand, rc.pauseCommand, rc.togglePlayPauseCommand, rc.nextTrackCommand,
                  rc.previousTrackCommand, rc.changePlaybackPositionCommand] as [MPRemoteCommand] { c.isEnabled = on }
    }

    func load(_ t: [StreamTrack], start: Int = 0) {
        guard !t.isEmpty else { return }
        tracks = t; index = max(0, min(start, t.count - 1))
        startedAt = Date()
        setCommands(true)
        playCurrent()
    }

    func playCurrent() {
        cancelFade()
        guard tracks.indices.contains(index) else { stop(); return }
        cur.volume = 1
        cur.replaceCurrentItem(with: makeItem(tracks[index].stream))
        cur.play()
        trackChanged()
    }

    // MARK: queue editing (Touch Bar Up Next + Library window)

    var upcoming: [StreamTrack] { tracks.indices.contains(index + 1) ? Array(tracks[(index + 1)...]) : [] }

    func insertNext(_ t: [StreamTrack]) {
        defer { DispatchQueue.main.async { StreamPlayer.shared.save() } }
        guard active else { load(t); return }
        objectWillChange.send()
        tracks.insert(contentsOf: t, at: index + 1)
    }
    func append(_ t: [StreamTrack]) {
        defer { DispatchQueue.main.async { StreamPlayer.shared.save() } }
        guard active else { load(t); return }
        objectWillChange.send()
        tracks += t
    }
    /// i = position within `upcoming`
    func removeUpcoming(_ i: Int) {
        defer { DispatchQueue.main.async { StreamPlayer.shared.save() } }
        let a = index + 1 + i
        guard tracks.indices.contains(a) else { return }
        objectWillChange.send()
        tracks.remove(at: a)
    }
    /// from/to = positions within `upcoming` (to = final position)
    func moveUpcoming(_ from: Int, _ to: Int) {
        let a = index + 1 + from
        guard tracks.indices.contains(a) else { return }
        objectWillChange.send()
        let t = tracks.remove(at: a)
        tracks.insert(t, at: min(tracks.count, index + 1 + max(0, to)))
    }
    func moveUpcoming(fromOffsets: IndexSet, toOffset: Int) {
        guard tracks.indices.contains(index) else { return }     // queue ended meanwhile
        defer { DispatchQueue.main.async { StreamPlayer.shared.save() } }
        objectWillChange.send()
        var up = upcoming
        up.move(fromOffsets: fromOffsets, toOffset: toOffset)
        tracks = Array(tracks[...index]) + up
    }
    /// Reorder by identity, so edits stay correct even if the song changed meanwhile.
    func reorderUpcoming(_ uids: [UUID]) {
        guard tracks.indices.contains(index) else { return }
        defer { DispatchQueue.main.async { StreamPlayer.shared.save() } }
        let up = upcoming
        let byId = Dictionary(up.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<UUID>()
        var out = uids.compactMap { u -> StreamTrack? in
            guard let t = byId[u], seen.insert(u).inserted else { return nil }; return t
        }
        out += up.filter { !seen.contains($0.uid) }
        objectWillChange.send()
        tracks = Array(tracks[...index]) + out
    }
    func remove(uid: UUID) {
        defer { DispatchQueue.main.async { StreamPlayer.shared.save() } }
        guard let a = tracks.indices.first(where: { $0 > index && tracks[$0].uid == uid }) else { return }
        objectWillChange.send()
        tracks.remove(at: a)
    }
    func jump(uid: UUID) {
        if let i = tracks.indices.first(where: { $0 > index && tracks[$0].uid == uid }) { jump(to: i) }
    }

    func clearUpcoming() {
        guard tracks.indices.contains(index) else { return }
        defer { DispatchQueue.main.async { StreamPlayer.shared.save() } }
        objectWillChange.send()
        tracks = Array(tracks[...index])
    }

    /// Now Playing + artwork for tracks[index].
    // MARK: play reporting (scrobbling via the Subsonic server)
    // Counts time actually listened, so skipping or seeking to the end doesn't count as a play.
    private var listenUid: UUID?
    private var listened = 0.0, lastListenTick = Date()
    private var listenStarted = Date()
    private var sentNowPlaying = false, submitted = false

    /// Silent self-test: players muted and nothing reported.
    var testMuted = false { didSet { pa.isMuted = testMuted; pb.isMuted = testMuted } }

    private func trackListening() {
        let now = Date(), dt = now.timeIntervalSince(lastListenTick)
        lastListenTick = now
        let anyTarget = (cfg.reportPlays && Subsonic.auth != nil) || cfg.scrobbleLastfm || cfg.scrobbleListenBrainz
        guard anyTarget, !testMuted, active, tracks.indices.contains(index) else { return }
        let t = tracks[index]
        if t.uid != listenUid {
            listenUid = t.uid; listened = 0; sentNowPlaying = false; submitted = false; listenStarted = now
        }
        // only time actually playing counts (not paused, buffering or stalled)
        guard cur.timeControlStatus == .playing, dt < 2 else { return }
        if listened == 0 { listenStarted = now.addingTimeInterval(-dt) }   // the listen starts when sound does
        listened += dt
        if !sentNowPlaying {
            sentNowPlaying = true
            if cfg.reportPlays && Subsonic.auth != nil { Task { try? await Subsonic.scrobble(t.id, submission: false) } }
            Scrobbler.nowPlaying(.init(title: t.title, artist: t.artist, album: t.album, duration: t.duration))
        }
        // Last.fm rule: half the song or 4 minutes, whichever comes first (songs over 30 s)
        let need = min(max(t.duration, 31) / 2, 240)
        if !submitted && t.duration > 30 && listened >= need {
            submitted = true
            let started = listenStarted
            Scrobbler.scrobble(.init(title: t.title, artist: t.artist, album: t.album, duration: t.duration),
                               startedAt: started, subsonicId: t.id)
        }
    }
    /// Repeat-one replays count again.
    func resetListening() { listenUid = nil }

    private func trackChanged() {
        objectWillChange.send()
        DispatchQueue.main.async { self.save() }
        let t = tracks[index]
        artwork = nil
        updateInfo()
        guard let c = t.cover else { return }
        var req = URLRequest(url: c); req.setValue("LyricsBar/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] d, _, _ in
            guard let d, let img = NSImage(data: d) else { return }
            DispatchQueue.main.async {
                guard let self, self.tracks.indices.contains(self.index), self.tracks[self.index].id == t.id else { return }
                self.artwork = img; self.updateInfo()
            }
        }.resume()
    }

    // MARK: crossfade

    /// Song after the current one, honouring repeat-all.
    var followingIndex: Int? {
        if tracks.indices.contains(index + 1) { return index + 1 }
        return cfg.repeatMode == "all" && !tracks.isEmpty ? 0 : nil
    }

    private func checkCrossfade() {
        let xf = cfg.crossfadeSeconds
        guard xf > 0, active, isPlaying, fade == nil, cfg.repeatMode != "one", followingIndex != nil else { return }
        let d = cur.currentItem?.duration.seconds ?? 0
        let dur = d.isFinite && d > 0 ? d : tracks[index].duration
        let pos = cur.currentTime().seconds
        guard dur > xf * 2, pos.isFinite else { return }
        if dur - pos <= xf { startCrossfade(over: max(0.6, dur - pos)) }
    }

    private func startCrossfade(over d: Double) {
        let out = cur, inn = other
        let n = followingIndex ?? index + 1
        if n == index { resetListening() }          // repeat-all on a one-song queue: a new listen
        index = n
        inn.volume = 0
        inn.replaceCurrentItem(with: makeItem(tracks[index].stream))
        inn.play()
        cur = inn                 // Now Playing / lyrics switch to the incoming song right away
        trackChanged()
        let start = Date()
        let t = Timer(timeInterval: 0.04, repeats: true) { [weak self] timer in
            let f = min(1, Date().timeIntervalSince(start) / d)
            // equal-power curve keeps loudness steady through the fade
            inn.volume = Float(sin(f * .pi / 2))
            out.volume = Float(cos(f * .pi / 2))
            if f >= 1 {
                timer.invalidate(); self?.fade = nil
                out.pause(); out.replaceCurrentItem(with: nil); out.volume = 1
            }
        }
        RunLoop.main.add(t, forMode: .common)
        fade = t
    }

    /// Finish any fade immediately (used by pause / skip / seek).
    private func cancelFade() {
        guard fade != nil else { return }
        fade?.invalidate(); fade = nil
        other.pause(); other.replaceCurrentItem(with: nil); other.volume = 1
        cur.volume = 1
    }

    @objc func ended(_ n: Notification) {
        let item = n.object as? AVPlayerItem
        DispatchQueue.main.async {
            guard item != nil, item === self.cur.currentItem else { return }
            if cfg.repeatMode == "one" { self.resetListening(); self.seek(0); self.cur.play() } else { self.next() }
        }
    }

    // 3. a stream that fails (network drop, bad transcode) skips ahead instead of stalling
    private var itemObs: NSKeyValueObservation?
    private func makeItem(_ url: URL) -> AVPlayerItem {
        let it = AVPlayerItem(url: url)
        attachVisualizerTap(to: it)
        itemObs = it.observe(\.status) { [weak self] it, _ in
            guard it.status == .failed else { return }
            DispatchQueue.main.async {
                guard let self, it === self.cur.currentItem else { return }
                NSLog("LyricsBar: stream failed: \(it.error?.localizedDescription ?? "?") — skipping")
                self.next()
            }
        }
        return it
    }
    @objc func failed(_ n: Notification) {
        let item = n.object as? AVPlayerItem
        DispatchQueue.main.async {
            guard item != nil, item === self.cur.currentItem else { return }
            self.next()
        }
    }

    func play() { guard active else { return }; cur.play() }
    func jump(to i: Int) { guard tracks.indices.contains(i) else { return }; index = i; playCurrent() }
    func pause() { cancelFade(); cur.pause(); save() }
    func toggle() { isPlaying ? pause() : play() }
    func next() {
        if let n = followingIndex {
            if n == index { resetListening() }      // repeat of the same song counts as a new listen
            index = n; playCurrent()
        } else { stop() }
    }

    // MARK: shuffle (toggle keeps the original order so it can be restored)
    @Published var shuffled = false
    private var unshuffled: [UUID] = []
    func toggleShuffle() {
        guard active else { return }
        objectWillChange.send()
        let head = Array(tracks[...index]), up = upcoming
        if !shuffled {
            unshuffled = up.map(\.uid)
            tracks = head + up.shuffled()
        } else {
            let pos = Dictionary(unshuffled.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
            tracks = head + up.sorted { (pos[$0.uid] ?? .max) < (pos[$1.uid] ?? .max) }
        }
        shuffled.toggle()
        save()
    }

    // MARK: resume after restart (~/.touchbar-lyrics/queue.json; no credentials stored)
    static let queuePath = home + "/queue.json"
    func save() {
        // nothing loaded is NOT "queue cleared" (e.g. the login wasn't readable yet at launch): only stop() deletes it
        guard active else { return }
        let pos = cur.currentTime().seconds
        let obj: [String: Any] = [
            "index": index, "position": pos.isFinite ? pos : 0, "shuffled": shuffled,
            "tracks": tracks.map { ["id": $0.id, "title": $0.title, "artist": $0.artist, "album": $0.album,
                                    "duration": $0.duration, "coverId": $0.coverId ?? ""] },
        ]
        if let d = try? JSONSerialization.data(withJSONObject: obj) {
            try? d.write(to: URL(fileURLWithPath: StreamPlayer.queuePath), options: .atomic)
        }
    }
    /// Load the saved queue paused at its old position (never starts playing by itself).
    private var restoreRetries = 0
    func restore(force: Bool = false) {
        // the Subsonic login comes from the Keychain, which may still be waiting on a permission prompt
        if Subsonic.auth == nil, FileManager.default.fileExists(atPath: StreamPlayer.queuePath), restoreRetries < 60 {
            restoreRetries += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.restore(force: force) }
            return
        }
        guard cfg.resumeQueue || force, !active, let d = FileManager.default.contents(atPath: StreamPlayer.queuePath),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let list = j["tracks"] as? [[String: Any]] else { return }
        let t: [StreamTrack] = list.compactMap { e in
            guard let id = e["id"] as? String, let u = Subsonic.streamURL(id) else { return nil }
            let c = (e["coverId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return StreamTrack(id: id, title: e["title"] as? String ?? "", artist: e["artist"] as? String ?? "",
                               album: e["album"] as? String ?? "", duration: (e["duration"] as? NSNumber)?.doubleValue ?? 0,
                               stream: u, cover: Subsonic.coverURL(c), coverId: c)
        }
        guard !t.isEmpty else { return }
        tracks = t
        index = max(0, min(t.count - 1, (j["index"] as? NSNumber)?.intValue ?? 0))
        shuffled = j["shuffled"] as? Bool ?? false
        setCommands(true)
        cur.volume = 1
        cur.replaceCurrentItem(with: makeItem(tracks[index].stream))
        let pos = (j["position"] as? NSNumber)?.doubleValue ?? 0
        cur.seek(to: CMTime(seconds: pos, preferredTimescale: 600))
        trackChanged()
    }
    func previous() {
        if cur.currentTime().seconds > 3 || index == 0 { seek(0) } else { index -= 1; playCurrent() }
    }
    func seek(_ s: Double) {
        cancelFade()
        cur.seek(to: CMTime(seconds: s, preferredTimescale: 600)) { [weak self] _ in
            DispatchQueue.main.async { self?.updateInfo() }
        }
    }
    func stop() {
        objectWillChange.send()
        try? FileManager.default.removeItem(atPath: StreamPlayer.queuePath)
        cancelFade()
        cur.pause()
        cur.replaceCurrentItem(with: nil)
        tracks = []
        setCommands(false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Publishes to the system Now Playing feed, so lyricsd / media keys / Control Center see it.
    func updateInfo() {
        guard tracks.indices.contains(index) else { return }
        let t = tracks[index]
        let pos = cur.currentTime().seconds
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title, MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album, MPMediaItemPropertyPlaybackDuration: t.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: pos.isFinite ? pos : 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let a = artwork { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: a.size) { _ in a } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
}

// MARK: - Liked (starred) songs, shared by the Touch Bar ♥ and the Library

final class LikedCache: ObservableObject {
    static let shared = LikedCache()
    @Published private(set) var ids = Set<String>()
    func reload() {
        guard Subsonic.auth != nil else { return }
        Task { @MainActor in if let s = try? await Subsonic.starred() { ids = Set(s.map(\.id)) } }
    }
    func toggle(_ id: String) {
        let liked = ids.contains(id)
        if liked { ids.remove(id) } else { ids.insert(id) }        // optimistic
        Task { @MainActor in
            do { if liked { try await Subsonic.unstar([id]) } else { try await Subsonic.star([id]) } }
            catch { if liked { ids.insert(id) } else { ids.remove(id) } }
        }
    }
}

// MARK: - Playing Subsonic songs (shared by the Touch Bar picker and the Library window)

func streamTracks(_ songs: [SSong]) -> [StreamTrack] {
    songs.compactMap { s in
        guard let u = Subsonic.streamURL(s.id) else { return nil }
        return StreamTrack(id: s.id, title: s.title, artist: s.artist, album: s.album,
                           duration: Double(s.duration), stream: u, cover: Subsonic.coverURL(s.coverArt), coverId: s.coverArt)
    }
}

/// Replace the queue and play. Pauses other players first if that setting is on.
func playSongs(_ songs: [SSong], start: Int = 0, shuffle: Bool = false) {
    var t = streamTracks(songs)
    guard !t.isEmpty else { return }
    var s = start
    if shuffle { t.shuffle(); s = 0 }
    let sp = StreamPlayer.shared
    if cfg.pauseOthers && !(sp.active && sp.isPlaying) && systemState().playing {
        run(mediaControl, ["pause"])   // only when something else is actually playing (a bare "pause" can wake Music)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { sp.load(t, start: s) }
    } else {
        sp.load(t, start: s)
    }
}
// MARK: - Transport routing
// A system media command with no Now Playing app makes macOS launch Apple Music, so commands go
// straight to LyricsBar's own player when it holds the queue, and "play" with nothing loaded
// starts the default app chosen in Settings.

func systemState() -> (playing: Bool, bundle: String, title: String) {
    guard let d = FileManager.default.contents(atPath: home + "/state.json"),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return (false, "", "") }
    return (j["playing"] as? Bool ?? false, j["bundle"] as? String ?? "", j["title"] as? String ?? "")
}

func ownPlayerInCharge() -> Bool {
    guard StreamPlayer.shared.active else { return false }
    let st = systemState()
    return st.title.isEmpty || st.bundle == Bundle.main.bundleIdentifier
}

/// Start something when nothing is loaded. Returns false if the user chose "ask" (caller opens the picker).
@discardableResult
func startDefaultPlayer() -> Bool {
    switch cfg.defaultApp {
    case "subsonic":
        let sp = StreamPlayer.shared
        sp.restore(force: true)                    // pick up the saved queue if there is one
        if sp.active { sp.play(); return true }
        Task { @MainActor in
            if let liked = try? await Subsonic.starred(), !liked.isEmpty { playSongs(liked, shuffle: true) }
        }
        return true
    case "spotify":
        run("/usr/bin/osascript", ["-e", "tell application \"Spotify\" to play"]); return true
    case "applemusic":
        run("/usr/bin/osascript", ["-e", "tell application \"Music\" to play"]); return true
    default:
        return false
    }
}

enum Transport { case toggle, next, previous, seek(Double) }

/// Returns false only for a play with nothing loaded and the default set to "ask".
@discardableResult
func transport(_ t: Transport) -> Bool {
    let sp = StreamPlayer.shared
    if ownPlayerInCharge() {
        switch t {
        case .toggle: sp.toggle()
        case .next: sp.next()
        case .previous: sp.previous()
        case .seek(let v): sp.seek(v)
        }
        return true
    }
    if systemState().title.isEmpty {               // nothing loaded anywhere
        if case .toggle = t { return startDefaultPlayer() }
        return true                                 // skip/seek with nothing loaded: do nothing (don't wake Music)
    }
    switch t {
    case .toggle: run(mediaControl, ["toggle-play-pause"])
    case .next: run(mediaControl, ["next-track"])
    case .previous: run(mediaControl, ["previous-track"])
    case .seek(let v): run(mediaControl, ["seek", String(format: "%.2f", v)])
    }
    return true
}

func queueNext(_ songs: [SSong]) {
    StreamPlayer.shared.active ? StreamPlayer.shared.insertNext(streamTracks(songs)) : playSongs(songs)
}
func queueLater(_ songs: [SSong]) {
    StreamPlayer.shared.active ? StreamPlayer.shared.append(streamTracks(songs)) : playSongs(songs)
}

// MARK: - Slim slider with a pill handle (seek bar, brightness, volume)

final class ScrubBar: NSView {
    var minValue = 0.0
    var maxValue = 1.0 { didSet { needsDisplay = true } }
    var doubleValue = 0.0 { didSet { needsDisplay = true } }
    var floatValue: Float { get { Float(doubleValue) } set { doubleValue = Double(newValue) } }
    var onChange: ((Double) -> Void)?
    var onEnd: ((Double) -> Void)?
    private(set) var dragging = false { didSet { needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.direct]
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setContentHuggingPriority(.init(1), for: .horizontal)
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    private var knob: NSSize { dragging ? NSSize(width: 26, height: 12) : NSSize(width: 20, height: 9) }
    private var fraction: CGFloat {
        maxValue > minValue ? CGFloat(max(0, min(1, (doubleValue - minValue) / (maxValue - minValue)))) : 0
    }

    override func draw(_ dirty: NSRect) {
        let k = knob, inset = k.width / 2
        let w = bounds.width - inset * 2, midY = bounds.midY
        let trackH: CGFloat = dragging ? 5 : 4
        let track = NSRect(x: inset, y: midY - trackH / 2, width: w, height: trackH)
        NSColor.white.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: trackH / 2, yRadius: trackH / 2).fill()
        let x = inset + w * fraction
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: inset, y: track.minY, width: x - inset, height: trackH),
                     xRadius: trackH / 2, yRadius: trackH / 2).fill()
        let knobRect = NSRect(x: x - k.width / 2, y: midY - k.height / 2, width: k.width, height: k.height)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = 3
        sh.set()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: knobRect, xRadius: k.height / 2, yRadius: k.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func value(at x: CGFloat) -> Double {
        let inset = knob.width / 2
        let f = max(0, min(1, (x - inset) / max(1, bounds.width - inset * 2)))
        return minValue + Double(f) * (maxValue - minValue)
    }
    private func track(_ event: NSEvent, phase: NSTouch.Phase) {
        guard let t = event.touches(matching: phase, in: self).first else { return }
        doubleValue = value(at: t.location(in: self).x)
        onChange?(doubleValue)
    }
    override func touchesBegan(with event: NSEvent) { dragging = true; track(event, phase: .began) }
    override func touchesMoved(with event: NSEvent) { track(event, phase: .moved) }
    override func touchesEnded(with event: NSEvent) { dragging = false; onEnd?(doubleValue) }
    var onCancel: (() -> Void)?
    override func touchesCancelled(with event: NSEvent) { dragging = false; onCancel?() }
}

// MARK: - Picker (providers → playlists), a horizontally scrolling Touch Bar list

final class TBPicker: NSView, NSScrubberDataSource, NSScrubberDelegate, NSScrubberFlowLayoutDelegate {
    struct Item { let title: String; var dim = false; var hold: (() -> Void)? = nil; let action: (() -> Void)? }
    private var visible = NSRange(location: 0, length: 0)
    private var suppressSelectUntil = Date.distantPast
    let scrubber = NSScrubber()
    var items: [Item] = [] { didSet { scrubber.reloadData(); if !items.isEmpty { scrubber.scrollItem(at: 0, to: .none) } } }
    var onInteract: (() -> Void)?
    let font = NSFont.systemFont(ofSize: 13, weight: .medium)

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrubber.dataSource = self
        scrubber.delegate = self
        let layout = NSScrubberFlowLayout(); layout.itemSpacing = 8
        scrubber.scrubberLayout = layout
        scrubber.mode = .free
        scrubber.selectionBackgroundStyle = nil
        scrubber.backgroundColor = .clear
        scrubber.showsAdditionalContentIndicators = false
        let press = NSPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
        press.minimumPressDuration = 0.5
        press.allowedTouchTypes = [.direct]
        scrubber.addGestureRecognizer(press)
        wantsLayer = true
        layer?.cornerRadius = 8; layer?.masksToBounds = true
        scrubber.register(NSScrubberTextItemView.self, forItemIdentifier: .init("t"))
        fill(scrubber, in: self)
    }
    required init?(coder: NSCoder) { fatalError() }

    func numberOfItems(for s: NSScrubber) -> Int { items.count }

    func scrubber(_ s: NSScrubber, viewForItemAt i: Int) -> NSScrubberItemView {
        let v = s.makeItem(withIdentifier: .init("t"), owner: nil) as! NSScrubberTextItemView
        v.title = items[i].title
        v.textField.font = font
        v.textField.textColor = items[i].dim ? NSColor.white.withAlphaComponent(0.55) : .white
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(items[i].action == nil ? 0 : 0.14).cgColor
        v.layer?.cornerRadius = 8
        return v
    }

    func scrubber(_ s: NSScrubber, layout: NSScrubberFlowLayout, sizeForItemAt i: Int) -> NSSize {
        let w = (items[i].title as NSString).size(withAttributes: [.font: font]).width
        if items[i].title == "|" { return NSSize(width: 14, height: 30) }
        return NSSize(width: min(260, ceil(w) + 30), height: 30)
    }

    @objc func pressed(_ g: NSPressGestureRecognizer) {
        guard g.state == .began else { return }
        let p = g.location(in: scrubber)
        for i in visible.location..<NSMaxRange(visible) where items.indices.contains(i) {
            guard let v = scrubber.itemViewForItem(at: i) else { continue }
            if scrubber.convert(v.bounds, from: v).contains(p), let h = items[i].hold {
                suppressSelectUntil = Date().addingTimeInterval(1.5)
                onInteract?(); h(); return
            }
        }
    }

    func scrubber(_ s: NSScrubber, didSelectItemAt i: Int) {
        onInteract?()
        if Date() < suppressSelectUntil { s.selectedIndex = -1; return }   // that touch was a hold
        if items.indices.contains(i) { items[i].action?() }
        s.selectedIndex = -1
    }

    func scrubber(_ s: NSScrubber, didChangeVisible r: NSRange) { visible = r; onInteract?() }
}

final class BarView: NSView {
    let bg = NSImageView()
    let tint = NSView()
    // left
    let artButton = ArtView()
    let lyric = SwipeLabel(labelWithString: "")
    let queueStrip = QueueStrip()
    let lyricArea = LyricTouchArea()
    var extras: Capsule!, likeBtn: PillButton!, shuffleBtn: PillButton!, repeatBtn: PillButton!
    var likedSync: AnyCancellable?
    var backBtn: PillButton!, backCap: Capsule!
    var backAction: (() -> Void)?
    var pendingSlide: (CATransitionSubtype, Date)?
    let mediaView = NSView()
    var playBtn: PillButton!
    let elapsedLbl = timeLabel(.right)
    let remainLbl = timeLabel(.left)
    let scrubber = ScrubBar()
    // right
    var strip: Capsule!
    var panel: Capsule!
    var volBtn: PillButton!
    var panelIcon: PillButton!
    let panelSlider = ScrubBar()

    var bundleId = ""
    var isPlaying = false
    var duration = 0.0
    var elapsedAt: (pos: Double, t: Double, rate: Double) = (0, 0, 0)
    var localSeek: (pos: Double, t: Double)?
    var scrubbing = false
    var mediaMode = false
    var panelMode = Panel.none
    let picker = TBPicker()
    var pickerMode = false
    var pickerTimer: Timer?
    var shuffle = false
    var currentTitle = ""
    var pickerRow: NSStackView!
    var pickerTransport: Capsule!
    var pickerPlayBtn: PillButton!
    var briBtn: PillButton!, appsBtn: PillButton!
    var upNextReturnsToMedia = false
    let vizBG = VisualizerView(style: .background)
    let vizCompact = VisualizerView(style: .compact)
    let progress = NSView()
    var accent: NSColor?
    var titleCardUntil = Date.distantPast
    var outroActive = false
    var lyricKey = ""
    var lyricLeadArt: NSLayoutConstraint!, lyricLeadViz: NSLayoutConstraint!
    var lyricLimits: [NSLayoutConstraint] = []
    var lyricPinArt: NSLayoutConstraint!, lyricPinViz: NSLayoutConstraint!, lyricCenter: NSLayoutConstraint!
    var mediaTimer: Timer?, panelTimer: Timer?, seekTimer: Timer?
    var keepControlsWhilePaused = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        bg.imageScaling = .scaleAxesIndependently
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        fill(bg, in: self); fill(tint, in: self); fill(vizBG, in: self)
        addSubview(lyricArea)     // above the background, below every control added later
        progress.wantsLayer = true
        progress.layer?.cornerRadius = 1
        addSubview(progress)

        // album art = media-controls toggle
        artButton.image = noteImage()
        artButton.onTap = { [weak self] in self?.toggleMedia() }
        artButton.onHold = { [weak self] in self?.closePicker(); SettingsWindow.shared.toggle() }
        artButton.translatesAutoresizingMaskIntoConstraints = false
        artButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        artButton.heightAnchor.constraint(equalToConstant: 26).isActive = true

        lyric.font = .systemFont(ofSize: 15, weight: .semibold)
        lyric.textColor = .white
        lyric.lineBreakMode = .byTruncatingTail
        lyric.wantsLayer = true
        let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.55); sh.shadowBlurRadius = 3
        sh.shadowOffset = .init(width: 0, height: -1)
        lyric.shadow = sh
        lyric.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        lyric.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        // media controls (hidden until art is tapped)
        playBtn = PillButton(symbol("play.fill", 15), self, #selector(playPause))
        let transport = Capsule([
            PillButton(symbol("backward.fill", 13), self, #selector(prev)),
            playBtn,
            PillButton(symbol("forward.fill", 13), self, #selector(next)),
        ])
        scrubber.onChange = { [weak self] v in self?.scrubChanged(v) }
        scrubber.onEnd = { [weak self] v in self?.scrubEnded(v) }
        scrubber.onCancel = { [weak self] in self?.scrubbing = false }
        let scrubRow = NSStackView(views: [elapsedLbl, scrubber, remainLbl])
        scrubRow.spacing = 8
        likeBtn = PillButton(symbol("heart", 14), self, #selector(likeTapped), width: 44)
        likeBtn.isHidden = true
        let upNext = Capsule([
            likeBtn,
            PillButton(symbol("line.3.horizontal", 14), self, #selector(openMenuFromMedia), width: 44),
            PillButton(symbol("text.line.first.and.arrowtriangle.forward", 13), self, #selector(openUpNextFromMedia), width: 44),
        ])
        shuffleBtn = PillButton(symbol("shuffle", 13), self, #selector(shuffleTapped), width: 40)
        repeatBtn = PillButton(symbol("repeat", 13), self, #selector(repeatTapped), width: 40)
        extras = Capsule([shuffleBtn, repeatBtn])       // shown next to ‹ in Up Next
        extras.isHidden = true
        likedSync = LikedCache.shared.$ids.sink { [weak self] _ in DispatchQueue.main.async { self?.updateExtras() } }
        let mediaStack = NSStackView(views: [transport, scrubRow, upNext])
        mediaStack.spacing = 12
        fill(mediaStack, in: mediaView)
        mediaView.alphaValue = 0
        mediaView.isHidden = true
        // picker row = [mini transport (when something is paused)] + scrolling list
        pickerPlayBtn = PillButton(symbol("play.fill", 15), self, #selector(playPause))
        pickerTransport = Capsule([
            PillButton(symbol("backward.fill", 13), self, #selector(prev)),
            pickerPlayBtn,
            PillButton(symbol("forward.fill", 13), self, #selector(next)),
        ])
        picker.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // pinned ‹ back button for submenus; turns into a 🗑 while a queued song is held
        backBtn = PillButton(symbol("chevron.left", 14), self, #selector(pickerBack), width: 44)
        backCap = Capsule([backBtn])
        backCap.isHidden = true
        queueStrip.isHidden = true
        queueStrip.trash = backCap
        queueStrip.onInteract = { [weak self] in self?.bumpPickerTimer() }
        queueStrip.onLift = { [weak self] up in
            guard let self else { return }
            if !up && self.queueDirty { DispatchQueue.main.async { self.syncQueueStrip() } }
            self.backCap.isHidden = false
            self.backBtn.image = symbol(up ? "trash" : "chevron.left", 14)
            self.backBtn.contentTintColor = .white
        }
        queueStrip.onTrashHover = { [weak self] over in
            self?.backBtn.image = over ? coloredSymbol("trash.fill", 14, .systemRed) : symbol("trash", 14)
        }
        queueStrip.onTap = { [weak self] e in
            guard let self else { return }
            if self.stripIsSpotify {
                if let u = e.uid { SpotifyQueue.shared.jump(id: u) { err in if let err { self.toast(err, seconds: 3) } } }
            } else if let u = e.uid { StreamPlayer.shared.jump(uid: u) }
            self.closePicker()
        }
        queueStrip.onMove = { [weak self] in
            guard let self else { return }
            let ids = self.queueStrip.entries.compactMap(\.uid)
            if self.stripIsSpotify { SpotifyQueue.shared.reorder(ids) { err in if let err { self.toast(err, seconds: 3) } } }
            else { StreamPlayer.shared.reorderUpcoming(ids) }
        }
        queueStrip.onRemove = { [weak self] e in
            guard let self, let u = e.uid else { return }
            if self.stripIsSpotify { SpotifyQueue.shared.remove(id: u) { err in if let err { self.toast(err, seconds: 3) } } }
            else { StreamPlayer.shared.remove(uid: u) }
        }
        // keep the strip in sync with the player (song changes, Library edits); never mid-drag
        queueSync = StreamPlayer.shared.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncQueueStrip(); self?.updateExtras() }
        }
        lyricArea.label = lyric
        lyricArea.onSwipe = { [weak self] dir in
            guard let self, !self.currentTitle.isEmpty else { self?.lyric.alphaValue = 1; return }
            self.pendingSlide = (dir > 0 ? .fromRight : .fromLeft, Date())
            _ = self.lyric
            dir > 0 ? self.next() : self.prev()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.lyric.alphaValue = 1 }
        }
        // tap and long-press each do what's chosen in Settings → General → Lyrics gestures
        lyricArea.onTap = { [weak self] in self?.lyricGesture(cfg.lyricTapAction) }
        lyricArea.onLongPress = { [weak self] in self?.lyricGesture(cfg.lyricHoldAction) }
        pickerRow = NSStackView(views: [backCap, extras, pickerTransport, picker, queueStrip])
        pickerRow.spacing = 10
        pickerRow.alphaValue = 0
        pickerRow.isHidden = true
        picker.onInteract = { [weak self] in self?.bumpPickerTimer() }

        // right: control strip + slider panel
        volBtn = PillButton(symbol(Sys.volumeSymbol, 14), self, #selector(openVolume), width: 52)
        briBtn = PillButton(symbol("sun.max.fill", 14), self, #selector(openBrightness), width: 52)
        appsBtn = PillButton(symbol("books.vertical.fill", 14), self, #selector(openApps), width: 52)
        strip = Capsule([briBtn, volBtn, appsBtn], spacing: 10)
        for (btn, isVol) in [(briBtn!, false), (volBtn!, true)] {
            let o = SlideOverlay()
            fill(o, in: btn)
            o.onTap = { [weak self] in isVol ? self?.openVolume() : self?.openBrightness() }
            o.onSlide = { [weak self] d in
                guard let self else { return }
                if isVol {
                    if Sys.muted && d > 0 { Sys.muted = false }
                    Sys.volume = max(0, min(1, Sys.volume + d))
                    self.volBtn.image = symbol(Sys.volumeSymbol, 14)
                    self.toast("Volume  \(Int((Sys.muted ? 0 : Sys.volume) * 100))%")
                } else {
                    Sys.brightness = max(0, min(1, Sys.brightness + d))
                    self.toast("Brightness  \(Int(Sys.brightness * 100))%")
                }
            }
        }
        strip.stack.edgeInsets = .init(top: 0, left: 4, bottom: 0, right: 4)
        strip.setContentHuggingPriority(.required, for: .horizontal)
        panelIcon = PillButton(nil, self, #selector(panelIconTapped), width: 40)
        panelSlider.onChange = { [weak self] _ in self?.panelSlid() }
        panelSlider.widthAnchor.constraint(equalToConstant: 210).isActive = true
        panel = Capsule([PillButton(symbol("xmark", 11, .bold), self, #selector(closePanel), width: 34),
                         panelIcon, panelSlider], spacing: 4)
        panel.stack.edgeInsets = .init(top: 0, left: 0, bottom: 0, right: 10)
        panel.alphaValue = 0
        panel.isHidden = true
        panel.setContentHuggingPriority(.required, for: .horizontal)

        for v in [artButton, vizCompact, lyric, mediaView, pickerRow!, strip!, panel!] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            artButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            artButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            vizCompact.leadingAnchor.constraint(equalTo: artButton.trailingAnchor, constant: 6),
            vizCompact.centerYAnchor.constraint(equalTo: centerYAnchor),
            vizCompact.widthAnchor.constraint(equalToConstant: 30),
            vizCompact.heightAnchor.constraint(equalToConstant: 22),
            lyric.centerYAnchor.constraint(equalTo: centerYAnchor),
            mediaView.leadingAnchor.constraint(equalTo: artButton.trailingAnchor, constant: 10),
            mediaView.trailingAnchor.constraint(equalTo: strip.leadingAnchor, constant: -24),
            pickerRow.leadingAnchor.constraint(equalTo: artButton.trailingAnchor, constant: 10),
            pickerRow.trailingAnchor.constraint(equalTo: strip.leadingAnchor, constant: -16),
            pickerRow.topAnchor.constraint(equalTo: topAnchor), pickerRow.bottomAnchor.constraint(equalTo: bottomAnchor),
            mediaView.topAnchor.constraint(equalTo: topAnchor), mediaView.bottomAnchor.constraint(equalTo: bottomAnchor),

            strip.trailingAnchor.constraint(equalTo: trailingAnchor),
            strip.centerYAnchor.constraint(equalTo: centerYAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        // hard limits (never overlap the icon / right side) + a soft pin: left edge, or the bar's true centre
        let areaFill = lyricArea.trailingAnchor.constraint(equalTo: trailingAnchor); areaFill.priority = .defaultLow
        NSLayoutConstraint.activate([
            lyricArea.leadingAnchor.constraint(equalTo: artButton.trailingAnchor, constant: 4),
            lyricArea.trailingAnchor.constraint(lessThanOrEqualTo: strip.leadingAnchor, constant: -6),
            lyricArea.topAnchor.constraint(equalTo: topAnchor), lyricArea.bottomAnchor.constraint(equalTo: bottomAnchor),
            areaFill,
        ])
        lyricLeadArt = lyric.leadingAnchor.constraint(greaterThanOrEqualTo: artButton.trailingAnchor, constant: 10)
        lyricLeadViz = lyric.leadingAnchor.constraint(greaterThanOrEqualTo: vizCompact.trailingAnchor, constant: 6)
        lyricLeadArt.isActive = true
        lyricPinArt = lyric.leadingAnchor.constraint(equalTo: artButton.trailingAnchor, constant: 10)
        lyricPinViz = lyric.leadingAnchor.constraint(equalTo: vizCompact.trailingAnchor, constant: 6)
        lyricCenter = lyric.centerXAnchor.constraint(equalTo: centerXAnchor)
        for c in [lyricPinArt!, lyricPinViz!, lyricCenter!] { c.priority = .init(600) }
        // the label spans the free space so centred alignment works
        lyricLimits = [
            lyric.trailingAnchor.constraint(lessThanOrEqualTo: strip.leadingAnchor, constant: -14),
            lyric.trailingAnchor.constraint(lessThanOrEqualTo: panel.leadingAnchor, constant: -14),
            lyric.trailingAnchor.constraint(lessThanOrEqualTo: mediaView.leadingAnchor, constant: -16),
        ]
        lyricLimits[0].isActive = true
        let w = widthAnchor.constraint(equalToConstant: barSize.width); w.priority = .init(1); w.isActive = true
        heightAnchor.constraint(equalToConstant: barSize.height).isActive = true
        applyConfig()
    }

    /// Centre on the physical Touch Bar, which can be a few points wider than this view.
    override func layout() {
        super.layout()
        guard let w = window else { return }
        let c = (w.frame.width / 2 - convert(bounds, to: nil).midX).rounded()
        if lyricCenter.constant != c { lyricCenter.constant = c }
    }

    /// Re-read settings (called on launch and whenever the Settings window changes something).
    func applyConfig() {
        lyric.font = .systemFont(ofSize: cfg.lyricFontSize, weight: .semibold)
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(cfg.dimAmount).cgColor
        briBtn.isHidden = !cfg.showBrightness
        volBtn.isHidden = !cfg.showVolume
        appsBtn.isHidden = !cfg.showApps
        strip.isHidden = panelMode != .none || (!cfg.showBrightness && !cfg.showVolume && !cfg.showApps)
        if !pickerMode { shuffle = cfg.defaultShuffle }
        applyVisualizer()
        let k = lyricKey; lyricKey = "\u{1}"; if Date() >= titleCardUntil { setLyric(k) }   // re-render with new style
    }

    func applyVisualizer() {
        let style = cfg.visualizerStyle
        vizBG.isHidden = style != "background"
        vizBG.alphaValue = cfg.visualizerOpacity
        let compact = style == "compact"
        vizCompact.isHidden = !compact || lyric.isHidden
        vizCompact.alphaValue = 1
        lyricLeadArt.isActive = !compact
        lyricLeadViz.isActive = compact
        let centered = cfg.lyricAlignment == "center"
        lyricPinArt.isActive = !centered && !compact
        lyricPinViz.isActive = !centered && compact
        lyricCenter.isActive = centered
        let c = cfg.visualizerColor == "album" ? (accent ?? .white) : .white
        vizBG.color = c; vizCompact.color = c
        progress.layer?.backgroundColor = (accent ?? .white).withAlphaComponent(0.75).cgColor
    }

    func updateProgress() {
        guard cfg.showProgress, duration > 0, !currentTitle.isEmpty else { progress.isHidden = true; return }
        progress.isHidden = false
        let target: CGFloat = isPlaying ? 1 : 0          // no stray coloured bar while paused
        if progress.alphaValue != target && progress.animator().alphaValue != target {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.35; progress.animator().alphaValue = target }
        }
        let f = CGFloat(max(0, min(1, position / duration)))
        progress.frame = NSRect(x: 0, y: 0, width: bounds.width * f, height: 2)
    }

    func lyricAttrs(_ color: NSColor, _ weight: NSFont.Weight = .semibold) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = cfg.lyricAlignment == "center" ? .center : .left
        p.lineBreakMode = .byTruncatingTail
        return [.font: NSFont.systemFont(ofSize: cfg.lyricFontSize, weight: weight), .foregroundColor: color, .paragraphStyle: p]
    }

    func animateLyric() {
        switch cfg.lyricTransition {
        case "none": return
        case "fade":
            let t = CATransition(); t.type = .fade; t.duration = 0.25
            lyric.layer?.add(t, forKey: "lyric")
        default:
            let t = CATransition(); t.type = .push; t.subtype = .fromTop; t.duration = 0.22
            t.timingFunction = .init(name: .easeOut)
            lyric.layer?.add(t, forKey: "lyric")
        }
    }

    /// "Title · Artist" for a few seconds when a new song starts; lyrics resume afterwards.
    func showTitleCard(_ title: String, _ artist: String, slideIn: Bool = false) {
        let wasOutro = outroActive
        outroActive = false
        guard cfg.titleCardSeconds > 0, !title.isEmpty else {
            if wasOutro { titleCardUntil = .distantPast; lyricKey = "\u{1}" }
            return
        }
        titleCardUntil = Date().addingTimeInterval(cfg.titleCardSeconds)
        lyricKey = "\u{1}card"
        let a = NSMutableAttributedString(string: title, attributes: lyricAttrs(.white))
        if !artist.isEmpty {
            a.append(NSAttributedString(string: "   " + artist, attributes: lyricAttrs(NSColor.white.withAlphaComponent(0.6), .regular)))
        }
        lyric.alphaValue = 1
        var sub: CATransitionSubtype? = slideIn ? .fromRight : nil
        if let p = pendingSlide, Date().timeIntervalSince(p.1) < 4 { sub = p.0 }
        pendingSlide = nil
        if let sub {
            // the next title slides in (from the right, or from the left after swiping back)
            let t = CATransition(); t.type = .push; t.subtype = sub; t.duration = 0.4
            t.timingFunction = .init(name: .easeInEaseOut)
            lyric.layer?.add(t, forKey: "lyric")
        } else { animateLyric() }
        lyric.attributedStringValue = a
    }

    /// Near the end of a song: its title comes back, with the next song's title to the right.
    func showOutro(_ title: String, _ artist: String, next: (String, String)?) {
        outroActive = true
        titleCardUntil = .distantFuture
        lyricKey = "\u{1}outro"
        let a = NSMutableAttributedString(string: title, attributes: lyricAttrs(.white))
        if !artist.isEmpty {
            a.append(NSAttributedString(string: "   " + artist, attributes: lyricAttrs(NSColor.white.withAlphaComponent(0.6), .regular)))
        }
        if let n = next, !n.0.isEmpty {
            var small = lyricAttrs(NSColor.white.withAlphaComponent(0.45), .bold)
            small[.font] = NSFont.systemFont(ofSize: max(9, cfg.lyricFontSize - 5), weight: .bold)
            small[.kern] = 1.2
            small[.baselineOffset] = 1.5
            a.append(NSAttributedString(string: "        NEXT  ", attributes: small))
            a.append(NSAttributedString(string: n.0, attributes: lyricAttrs(NSColor.white.withAlphaComponent(0.85))))
            if !n.1.isEmpty {
                a.append(NSAttributedString(string: "   " + n.1, attributes: lyricAttrs(NSColor.white.withAlphaComponent(0.45), .regular)))
            }
        }
        let t = CATransition(); t.type = .fade; t.duration = 0.35
        lyric.layer?.add(t, forKey: "lyric")
        lyric.attributedStringValue = a
    }

    func cancelOutro() {
        guard outroActive else { return }
        outroActive = false
        titleCardUntil = .distantPast
        lyricKey = "\u{1}"
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: state updates

    func setLyric(_ s: String) {
        if Date() < titleCardUntil || pausedActive { return }
        guard s != lyricKey else { return }
        lyricKey = s
        animateLyric()
        lyric.attributedStringValue = NSAttributedString(string: s, attributes: lyricAttrs(.white))
    }

    /// What the lyric line shows while paused (Settings → General → While paused).
    var pausedActive = false
    func showPaused(_ a: NSAttributedString, key: String) {
        guard Date() >= titleCardUntil, !outroActive else { return }
        pausedActive = true
        guard lyricKey != key else { return }
        lyricKey = key
        animateLyric()
        lyric.attributedStringValue = a
    }
    func clearPaused() {
        guard pausedActive else { return }
        pausedActive = false
        lyricKey = "\u{1}"                     // the next lyric line re-renders
    }

    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        playBtn.image = symbol(playing ? "pause.fill" : "play.fill", 15)
        pickerPlayBtn?.image = playBtn.image
    }

    /// Faded cover = paused for longer than the art timeout (App.updateBackgroundMode decides).
    private var artDimmed = false
    func setArtDimmed(_ dim: Bool) {
        guard dim != artDimmed else { return }
        artDimmed = dim
        let a: CGFloat = dim ? 0.45 : 1
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.6; artButton.animator().alphaValue = a },
                                           completionHandler: { [weak self] in self?.artButton.baseAlpha = a })
    }

    var hasArtwork = false
    func setArtwork(_ img: NSImage?) {
        hasArtwork = img != nil
        artButton.image = img ?? noteImage()
    }

    var position: Double {
        let now = Date().timeIntervalSince1970
        if let l = localSeek, l.t > elapsedAt.t {
            return l.pos + (isPlaying ? now - l.t : 0)
        }
        return elapsedAt.pos + (now - elapsedAt.t) * elapsedAt.rate
    }

    func updateScrubber() {
        guard mediaMode, !scrubbing, !scrubber.dragging, duration > 0 else { return }
        let p = min(position, duration)
        scrubber.maxValue = duration
        scrubber.doubleValue = p
        elapsedLbl.stringValue = fmt(p)
        remainLbl.stringValue = "-" + fmt(duration - p)
    }

    // MARK: left side

    func show(_ v: NSView, _ on: Bool) {
        if v === lyric && cfg.visualizerStyle == "compact" { show(vizCompact, on) }
        if on { v.isHidden = false }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.2
            v.animator().alphaValue = on ? 1 : 0
        }, completionHandler: { if !on { v.isHidden = true } })
    }

    @objc func toggleMedia() {
        if pickerMode { closePicker() }
        else if currentTitle.isEmpty && !mediaMode { openPicker() }      // nothing loaded → choose something
        // paused or playing → the media controls (☰ in there opens the providers)
        else { setMediaMode(!mediaMode) }
    }

    // MARK: picker

    func openPicker() {
        if mediaMode { setMediaMode(false) }
        pickerMode = true
        shuffle = cfg.defaultShuffle
        showProviders()
        show(pickerRow, true); show(lyric, false)
        bumpPickerTimer()
    }

    func closePicker() {
        guard pickerMode else { return }
        showingUpNext = false
        extras.isHidden = true
        pickerMode = false
        pickerTimer?.invalidate()
        show(pickerRow, false); show(lyric, true)
    }

    func bumpPickerTimer() {
        pickerTimer?.invalidate()
        guard pickerMode else { return }
        pickerTimer = Timer.scheduledTimer(withTimeInterval: cfg.pickerAutoHide, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.queueStrip.isHolding { self.bumpPickerTimer() } else { self.closePicker() }
        }
    }

    func setPickerTransport(_ on: Bool) { pickerTransport.isHidden = !on }

    /// Pinned ‹ button for submenus (nil = top level, hidden).
    func setBack(_ action: (() -> Void)?) {
        backAction = action
        backBtn.image = symbol("chevron.left", 14); backBtn.contentTintColor = .white
        backCap.isHidden = action == nil
    }
    @objc func pickerBack() { bumpPickerTimer(); backAction?() }

    var queueSync: AnyCancellable?
    var queueDirty = false
    func updateExtras() {
        let sp = StreamPlayer.shared
        let own = bundleId == Bundle.main.bundleIdentifier && sp.active && sp.tracks.indices.contains(sp.index)
        likeBtn.isHidden = !own
        extras.isHidden = !(own && showingUpNext && pickerMode)
        guard own else { return }
        let liked = LikedCache.shared.ids.contains(sp.tracks[sp.index].id)
        likeBtn.image = liked ? coloredSymbol("heart.fill", 14, .systemPink) : symbol("heart", 14)
        let dim = NSColor.white.withAlphaComponent(0.35)
        shuffleBtn.image = coloredSymbol("shuffle", 13, sp.shuffled ? .white : dim)
        repeatBtn.image = coloredSymbol(cfg.repeatMode == "one" ? "repeat.1" : "repeat", 13, cfg.repeatMode == "off" ? dim : .white)
    }
    @objc func likeTapped() {
        bumpMediaTimer()
        let sp = StreamPlayer.shared
        guard sp.tracks.indices.contains(sp.index) else { return }
        LikedCache.shared.toggle(sp.tracks[sp.index].id)
    }
    @objc func shuffleTapped() { bumpMediaTimer(); StreamPlayer.shared.toggleShuffle(); updateExtras() }
    @objc func repeatTapped() {
        bumpMediaTimer()
        let order = ["off", "all", "one"]
        let i = order.firstIndex(of: cfg.repeatMode) ?? 0
        ConfigStore.shared.c.repeatMode = order[(i + 1) % 3]
        updateExtras()
    }

    /// Short message in the lyric line (e.g. "Volume 40%").
    func toast(_ text: String, seconds: Double = 1.2) {
        titleCardUntil = Date().addingTimeInterval(seconds)
        lyricKey = "\u{1}toast"
        lyric.alphaValue = 1
        lyric.attributedStringValue = NSAttributedString(string: text, attributes: lyricAttrs(.white))
    }

    var stripIsSpotify = false
    func syncQueueStrip() {
        guard !stripIsSpotify else { return }
        guard pickerMode, showingUpNext, bundleId == Bundle.main.bundleIdentifier, StreamPlayer.shared.active else { return }
        if queueStrip.isHolding { queueDirty = true; return }
        queueDirty = false
        let up = StreamPlayer.shared.upcoming
        if up.map(\.uid) != queueStrip.entries.compactMap(\.uid) { showUpNext() }
    }
    var showingUpNext = false

    func useQueueStrip(_ on: Bool) { queueStrip.isHidden = !on; picker.isHidden = on }

    func providerEnabled(_ p: String) -> Bool {
        switch p {
        case "subsonic": return cfg.showSubsonic
        case "spotify": return cfg.showSpotify
        case "applemusic": return cfg.showAppleMusic
        default: return false
        }
    }

    func showProviders() {
        showingUpNext = false
        extras.isHidden = true
        setPickerTransport(!currentTitle.isEmpty)
        useQueueStrip(false)
        setBack(currentTitle.isEmpty ? nil : { [weak self] in self?.closePicker(); self?.setMediaMode(true) })
        var items: [TBPicker.Item] = []
        if cfg.showSubsonic { items.append(.init(title: "Subsonic", action: { [weak self] in self?.showPlaylists("subsonic") })) }
        if cfg.showSpotify { items.append(.init(title: "Spotify", action: { [weak self] in self?.showPlaylists("spotify") })) }
        if cfg.showAppleMusic { items.append(.init(title: "Apple Music", action: { [weak self] in self?.showPlaylists("applemusic") })) }
        if !currentTitle.isEmpty {
            items.append(.init(title: "Up Next", action: { [weak self] in self?.upNextReturnsToMedia = false; self?.showUpNext() }))
        }
        let pins = cfg.pinned.filter { providerEnabled($0.provider) }
        if !pins.isEmpty { items.append(.init(title: "|", dim: true, action: nil)) }   // providers | pinned
        for p in pins {
            let hold: (() -> Void)? = p.provider == "subsonic" ? { [weak self] in self?.queuePlaylistNext(p.playlistId, p.name) } : nil
            items.append(.init(title: p.name, hold: hold) { [weak self] in self?.playPlaylist(p.provider, p.playlistId, p.name) })
        }
        picker.items = items
    }

    func showPlaylists(_ provider: String) {
        showingUpNext = false
        extras.isHidden = true
        setPickerTransport(false)
        setBack { [weak self] in self?.showProviders() }
        useQueueStrip(false)
        picker.items = [.init(title: "Loading…", dim: true, action: nil)]
        Task { @MainActor in
            let result = await loadPlaylists(provider)
            guard self.pickerMode else { return }
            switch result {
            case .failure(let e):
                self.picker.items = [.init(title: e.localizedDescription, dim: true, action: nil)]
            case .success(let list):
                var items: [TBPicker.Item] = []
                if provider == "subsonic" {
                    items.append(.init(title: self.shuffle ? "Shuffle: On" : "Shuffle: Off") { [weak self] in
                        self?.shuffle.toggle(); self?.showPlaylists(provider)
                    })
                    items.append(.init(title: "♥ Liked Songs",
                                       hold: { [weak self] in self?.queuePlaylistNext(likedSongsId, "Liked Songs") }) { [weak self] in
                        self?.playPlaylist("subsonic", likedSongsId, "Liked Songs")
                    })
                }
                for p in list {
                    let hold: (() -> Void)? = provider == "subsonic" ? { [weak self] in self?.queuePlaylistNext(p.id, p.name) } : nil
                    items.append(.init(title: p.name, hold: hold) { [weak self] in self?.playPlaylist(provider, p.id, p.name) })
                }
                self.picker.items = items
            }
        }
    }

    /// Upcoming songs for whichever player is active.
    func showUpNext() {
        showingUpNext = true
        defer { updateExtras() }
        if !pickerMode {
            pickerMode = true
            show(pickerRow, true); show(lyric, false)
        }
        setPickerTransport(false)
        bumpPickerTimer()
        setBack { [weak self] in
            guard let self else { return }
            if self.upNextReturnsToMedia { self.closePicker(); self.setMediaMode(true) } else { self.showProviders() }
        }
        let sp = StreamPlayer.shared
        stripIsSpotify = false
        if bundleId == Bundle.main.bundleIdentifier, sp.active {
            // our own queue: editable (hold + drag to reorder, drop on 🗑 to remove)
            if sp.upcoming.isEmpty {
                useQueueStrip(false)
                picker.items = [.init(title: "Nothing after this song", dim: true, action: nil)]
            } else {
                useQueueStrip(true)
                queueStrip.entries = sp.upcoming.map { .init(title: $0.title, sub: $0.artist, uid: $0.uid) }
            }
            return
        }
        useQueueStrip(false)
        picker.items = [.init(title: "Loading…", dim: true, action: nil)]
        let fill: ([(String, String)]?, String) -> Void = { [weak self] list, why in
            guard let self, self.pickerMode else { return }
            guard let list else { self.picker.items = [.init(title: why, dim: true, action: nil)]; return }
            self.picker.items = (list.isEmpty ? [.init(title: "Queue is empty", dim: true, action: nil)] :
                list.prefix(40).map { .init(title: "\($0.0) — \($0.1)", action: nil) })
        }
        if bundleId == "com.spotify.client" {
            // same strip as our own queue: tap to play, hold + drag to reorder, drop on 🗑 to remove
            let q = SpotifyQueue.shared
            q.refresh { [weak self] in
                guard let self, self.pickerMode, self.showingUpNext, !self.queueStrip.isHolding else { return }
                if let e = q.error { fill(nil, e) }
                else if q.items.isEmpty { fill([], "") }
                else {
                    self.stripIsSpotify = true
                    self.useQueueStrip(true)
                    self.queueStrip.entries = q.items.map { .init(title: $0.title, sub: $0.artist, uid: $0.id) }
                }
            }
        } else {
            fill(nil, "Up Next isn't available for this player")
        }
    }

    @objc func openMenuFromMedia() {
        setMediaMode(false)
        openPicker()
    }

    @objc func openUpNextFromMedia() {
        upNextReturnsToMedia = true
        setMediaMode(false)
        showUpNext()
    }

    /// Hold on a Subsonic playlist: add it after the current song instead of replacing the queue.
    func queuePlaylistNext(_ id: String, _ name: String) {
        closePicker()
        Task { @MainActor in
            do {
                let songs = id == likedSongsId ? try await Subsonic.starred() : try await Subsonic.playlist(id).1
                guard !songs.isEmpty else { return }
                let playing = StreamPlayer.shared.active
                queueNext(songs)
                self.toast(playing ? "Up next: \(name)" : "Playing \(name)", seconds: 2)
            } catch { self.toast("Couldn't load \(name)", seconds: 2) }
        }
    }

    func playPlaylist(_ provider: String, _ id: String, _ name: String) {
        closePicker()
        setLyric("Loading \(name)…")
        if provider == "spotify" {
            StreamPlayer.shared.stop()
            if cfg.pauseOthers && bundleId != "com.spotify.client" { run(mediaControl, ["pause"]) }
            let uri = spotifySafe(id)
            run("/usr/bin/osascript", ["-e", "tell application \"Spotify\" to play track \"\(uri)\""])
            return
        }
        if provider == "applemusic" {
            StreamPlayer.shared.stop()
            if cfg.pauseOthers && bundleId != "com.apple.Music" { run(mediaControl, ["pause"]) }
            let pid = id.filter { $0.isHexDigit }      // persistent IDs are hex; keeps the script safe
            run("/usr/bin/osascript", ["-e", "tell application \"Music\" to play (first user playlist whose persistent ID is \"\(pid)\")"])
            return
        }
        let shuffleNow = shuffle
        Task { @MainActor in
            do {
                let songs = id == likedSongsId ? try await Subsonic.starred() : try await Subsonic.playlist(id).1
                guard !songs.isEmpty else { self.setLyric("\(name) is empty"); return }
                playSongs(songs, shuffle: shuffleNow)
            } catch {
                self.setLyric("Couldn't load \(name): \(error.localizedDescription)")
            }
        }
    }

    func setMediaMode(_ on: Bool) {
        if on { closePicker() }
        mediaMode = on
        if on { closePanel() }
        show(mediaView, on); show(lyric, !on)
        updateScrubber()
        bumpMediaTimer()
    }

    /// keep the lyric clear of whatever occupies the right side
    func updateLyricLimit() {
        let idx = panelMode != .none ? 1 : 0
        for (i, c) in lyricLimits.enumerated() { c.isActive = i == idx }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.2; c.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
        }
    }

    func bumpMediaTimer() {
        mediaTimer?.invalidate()
        guard mediaMode else { return }
        mediaTimer = Timer.scheduledTimer(withTimeInterval: cfg.mediaAutoHide, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.keepControlsWhilePaused && !self.isPlaying { self.bumpMediaTimer(); return }   // stay up while paused
            self.setMediaMode(false)
        }
    }

    @objc func playPause() {
        bumpMediaTimer()
        if let l = Optional(position) { localSeek = (l, Date().timeIntervalSince1970) }
        if currentTitle.isEmpty {
            if !transport(.toggle) { openPicker() }      // default app = "ask"
            return
        }
        setPlaying(!isPlaying)  // optimistic; state.json confirms
        transport(.toggle)
    }
    @objc func prev() { bumpMediaTimer(); transport(.previous) }
    @objc func next() { bumpMediaTimer(); transport(.next) }

    func scrubChanged(_ v: Double) {
        bumpMediaTimer()
        scrubbing = true
        elapsedLbl.stringValue = fmt(v)
        remainLbl.stringValue = "-" + fmt(duration - v)
    }

    func scrubEnded(_ v: Double) {
        transport(.seek(v))
        localSeek = (v, Date().timeIntervalSince1970)
        scrubbing = false
        bumpMediaTimer()
    }

    @objc func openPlayer() {
        if !bundleId.isEmpty, let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: u, configuration: .init())
        }
    }

    // MARK: right side

    @objc func openBrightness() { openPanel(.brightness) }
    @objc func openVolume() { openPanel(.volume) }

    func openPanel(_ p: Panel) {
        if mediaMode { setMediaMode(false) }
        panelMode = p
        refreshPanel()
        show(strip, false); show(panel, true)
        updateLyricLimit()
        bumpPanelTimer()
    }

    func refreshPanel() {
        switch panelMode {
        case .brightness:
            panelIcon.image = symbol("sun.min.fill", 14)
            panelSlider.floatValue = Sys.brightness
        case .volume:
            panelIcon.image = symbol(Sys.volumeSymbol, 14)
            panelSlider.floatValue = Sys.muted ? 0 : Sys.volume
        case .none: break
        }
        volBtn.image = symbol(Sys.volumeSymbol, 14)
    }

    @objc func closePanel() {
        guard panelMode != .none else { return }
        panelMode = .none
        panelTimer?.invalidate()
        show(panel, false)
        if cfg.showBrightness || cfg.showVolume || cfg.showApps { show(strip, true) }
        updateLyricLimit()
        volBtn.image = symbol(Sys.volumeSymbol, 14)
    }

    func bumpPanelTimer() {
        panelTimer?.invalidate()
        panelTimer = Timer.scheduledTimer(withTimeInterval: cfg.panelAutoHide, repeats: false) { [weak self] _ in self?.closePanel() }
    }

    @objc func panelSlid() {
        bumpPanelTimer()
        switch panelMode {
        case .brightness: Sys.brightness = panelSlider.floatValue
        case .volume:
            Sys.volume = panelSlider.floatValue
            panelIcon.image = symbol(Sys.volumeSymbol, 14)
        case .none: break
        }
    }

    @objc func panelIconTapped() {
        bumpPanelTimer()
        switch panelMode {
        case .volume: Sys.muted.toggle(); refreshPanel()
        case .brightness: Sys.brightness = 0.05; refreshPanel()
        case .none: break
        }
    }

    @objc func openApps() { LibraryWindow.shared.toggle() }

    /// "pause" = play/pause (shows the controls instead when nothing is loaded), "controls" = media controls, "none".
    func lyricGesture(_ action: String) {
        switch action {
        case "pause": currentTitle.isEmpty ? toggleMedia() : playPause()
        case "controls": toggleMedia()
        default: break
        }
    }

}

// MARK: - App

final class App: NSObject, NSApplicationDelegate, NSTouchBarDelegate {
    let mainId = NSTouchBarItem.Identifier("com.crispy.lyricsbar.main")
    let trayId = NSTouchBarItem.Identifier("com.crispy.lyricsbar.tray")
    let bar = NSTouchBar()
    let view = BarView(frame: NSRect(origin: .zero, size: barSize))
    var wallpaperKey = ""
    var lastState = Data()
    var lastArtMtime: Date?
    var lastTitle = ""
    var artBG = false              // background is currently showing album art
    var lastArtist = ""
    var sysTitle = ""
    var ownFallback = false
    var fallbackArt: NSImage?

    /// macOS only lists an app under Now Playing once it has made sound, so a queue restored (paused)
    /// after a restart is invisible to the daemon. Until then, drive the bar from our own player.
    func useOwnPlayerFallback() {
        let sp = StreamPlayer.shared
        let on = sysTitle.isEmpty && sp.active && sp.tracks.indices.contains(sp.index)
        if !on {
            if ownFallback { ownFallback = false; fallbackArt = nil; lastState = Data() }   // re-read the real state
            return
        }
        ownFallback = true
        let t = sp.tracks[sp.index]
        view.bundleId = Bundle.main.bundleIdentifier ?? ""
        if view.isPlaying != sp.isPlaying { view.setPlaying(sp.isPlaying) }
        view.duration = t.duration
        let pos = sp.player.currentTime().seconds
        view.elapsedAt = (pos.isFinite ? pos : 0, Date().timeIntervalSince1970, sp.isPlaying ? 1 : 0)
        if t.title != lastTitle {
            lastTitle = t.title; lastArtist = t.artist; titleChangedAt = Date(); outroFor = ""
            view.showTitleCard(t.title, t.artist)
            view.updateExtras()
        }
        view.currentTitle = t.title
        if let a = sp.artwork, a !== fallbackArt {
            fallbackArt = a
            view.setArtwork(a); view.accent = accentColor(of: a); view.applyVisualizer()
        }
    }
    var titleChangedAt = Date()
    var outroFor = ""              // song we've already shown the end-of-song card for
    var stoppedSince: Date?
    var signalSources: [DispatchSourceSignal] = []
    var statusItem: NSStatusItem?

    /// Exercises the built-in player silently and restores the queue position afterwards. Log → debug.out
    func mutedSelfTest() {
        let sp = StreamPlayer.shared
        var log = ""      // talks to LyricsBar's player directly, never to other apps
        func note(_ s: String) {
            let i = sp.tracks.indices.contains(sp.index) ? sp.tracks[sp.index].title : "-"
            log += "\(s): active=\(sp.active) i=\(sp.index) '\(i)' playing=\(sp.isPlaying) pos=\(String(format: "%.1f", sp.player.currentTime().seconds)) item=\(sp.player.currentItem?.status.rawValue ?? -1) sys='\(systemState().title)'\n"
            try? log.write(toFile: home + "/debug.out", atomically: true, encoding: .utf8)
        }
        guard sp.active else { note("no queue"); return }
        let origIndex = sp.index, origPos = sp.player.currentTime().seconds
        sp.testMuted = true
        let steps: [(Double, String, () -> Void)] = [
            (0, "play", { sp.play() }),
            (5, "after play", {}),
            (0, "next", { sp.next() }),
            (5, "after next", {}),
            (0, "seek 30", { sp.seek(30) }),
            (2, "after seek", {}),
            (0, "seek to end-5 (crossfade)", {
                guard sp.tracks.indices.contains(sp.index) else { return }
                sp.seek(max(0, sp.tracks[sp.index].duration - 5))
            }),
            (7, "after crossfade", {}),
            (0, "previous x2", { sp.previous(); sp.previous() }),
            (4, "after previous", {}),
            (0, "pause", { sp.pause() }),
            (2, "after pause", {}),
            (0, "restore", { sp.jump(to: origIndex); sp.pause(); sp.seek(origPos.isFinite ? origPos : 0) }),
            (2, "restored", { sp.testMuted = false }),
        ]
        var t = 0.0
        for (delay, name, act) in steps {
            t += delay
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { act(); note(name) }
        }
    }

    func applicationWillTerminate(_ n: Notification) { StreamPlayer.shared.save() }

    /// Standard app + Edit menus. Without an Edit menu, ⌘V etc. never reach text fields.
    func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit LyricsBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        // Subsonic URLs carry the auth token, so never let URLSession write responses (and their URLs) to disk.
        // This must happen before ANY network request.
        URLCache.shared = URLCache(memoryCapacity: 48 << 20, diskCapacity: 0)
        URLCache.shared.removeAllCachedResponses()
        if let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.crispy.lyricsbar") {
            try? FileManager.default.removeItem(at: dir)
        }
        // our data folder holds listening history: keep it (and new files in it) private to this user
        umask(0o077)
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home)
        Creds.migrateFiles()      // old plaintext credential files → Keychain
        ScrobbleQueue.startRetrying()
        installMainMenu()
        LikedCache.shared.reload()
        StreamPlayer.shared.restore()
        bar.delegate = self
        bar.defaultItemIdentifiers = [mainId]

        let tray = NSCustomTouchBarItem(identifier: trayId)
        tray.view = NSButton(image: symbol("music.note", 14)!, target: self, action: #selector(present))
        addSystemTrayItem(tray)
        dfrSetControlStripPresence(trayId.rawValue, true)
        dfrShowCloseBox(false)

        present()
        refreshWallpaper()
        updateStatusItem()
        NotificationCenter.default.addObserver(forName: .lyricsBarConfigChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.view.applyConfig()
            self.updateStatusItem()
            self.refreshWallpaperNow()
        }
        // test hooks: kill -USR1 = toggle media view, kill -USR2 = volume panel
        for (sig, act) in [(SIGUSR1, { [weak self] in self?.view.toggleMedia() }),
                           (SIGUSR2, { [weak self] in self?.view.openVolume() }),
                           // kill -HUP with ~/.touchbar-lyrics/debug.cmd = "pick N" taps picker item N
                           // launchctl kickstart -k / logout: save the queue so it can be resumed
                           (SIGTERM, { StreamPlayer.shared.save(); exit(0) }),
                           (SIGHUP, { [weak self] in
                               guard let self, let c = try? String(contentsOfFile: home + "/debug.cmd", encoding: .utf8) else { return }
                               if c.hasPrefix("viz") {
                                   let t = AudioTap.shared
                                   let line = "running=\(t.running) err=\(t.debugError) frames=\(t.framesSeen) levels=\(t.levels.map { String(format: "%.2f", $0) }.joined(separator: " "))\n"
                                   try? line.write(toFile: home + "/debug.out", atomically: true, encoding: .utf8); return
                               }
                               if c.hasPrefix("qpreview") {   // silent preview of the Up Next strip with sample songs
                                   let v = self.view
                                   v.pickerMode = true; v.show(v.pickerRow, true); v.show(v.lyric, false)
                                   v.setPickerTransport(false); v.setBack { v.closePicker() }; v.useQueueStrip(true)
                                   v.queueStrip.entries = [("Garbage", "twenty one pilots"), ("Mayonaka no Door~stay with me", "Miki Matsubara"),
                                       ("are we there yet?", "Jacal"), ("Bonus Fruit I", "Webinar™"), ("A Much Longer Song Title Here", "Some Artist"),
                                       ("Plastic Love", "Mariya Takeuchi"), ("Short", "X")].map { .init(title: $0.0, sub: $0.1, uid: nil) }
                                   v.bumpPickerTimer()
                               }
                               if c.hasPrefix("text ") {
                                   self.view.showTitleCard(String(c.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines), "")
                                   DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                       let v = self.view
                                       let info = "bar=\(v.convert(v.bounds, to: nil)) win=\(v.window?.frame ?? .zero) lyric=\(v.convert(v.lyric.bounds, from: v.lyric)) align=\(v.lyric.alignment.rawValue)"
                                       try? info.write(toFile: home + "/debug.out", atomically: true, encoding: .utf8)
                                   }
                               }
                               if c.hasPrefix("menu") { self.view.openPicker() }
                               if c.hasPrefix("mutedtest") { self.mutedSelfTest() }
                               if c.hasPrefix("qstate") {
                                   let sp = StreamPlayer.shared
                                   try? "active=\(sp.active) n=\(sp.tracks.count) i=\(sp.index) title=\(sp.tracks.indices.contains(sp.index) ? sp.tracks[sp.index].title : "-") status=\(sp.player.currentItem?.status.rawValue ?? -1) tint=\(String(describing: self.view.likeBtn.contentTintColor)) liked=\(LikedCache.shared.ids.count)".write(toFile: home + "/debug.out", atomically: true, encoding: .utf8)
                               }
                               if c.hasPrefix("toast ") { self.view.toast(String(c.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines), seconds: 3) }
                               if c.hasPrefix("media") { self.view.setMediaMode(true) }
                               if c.trimmingCharacters(in: .whitespacesAndNewlines) == "apps" { self.view.openApps() }
                               if c.trimmingCharacters(in: .whitespacesAndNewlines) == "arthold" { self.view.artButton.onHold?() }
                               if c.hasPrefix("discordtest ") {          // test against a fake Discord socket; "discordtest off" undoes it
                                   let arg = String(c.dropFirst(12)).trimmingCharacters(in: .whitespacesAndNewlines)
                                   if arg == "off" {
                                       DiscordPresence.shared.socketOverride = nil
                                       ConfigStore.shared.c.discordEnabled = false; ConfigStore.shared.c.discordAppId = ""
                                       ConfigStore.shared.c.discordWhenPaused = "hide"
                                   } else {
                                       DiscordPresence.shared.socketOverride = [arg]
                                       ConfigStore.shared.c.discordEnabled = true; ConfigStore.shared.c.discordAppId = "123456789012345678"
                                       ConfigStore.shared.c.discordWhenPaused = "show"
                                   }
                               }
                               if c.hasPrefix("spq") {                    // Spotify queue: spq [skip N | remove N | move A B]
                                   let q = SpotifyQueue.shared
                                   let w = c.split(separator: " ").map(String.init)
                                   let dump: (String?) -> Void = { err in
                                       q.refresh {
                                           let lines = q.items.enumerated().map { "\($0.offset): \($0.element.title) — \($0.element.artist)" }
                                           try? (["action error: \(err ?? "none")", "queue error: \(q.error ?? "none")"] + lines)
                                               .joined(separator: "\n").write(toFile: home + "/debug.out", atomically: true, encoding: .utf8)
                                       }
                                   }
                                   let n = w.count > 1 ? Int(w[2 < w.count ? 2 : 1].trimmingCharacters(in: .whitespacesAndNewlines)) : nil
                                   q.refresh {
                                       let items = q.items
                                       switch w.count > 1 ? w[1] : "" {
                                       case "skip": if let n, items.indices.contains(n) { q.jump(id: items[n].id) { e in DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dump(e) } } }
                                       case "remove": if let n, items.indices.contains(n) { q.remove(id: items[n].id) { e in DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dump(e) } } }
                                       case "move":
                                           let ab = w.dropFirst(2).compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                                           if ab.count == 2, items.indices.contains(ab[0]), items.indices.contains(ab[1]) {
                                               var ids = items.map(\.id); ids.insert(ids.remove(at: ab[0]), at: ab[1])
                                               q.reorder(ids) { e in DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dump(e) } }
                                           }
                                       default: dump(nil)
                                       }
                                   }
                               }
                               if c.hasPrefix("discordpreview") {
                                   let a = DiscordPresence.shared.activity(for: DiscordPresence.shared.snapshot(), cfg)
                                   let d = a.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }
                                   try? ((d.map { String(decoding: $0, as: UTF8.self) } ?? "nil") + "\nstatus: " + DiscordPresence.shared.status)
                                       .write(toFile: home + "/debug.out", atomically: true, encoding: .utf8)
                               }
                               if c.hasPrefix("vizsrc") { try? AudioTap.shared.debugSource.write(toFile: home + "/debug.out", atomically: true, encoding: .utf8) }
                               if c.hasPrefix("library "), let sec = LibSection(rawValue: c.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines)) {
                                   LibraryWindow.shared.show(sec)
                               }
                               if c.hasPrefix("settings "), let sec = SettingsSection(rawValue: c.dropFirst(9).trimmingCharacters(in: .whitespacesAndNewlines)) {
                                   SettingsWindow.shared.show(sec); return
                               }
                               guard c.hasPrefix("pick "), let n = Int(c.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)),
                                     self.view.picker.items.indices.contains(n) else { return }
                               self.view.picker.items[n].action?()
                           })] as [(Int32, () -> Void)] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler(handler: act); src.resume(); signalSources.append(src)
        }
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshWallpaper() }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(refreshWallpaperNow), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(present), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        nc.addObserver(self, selector: #selector(present), name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc func present() { presentSystemModal(bar, trayId: trayId.rawValue) }

    func updateStatusItem() {
        if !cfg.showMenuBarIcon { if let s = statusItem { NSStatusBar.system.removeStatusItem(s) }; statusItem = nil; return }
        guard statusItem == nil else { return }
        let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        s.button?.image = symbol("music.note", 14, .medium)
        s.button?.image?.isTemplate = true
        let m = NSMenu()
        m.addItem(withTitle: "Library…", action: #selector(openLibrary), keyEquivalent: "l").target = self
        // only offer the switch when the other version is actually installed
        let other = NSHomeDirectory() + "/Applications/" + (isBeta ? "LyricsBar Stable.app" : "LyricsBar Beta.app")
        if FileManager.default.fileExists(atPath: other) {
            m.addItem(withTitle: isBeta ? "Switch to Stable Version" : "Switch to Beta Version",
                      action: #selector(switchVersion), keyEquivalent: "").target = self
        }
        m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        m.addItem(withTitle: "Pinned Playlists…", action: #selector(openPins), keyEquivalent: "").target = self
        m.addItem(withTitle: "Manage Subsonic Playlists…", action: #selector(openSubsonic), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Restart LyricsBar", action: #selector(restart), keyEquivalent: "").target = self
        s.menu = m
        statusItem = s
    }
    /// ~/Applications/LyricsBar.app is a symlink to "LyricsBar Stable.app" or "LyricsBar Beta.app".
    var isBeta: Bool { Bundle.main.bundleURL.resolvingSymlinksInPath().lastPathComponent.contains("Beta") }
    @objc func switchVersion() {
        let apps = NSHomeDirectory() + "/Applications/"
        let target = isBeta ? "LyricsBar Stable.app" : "LyricsBar Beta.app"
        guard FileManager.default.fileExists(atPath: apps + target) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ln")
        p.arguments = ["-sfn", target, apps + "LyricsBar.app"]
        try? p.run(); p.waitUntilExit()
        StreamPlayer.shared.save()
        exit(0)      // launchd (KeepAlive) relaunches through the symlink → the other version
    }

    @objc func openLibrary() { LibraryWindow.shared.show() }
    @objc func openSettings() { SettingsWindow.shared.show(.general) }
    @objc func openPins() { SettingsWindow.shared.show(.pinned) }
    @objc func openSubsonic() { SettingsWindow.shared.show(.subsonic) }
    @objc func restart() { exit(0) }   // launchd's KeepAlive starts it again

    func touchBar(_ tb: NSTouchBar, makeItemForIdentifier id: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard id == mainId else { return nil }
        let item = NSCustomTouchBarItem(identifier: id)
        item.view = view
        return item
    }

    @objc func refreshWallpaperNow() { wallpaperKey = ""; refreshWallpaper() }

    func refreshWallpaper() {
        if cfg.backgroundStyle == "solid" {
            guard wallpaperKey != "solid" + cfg.solidColor else { return }
            wallpaperKey = "solid" + cfg.solidColor
            let img = NSImage(size: barSize, flipped: false) { r in
                (NSColor(hex: cfg.solidColor) ?? .black).setFill(); r.fill(); return true
            }
            view.bg.image = img
            return
        }
        let artURL = URL(fileURLWithPath: home + "/artwork.jpg")
        let useArt = cfg.backgroundStyle == "album" && artBG
        if useArt && !FileManager.default.fileExists(atPath: artURL.path) { return }   // next cover not ready: keep current
        if !useArt && wallpaperIsRotating() {
            // macOS doesn't say which picture a rotating folder is showing: plain black instead of a stale one
            guard wallpaperKey != "rotating" else { return }
            wallpaperKey = "rotating"
            let t = CATransition(); t.type = .fade; t.duration = 0.6
            view.bg.layer?.add(t, forKey: "bg")
            view.bg.image = NSImage(size: barSize, flipped: false) { r in NSColor.black.setFill(); r.fill(); return true }
            return
        }
        guard let url = useArt ? artURL : currentWallpaperURL() else { return }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(mtime)|\(cfg.blurAmount)|\(cfg.targetBrightness)|\(cfg.saturation)"
        guard key != wallpaperKey else { return }
        wallpaperKey = key
        DispatchQueue.global(qos: .utility).async {
            let img = blurredStrip(from: url)
            DispatchQueue.main.async {
                let t = CATransition(); t.type = .fade; t.duration = 0.6
                self.view.bg.layer?.add(t, forKey: "bg")
                self.view.bg.image = img
            }
        }
    }

    func tick() {
        DiscordPresence.shared.tick()
        if let d = FileManager.default.contents(atPath: home + "/state.json"), d != lastState,
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            lastState = d
            view.setPlaying(j["playing"] as? Bool ?? false)
            view.bundleId = j["bundle"] as? String ?? ""
            view.duration = j["duration"] as? Double ?? 0
            view.elapsedAt = (j["elapsed"] as? Double ?? 0, j["anchor"] as? Double ?? 0, j["rate"] as? Double ?? 0)
            let title = j["title"] as? String ?? ""
            sysTitle = title
            if title != lastTitle {
                lastTitle = title; view.localSeek = nil; titleChangedAt = Date()
                DispatchQueue.main.async { self.view.updateExtras() }
                lastArtist = j["artist"] as? String ?? ""
                view.showTitleCard(title, lastArtist, slideIn: view.outroActive)
                outroFor = ""
            }
            view.currentTitle = title
            let sp = StreamPlayer.shared
            if (j["playing"] as? Bool ?? false), (j["bundle"] as? String ?? "") != Bundle.main.bundleIdentifier,
               sp.isPlaying, Date().timeIntervalSince(sp.startedAt) > 3 {
                sp.pause()   // another player took over
            }
        }
        useOwnPlayerFallback()
        if let s = try? String(contentsOfFile: home + "/current.txt", encoding: .utf8) {
            view.setLyric(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        view.updateScrubber()
        let artPath = home + "/artwork.jpg"
        let m = (try? FileManager.default.attributesOfItem(atPath: artPath)[.modificationDate]) as? Date
        if m != lastArtMtime {
            lastArtMtime = m
            if m != nil, let img = NSImage(contentsOfFile: artPath) {
                view.setArtwork(img)
                view.accent = accentColor(of: img)
                view.applyVisualizer()
                if cfg.backgroundStyle == "album" && view.isPlaying { artBG = true; refreshWallpaperNow() }
            } else if lastTitle.isEmpty {
                // nothing loaded any more → back to the ♪ placeholder
                view.setArtwork(nil); view.accent = nil; view.applyVisualizer()
            }
            // otherwise a new song is loading: keep the previous cover until its art arrives
        }
        // …but not forever: a song that never gets art (or playback ending) drops the old cover
        if !ownFallback && m == nil && view.hasArtwork && (lastTitle.isEmpty || Date().timeIntervalSince(titleChangedAt) > 4) {
            view.setArtwork(nil); view.accent = nil; view.applyVisualizer()
            if artBG { artBG = false; refreshWallpaperNow() }
        }
        updateBackgroundMode()
        updatePausedScreen()
        BarAwake.shared.tick(playing: view.isPlaying)
        view.updateProgress()
        driveVisualizer()
        checkOutro()
    }

    // MARK: while paused

    var pausedSince: Date?
    var controlsOpenedForPause = false
    func updatePausedScreen() {
        let mode = cfg.pausedShows
        let paused = !view.isPlaying && !lastTitle.isEmpty
        if !paused { pausedSince = nil } else if pausedSince == nil { pausedSince = Date() }
        let since = pausedSince.map { Date().timeIntervalSince($0) } ?? 0
        let active = paused && mode != "lyrics" && since >= cfg.pausedDelay
        view.keepControlsWhilePaused = active && mode == "controls"
        guard active else {
            view.clearPaused()
            if controlsOpenedForPause { controlsOpenedForPause = false; if view.mediaMode { view.setMediaMode(false) } }
            return
        }
        if mode == "controls" {
            view.clearPaused()
            if !view.mediaMode && !view.pickerMode && !controlsOpenedForPause { controlsOpenedForPause = true; view.setMediaMode(true) }
            return
        }
        let dim = NSColor.white.withAlphaComponent(0.6)
        let a = NSMutableAttributedString()
        var key = "\u{1}paused:" + mode
        switch mode {
        case "title":
            a.append(NSAttributedString(string: lastTitle, attributes: view.lyricAttrs(.white)))
            if !lastArtist.isEmpty { a.append(NSAttributedString(string: "   " + lastArtist, attributes: view.lyricAttrs(dim, .regular))) }
            key += lastTitle + lastArtist
        case "phrase":
            let t = cfg.pausedPhrase.replacingOccurrences(of: "{title}", with: lastTitle)
                .replacingOccurrences(of: "{artist}", with: lastArtist)
            a.append(NSAttributedString(string: t, attributes: view.lyricAttrs(.white)))
            key += t
        default:   // quotes
            let qs = pausedQuotes()
            guard !qs.isEmpty else { view.clearPaused(); return }
            let i = Int((since - cfg.pausedDelay) / max(60, cfg.pausedQuoteSeconds)) % qs.count
            let (text, by) = qs[(i + quoteOffset) % qs.count]
            a.append(NSAttributedString(string: text, attributes: view.lyricAttrs(.white, .regular)))
            if !by.isEmpty { a.append(NSAttributedString(string: "   — " + by, attributes: view.lyricAttrs(dim, .regular))) }
            key += "\(i)"
        }
        view.showPaused(a, key: key)
    }

    lazy var quoteOffset = Int.random(in: 0..<1000)   // start somewhere different each launch
    func pausedQuotes() -> [(String, String)] {
        var out: [(String, String)] = []
        for line in cfg.pausedQuotes.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard !s.isEmpty else { continue }
            // "text — author" (or " - author") splits the author off
            if let r = s.range(of: " — ", options: .backwards) ?? s.range(of: " - ", options: .backwards) {
                out.append((String(s[..<r.lowerBound]), String(s[r.upperBound...])))
            } else { out.append((s, "")) }
        }
        if cfg.pausedBuiltinQuotes || out.isEmpty { out += BuiltinQuotes.all }
        return out
    }

    func checkOutro() {
        let window = cfg.outroSeconds
        guard window > 0, view.duration > 20, !lastTitle.isEmpty else { return }
        let remaining = view.duration - view.position
        if view.isPlaying, remaining <= window, remaining > 0.3, outroFor != lastTitle {
            outroFor = lastTitle
            let title = lastTitle, artist = lastArtist
            fetchNext { [weak self] next in
                guard let self, self.lastTitle == title, self.outroFor == title else { return }
                self.view.showOutro(title, artist, next: next)
            }
        } else if view.outroActive && remaining > window + 2 {
            view.cancelOutro(); outroFor = ""       // seeked back
        }
    }

    /// Title/artist of the song after this one, for whichever player is active.
    func fetchNext(_ done: @escaping ((String, String)?) -> Void) {
        let sp = StreamPlayer.shared
        if view.bundleId == Bundle.main.bundleIdentifier, sp.active {
            let i = sp.index + 1
            done(sp.tracks.indices.contains(i) ? (sp.tracks[i].title, sp.tracks[i].artist) : nil)
        } else if view.bundleId == "com.spotify.client" {
            libraryJSON(["queue", "spotify"]) { obj, _ in
                let f = (obj as? [[String: Any]])?.first
                done(f.map { ($0["title"] as? String ?? "", $0["artist"] as? String ?? "") })
            }
        } else { done(nil) }
    }

    /// Album-art background while playing; wallpaper again `artLinger` seconds after playback stops (-1 = keep it).
    func updateBackgroundMode() {
        if view.isPlaying { stoppedSince = nil } else if stoppedSince == nil { stoppedSince = Date() }
        // the cover (button and background) stays up for `artLinger` after pausing, then fades
        let lingering = view.isPlaying || cfg.artLinger < 0 || Date().timeIntervalSince(stoppedSince ?? Date()) <= cfg.artLinger
        view.setArtDimmed(!lingering)
        guard cfg.backgroundStyle == "album" else { if artBG { artBG = false }; return }
        if view.isPlaying {
            if !artBG && FileManager.default.fileExists(atPath: home + "/artwork.jpg") { artBG = true; refreshWallpaperNow() }
        } else if artBG && !lingering {
            artBG = false; refreshWallpaperNow()
        }
    }

    var vizIdleSince: Date?
    var vizTimer: Timer?

    /// Run the audio tap only while something plays and a visualizer style is on.
    func driveVisualizer() {
        let tap = AudioTap.shared
        tap.sensitivity = Float(cfg.visualizerSensitivity)
        let want = cfg.visualizerStyle != "off" && view.isPlaying
        // listen at the source: LyricsBar's own stream, or just the app that's playing
        let own = ownPlayerInCharge()
        let src: AudioTap.Source = own ? .own : .app(systemState().bundle)
        if own { tap.setOwnItem(StreamPlayer.shared.player.currentItem) }
        if want {
            vizIdleSince = nil
            if tap.running && tap.source != src { tap.start(src) }     // switch source without restarting the timer
            if !tap.running {
                tap.start(src)
                vizTimer?.invalidate()
                let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    guard let self else { return }
                    let lv = AudioTap.shared.levels
                    if !self.view.vizBG.isHidden { self.view.vizBG.update(lv) }
                    if !self.view.vizCompact.isHidden { self.view.vizCompact.update(lv) }
                }
                RunLoop.main.add(t, forMode: .common)
                vizTimer = t
            }
        } else if tap.running {
            if vizIdleSince == nil { vizIdleSince = Date() }
            if Date().timeIntervalSince(vizIdleSince!) > 4 || cfg.visualizerStyle == "off" {
                tap.stop(); vizTimer?.invalidate(); vizTimer = nil
                view.vizBG.update([0]); view.vizCompact.update([0])
            }
        }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()


// MARK: - Quotes for the paused screen

enum BuiltinQuotes {   // a type, not a top-level let: main.swift globals after the run loop never initialise
    static let all: [(String, String)] = [
    ("Where words fail, music speaks.", "Hans Christian Andersen"),
    ("Without music, life would be a mistake.", "Friedrich Nietzsche"),
    ("Music expresses that which cannot be said and on which it is impossible to be silent.", "Victor Hugo"),
    ("If music be the food of love, play on.", "Shakespeare"),
    ("After silence, that which comes nearest to expressing the inexpressible is music.", "Aldous Huxley"),
    ("Music is the universal language of mankind.", "Henry Wadsworth Longfellow"),
    ("One good thing about music, when it hits you, you feel no pain.", "Bob Marley"),
    ("Music can change the world because it can change people.", "Bono"),
    ("I think music in itself is healing.", "Billy Joel"),
    ]
}

// MARK: - Keeping the Touch Bar awake

/// macOS dims the Touch Bar after about a minute without keyboard/trackpad input. To keep it lit we declare
/// user activity (like `caffeinate -u`), which also keeps the screen on. Our own declarations reset the idle
/// counter too, so real activity is told apart by the counter dropping below the time since our last one.
final class BarAwake {
    static let shared = BarAwake()
    private var assertion: IOPMAssertionID = 0
    private var lastDeclare: Date?
    private var lastReal = Date()
    private var lastCheck = Date.distantPast

    private func hidIdle() -> Double? {
        let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard s != 0 else { return nil }
        defer { IOObjectRelease(s) }
        guard let v = IORegistryEntryCreateCFProperty(s, "HIDIdleTime" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber else { return nil }
        return v.doubleValue / 1e9
    }

    func tick(playing: Bool) {
        let now = Date()
        guard now.timeIntervalSince(lastCheck) >= 5 else { return }
        lastCheck = now
        if let idle = hidIdle() {
            let sinceOurs = lastDeclare.map { now.timeIntervalSince($0) } ?? .infinity
            if idle < sinceOurs - 1.5 { lastReal = now.addingTimeInterval(-idle) }   // a real key/trackpad event
        }
        let mins = cfg.barSleepMinutes                 // 0 = like macOS, -1 = never, else minutes after last use
        let want = mins != 0 && (playing || !cfg.barAwakeOnlyWhilePlaying)
            && (mins < 0 || now.timeIntervalSince(lastReal) < mins * 60)
        if want {
            if lastDeclare == nil || now.timeIntervalSince(lastDeclare!) >= 20 {
                IOPMAssertionDeclareUserActivity("LyricsBar keeps the Touch Bar awake" as CFString, kIOPMUserActiveLocal, &assertion)
                lastDeclare = now
            }
        } else if assertion != 0 {
            IOPMAssertionRelease(assertion); assertion = 0
        }
    }
}
