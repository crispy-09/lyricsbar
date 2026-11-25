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

let home = (NSHomeDirectory() as NSString).appendingPathComponent(".touchbar-lyrics")
/// Apple Silicon Homebrew, Intel Homebrew, or anywhere on PATH (same order as lyricsd.py).
let mediaControl: String = {
    for p in ["/opt/homebrew/bin/media-control", "/usr/local/bin/media-control"] where FileManager.default.isExecutableFile(atPath: p) { return p }
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let p = "\(dir)/media-control"
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return "/opt/homebrew/bin/media-control"
}()

extension Notification.Name {
    /// A short message for the Touch Bar from code that has no view (e.g. the stream player).
    static let lyricsBarToast = Notification.Name("lyricsBarToast")
}
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

/// Takes LyricsBar's bar off the Touch Bar, so macOS shows the app's own bar and the Control Strip again.
func dismissSystemModal(_ bar: NSTouchBar) {
    let cls: AnyClass = NSTouchBar.self
    // minimise (not dismiss): the bar folds into its ♪ in the Control Strip, which brings it back
    for name in ["minimizeSystemModalTouchBar:", "minimizeSystemModalFunctionBar:",
                 "dismissSystemModalTouchBar:", "dismissSystemModalFunctionBar:"] {
        let sel = NSSelectorFromString(name)
        if let m = class_getClassMethod(cls, sel) {
            typealias F = @convention(c) (AnyObject, Selector, NSTouchBar) -> Void
            unsafeBitCast(method_getImplementation(m), to: F.self)(cls, sel, bar)
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

/// The ♪ that sits in the Control Strip while the regular Touch Bar shows: a square grey cell like
/// the system's own buttons (a plain NSButton gets a rounded bezel there).
final class ControlStripButton: NSButton {
    convenience init(_ img: NSImage?, _ target: AnyObject, _ action: Selector) {
        self.init(frame: .zero)
        image = img
        imagePosition = .imageOnly
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 69 / 255, green: 69 / 255, blue: 71 / 255, alpha: 1).cgColor
        layer?.cornerRadius = 0
        self.target = target; self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 54).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }
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

enum Panel { case none, brightness, volume, keyboard }

/// The keyboard backlight, through CoreBrightness (private, same as Control Center uses).
enum KeyboardLight {
    private static let client: NSObject? = {
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW)
        return (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
    }()
    private static let id: UInt64? = {
        guard let c = client, c.responds(to: NSSelectorFromString("copyKeyboardBacklightIDs")),
              let a = c.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber]
        else { return nil }
        return a.first?.uint64Value
    }()
    static var available: Bool { id != nil }
    static var level: Float {
        get {
            guard let c = client, let k = id, let m = c.method(for: NSSelectorFromString("brightnessForKeyboard:")) else { return 0 }
            typealias F = @convention(c) (AnyObject, Selector, UInt64) -> Float
            return unsafeBitCast(m, to: F.self)(c, NSSelectorFromString("brightnessForKeyboard:"), k)
        }
        set {
            guard let c = client, let k = id, let m = c.method(for: NSSelectorFromString("setBrightness:forKeyboard:")) else { return }
            typealias F = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
            _ = unsafeBitCast(m, to: F.self)(c, NSSelectorFromString("setBrightness:forKeyboard:"), max(0, min(1, newValue)), k)
        }
    }
}

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
    var isPlaying: Bool { cur.timeControlStatus != .paused && !pausing }

    override init() {
        cur = pa
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(ended(_:)),
                                               name: AVPlayerItem.didPlayToEndTimeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(failed(_:)),
                                               name: AVPlayerItem.failedToPlayToEndTimeNotification, object: nil)
        for p in [pa, pb] {
            obs.append(p.observe(\.timeControlStatus) { [weak self] p, _ in
                DispatchQueue.main.async { if p === self?.cur { self?.objectWillChange.send(); self?.updateInfo() } }
            })
            timeObs.append(p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) {
                [weak self, weak p] _ in if p === self?.cur { self?.updateInfo(); self?.save() }
            })
            timeObs.append(p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 10), queue: .main) {
                [weak self, weak p] _ in if p === self?.cur { self?.writeClock() }
            })
        }
        let m = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkCrossfade(); self?.trackListening(); self?.ensurePreload(); self?.shareRoute()
        }
        RunLoop.main.add(m, forMode: .common)
        monitor = m
        let rc = MPRemoteCommandCenter.shared()
        rc.playCommand.addTarget { [weak self] _ in self?.play(); return .success }
        rc.pauseCommand.addTarget { [weak self] _ in self?.pause(); return .success }
        rc.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        rc.nextTrackCommand.addTarget { [weak self] _ in self?.skipNext(); return .success }
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
        shuffled = false; unshuffled = []          // a new queue starts in its own order
        startedAt = Date()
        setCommands(true)
        playCurrent()
    }

    func playCurrent() {
        cancelFade()
        guard tracks.indices.contains(index) else { stop(); return }
        if adoptPreload(for: index) {
            // already loaded in the idle player: switch to it and let go of the old one
            let old = cur
            cur = other
            old.pause(); old.replaceCurrentItem(with: nil); old.volume = 1
        } else {
            cur.replaceCurrentItem(with: makeItem(tracks[index].stream))
        }
        cur.volume = 1
        wantPlaying = true
        cur.play()
        trackChanged()
    }

    // MARK: preloading the next song
    // While a song plays, the one after it is loaded (paused, silent) into the idle player, so a skip, a
    // crossfade or the end of the song starts it at once instead of waiting for the stream to open.

    private var preloaded: (uid: UUID, item: AVPlayerItem)?
    private var preObs: NSKeyValueObservation?
    private var preloadFailed: (uid: UUID, until: Date)?        // don't hammer a song (or server) that won't load

    /// Keeps the idle player holding whatever follows the current song. Called from the monitor timer, so it
    /// follows queue edits, shuffle and repeat changes by itself.
    /// AirPlay is chosen per player (AirPlayMenu sets it on the current one): keep the second player, which the
    /// next song fades in on, on the same route. Not public API, so only if this macOS still has it.
    private func shareRoute() {
        let get = NSSelectorFromString("outputContext"), set = NSSelectorFromString("setOutputContext:")
        guard cur.responds(to: get), other.responds(to: get), other.responds(to: set) else { return }
        let a = cur.perform(get)?.takeUnretainedValue(), b = other.perform(get)?.takeUnretainedValue()
        if a !== b { _ = other.perform(set, with: a) }
    }

    private func ensurePreload() {
        guard active, isPlaying, fade == nil, let n = followingIndex, n != index, tracks.indices.contains(n),
              cur.currentItem?.isPlaybackLikelyToKeepUp == true          // the current song gets the network first
        else { if !active || fade != nil { forgetPreload() }; return }
        let t = tracks[n]
        if preloaded?.uid == t.uid { return }
        if let f = preloadFailed, f.uid == t.uid, Date() < f.until { return }
        let item = makeItem(t.stream, watch: false)
        item.preferredForwardBufferDuration = 20                          // enough to start; the rest loads once it plays
        let uid = t.uid
        preObs = item.observe(\.status) { [weak self] it, _ in
            DispatchQueue.main.async {
                guard let self, it.status == .failed else { return }
                if it === self.cur.currentItem { self.skipAfterFailure(); return }
                guard self.preloaded?.item === it else { return }
                // couldn't preload: skipping falls back to loading it fresh; try again later
                self.preloadFailed = (uid, Date().addingTimeInterval(30))
                self.preloaded = nil; self.preObs = nil
                if self.fade == nil { self.other.replaceCurrentItem(with: nil) }
            }
        }
        other.volume = 1
        other.replaceCurrentItem(with: item)
        preloaded = (uid, item)
    }

    /// True if the idle player already holds track `i` (which then stops being "the preload").
    private func adoptPreload(for i: Int) -> Bool {
        guard let p = preloaded, tracks.indices.contains(i), tracks[i].uid == p.uid,
              other.currentItem === p.item, p.item.status != .failed else { return false }
        p.item.preferredForwardBufferDuration = 0
        itemObs = preObs; preObs = nil            // its failure handling moves with it
        if p.item.status == .readyToPlay { failStreak = 0 }
        preloaded = nil
        return true
    }

    /// The idle player is about to be used for something else (or was just cleared).
    private func forgetPreload() { preloaded = nil; preObs = nil }

    /// Debug (`skiptime` / `skiptime cold`): skips to the next song and reports how long until its audio
    /// clock moves; `cold` throws the preload away first, to compare.
    func debugSkipTime(cold: Bool, done: @escaping (String) -> Void) {
        let had = preloaded != nil
        if cold, fade == nil { forgetPreload(); other.replaceCurrentItem(with: nil); preloadFailed = nil }
        let t0 = Date()
        skipNext()
        let p = cur
        let t = Timer(timeInterval: 0.005, repeats: true) { timer in
            let dt = Date().timeIntervalSince(t0)
            let pos = p.currentTime().seconds
            guard (p.timeControlStatus == .playing && pos.isFinite && pos > 0.02) || dt > 20 else { return }
            timer.invalidate()
            done(String(format: "%@ preload=%@ → %.0f ms", cold ? "cold" : "warm", cold ? "dropped" : (had ? "ready" : "none"), dt * 1000))
        }
        RunLoop.main.add(t, forMode: .common)
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
        resumeAt = 0
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

    private func sameAlbum(_ a: StreamTrack, _ b: StreamTrack) -> Bool {
        !a.album.isEmpty && a.album == b.album && a.artist == b.artist
            && (a.coverId == nil || b.coverId == nil || a.coverId == b.coverId)
    }

    private func checkCrossfade() {
        let xf = cfg.crossfadeSeconds
        guard xf > 0, active, isPlaying, fade == nil, cfg.repeatMode != "one", let n = followingIndex else { return }
        // albums flow straight into the next track: no fade between songs of the same album
        if cfg.noCrossfadeInAlbums, sameAlbum(tracks[index], tracks[n]) { return }
        let d = cur.currentItem?.duration.seconds ?? 0
        let dur = d.isFinite && d > 0 ? d : tracks[index].duration
        let pos = cur.currentTime().seconds
        guard dur > xf * 2, pos.isFinite else { return }
        if dur - pos <= xf { startCrossfade(over: max(0.6, dur - pos)) }
    }

    /// Skipping by hand (Touch Bar, media keys): crossfades too when "Crossfade when skipping" is on.
    func skipNext() {
        if cfg.skipCrossfade, isPlaying, let n = followingIndex, n != index {
            cancelFade(); startCrossfade(over: cfg.skipCrossfadeSeconds, to: n)
        } else { next() }
    }
    /// Back to the previous song regardless of how far into this one we are.
    func previousTrack() {
        guard index > 0 else { seek(0); return }
        if cfg.skipCrossfade, isPlaying { cancelFade(); startCrossfade(over: cfg.skipCrossfadeSeconds, to: index - 1) }
        else { index -= 1; playCurrent() }
    }

    private func startCrossfade(over d: Double, to target: Int? = nil) {
        let out = cur, inn = other
        let n = target ?? followingIndex ?? index + 1
        if n == index { resetListening() }          // repeat-all on a one-song queue: a new listen
        index = n
        inn.volume = 0
        if !adoptPreload(for: n) {
            forgetPreload()
            inn.replaceCurrentItem(with: makeItem(tracks[index].stream))
        }
        wantPlaying = true
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

    // Pausing eases the volume down instead of cutting off; resuming eases it back up.
    private var ramp: Timer?
    private var pausing = false
    static let pauseFade = 0.6, resumeFade = 0.25

    /// Moves `cur`'s volume to `to` over `d` seconds, then runs `done`.
    private func rampVolume(to: Float, over d: Double, done: (() -> Void)? = nil) {
        ramp?.invalidate()
        let p = cur, from = p.volume, start = Date()
        let t = Timer(timeInterval: 0.02, repeats: true) { [weak self] timer in
            let f = min(1, Date().timeIntervalSince(start) / d)
            let e = Float(0.5 - cos(f * .pi) / 2)          // ease in and out
            p.volume = from + (to - from) * e
            if f >= 1 { timer.invalidate(); self?.ramp = nil; done?() }
        }
        RunLoop.main.add(t, forMode: .common)
        ramp = t
    }

    /// Ends a pause/resume ramp at once: a pending pause takes effect, the volume goes back to full.
    private func finishRamp() {
        guard ramp != nil || pausing else { return }
        ramp?.invalidate(); ramp = nil
        if pausing { pausing = false; cur.pause(); save() }
        cur.volume = 1
    }

    /// Finish any fade immediately (used by pause / skip / seek).
    private func cancelFade() {
        finishRamp()
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
    /// Precise timing: without it a seek lands by estimate and the audio can be seconds away from the time
    /// the player reports (measured on FLAC: -7 s … +2 s), so lyrics and the scrubber were off after seeking.
    /// The `seektest` debug hook measures this.
    static func asset(_ url: URL) -> AVURLAsset {
        AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    }
    private func makeItem(_ url: URL, watch: Bool = true) -> AVPlayerItem {
        let it = AVPlayerItem(asset: Self.asset(url))
        attachVisualizerTap(to: it)
        guard watch else { return it }            // a preload: watched separately until it becomes the song
        itemObs = it.observe(\.status) { [weak self] it, _ in
            DispatchQueue.main.async {
                guard let self, it === self.cur.currentItem else { return }
                if it.status == .readyToPlay { self.failStreak = 0 }
                guard it.status == .failed else { return }
                NSLog("LyricsBar: stream failed: \(it.error?.localizedDescription ?? "?")")
                self.skipAfterFailure()
            }
        }
        return it
    }
    @objc func failed(_ n: Notification) {
        let item = n.object as? AVPlayerItem
        DispatchQueue.main.async {
            guard item != nil, item === self.cur.currentItem else { return }
            self.skipAfterFailure()
        }
    }
    /// One bad file: skip it. Several in a row means the server is unreachable (or the login expired):
    /// pause there and keep the queue, instead of failing through every song and ending playback.
    private var failStreak = 0
    private weak var failedItem: AVPlayerItem?     // a failure is reported twice (status + notification): handle it once
    private var resumeAt: Double = 0               // where the loaded song should continue if it has to be loaded again
    private var wantPlaying = false                // the user's intent (the player itself may report paused after a failure)
    private func skipAfterFailure() {
        if let it = cur.currentItem { if it === failedItem { return }; failedItem = it }
        // paused (a queue restored at login before the network is up, or after a long sleep): don't start
        // playing or move through the queue. play() loads the song again.
        if !wantPlaying { return }
        let at = cur.currentTime().seconds
        if at.isFinite, at > 1 { resumeAt = at }
        failStreak += 1
        if failStreak >= 3 || followingIndex == nil {
            failStreak = 0
            wantPlaying = false
            cancelFade(); cur.pause(); save()
            NotificationCenter.default.post(name: .lyricsBarToast, object: "Can't reach your Subsonic server")
            objectWillChange.send()
            return
        }
        next()
    }

    func play() {
        guard active else { return }
        wantPlaying = true
        if pausing {                                   // pressed again while fading out: come back up
            pausing = false
            rampVolume(to: 1, over: Self.resumeFade); objectWillChange.send(); return
        }
        cancelFade()
        if tracks.indices.contains(index), cur.currentItem == nil || cur.currentItem?.status == .failed {
            // the song couldn't load (the server was unreachable): a failed item can't be played, so load it again
            let at = cur.currentTime().seconds
            let pos = at.isFinite && at > 1 ? at : resumeAt
            cur.replaceCurrentItem(with: makeItem(tracks[index].stream))
            if pos > 1 {
                cur.seek(to: CMTime(seconds: pos, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    DispatchQueue.main.async { self?.updateInfo() }
                }
            }
        }
        guard cur.timeControlStatus == .paused else { return }   // already playing
        cur.volume = 0
        cur.play()
        rampVolume(to: 1, over: Self.resumeFade)
    }
    func jump(to i: Int) { guard tracks.indices.contains(i) else { return }; index = i; playCurrent() }
    func pause() {
        guard !pausing else { return }
        wantPlaying = false
        cancelFade()
        guard cur.timeControlStatus != .paused, !testMuted else { cur.pause(); save(); return }
        pausing = true
        objectWillChange.send()
        rampVolume(to: 0, over: Self.pauseFade) { [weak self] in
            guard let self, self.pausing else { return }
            self.pausing = false
            self.cur.pause(); self.cur.volume = 1; self.save()
        }
    }
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
        var pos = cur.currentTime().seconds
        // not loaded yet (just restored, or it failed): keep the position it's meant to continue from
        if !pos.isFinite || (pos < 1 && cur.currentItem?.status != .readyToPlay) { pos = resumeAt }
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
        cur.seek(to: CMTime(seconds: pos, preferredTimescale: 600)) { [weak self] _ in
            DispatchQueue.main.async { self?.updateInfo() }      // paused there: the lyric line shown matches it
        }
        trackChanged()
        resumeAt = pos
    }
    func previous() {
        if cur.currentTime().seconds > 3 || index == 0 { seek(0) } else { previousTrack() }
    }
    func seek(_ s: Double) {
        cancelFade()
        // exact, so what plays matches the position the lyrics are timed to (clock.json, written by updateInfo)
        cur.seek(to: CMTime(seconds: s, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            DispatchQueue.main.async { self?.updateInfo() }
        }
    }
    func stop() {
        objectWillChange.send()
        try? FileManager.default.removeItem(atPath: StreamPlayer.queuePath)
        cancelFade()
        cur.pause()
        cur.replaceCurrentItem(with: nil)
        forgetPreload(); other.replaceCurrentItem(with: nil)
        wantPlaying = false
        tracks = []
        shuffled = false; unshuffled = []
        setCommands(false)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Publishes to the system Now Playing feed, so lyricsd / media keys / Control Center see it.
    /// The exact clock for lyricsd (Now Playing reaches it late). Rewritten every second while playing too:
    /// after a seek the player reports "playing" while the audio is still restarting, which left the
    /// clock a few tenths of a second ahead until the next update.
    func writeClock() {
        guard tracks.indices.contains(index) else { return }
        let t = tracks[index], pos = cur.currentTime().seconds
        let clock: [String: Any] = ["bundle": Bundle.main.bundleIdentifier ?? "", "title": t.title, "artist": t.artist,
                                    "album": t.album, "duration": t.duration, "position": pos.isFinite ? pos : 0,
                                    "at": Date().timeIntervalSince1970, "rate": cur.timeControlStatus == .playing ? 1.0 : 0.0]
        if let d = try? JSONSerialization.data(withJSONObject: clock) {
            try? d.write(to: URL(fileURLWithPath: home + "/clock.json"), options: .atomic)
        }
    }

    func updateInfo() {
        guard tracks.indices.contains(index) else { return }
        let t = tracks[index]
        let pos = cur.currentTime().seconds
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title, MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album, MPMediaItemPropertyPlaybackDuration: t.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: pos.isFinite ? pos : 0,
            // 0 while (re)buffering after a seek or skip, so lyrics don't run ahead of the audio
            MPNowPlayingInfoPropertyPlaybackRate: cur.timeControlStatus == .playing ? 1.0 : 0.0,
        ]
        if let a = artwork { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: a.size) { _ in a } }
        writeClock()
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

/// A paused song another app left behind (e.g. Music after a restart) shouldn't take over the bar: until that
/// app plays while LyricsBar runs, it's ignored unless it's the default player.
enum NowPlayingFilter {
    static var seenPlaying = Set<String>()
    static func ignored(_ j: [String: Any]) -> Bool {
        let bundle = j["bundle"] as? String ?? ""
        if j["playing"] as? Bool ?? false { seenPlaying.insert(bundle); return false }
        guard !bundle.isEmpty, bundle != Bundle.main.bundleIdentifier, !seenPlaying.contains(bundle) else { return false }
        return bundle != ConfigStore.shared.defaultBundle
    }
}

private var systemStateCache: (at: Date, value: (playing: Bool, bundle: String, title: String))?
func systemState() -> (playing: Bool, bundle: String, title: String) {
    // called several times per tick: one read per 100 ms is plenty
    if let c = systemStateCache, Date().timeIntervalSince(c.at) < 0.1 { return c.value }
    var v: (playing: Bool, bundle: String, title: String) = (false, "", "")
    if let d = FileManager.default.contents(atPath: home + "/state.json"),
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], !NowPlayingFilter.ignored(j) {
        v = (j["playing"] as? Bool ?? false, j["bundle"] as? String ?? "", j["title"] as? String ?? "")
    }
    systemStateCache = (Date(), v)
    return v
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

/// Tells lyricsd about a seek right away: the system Now Playing feed often doesn't announce seeks,
/// so lyrics would keep running from the old position until the next periodic update.
func noteSeek(_ v: Double) {
    let s = String(format: "{\"position\": %.3f, \"at\": %.3f}", v, Date().timeIntervalSince1970)
    try? s.write(toFile: home + "/seek.json", atomically: true, encoding: .utf8)
}

/// Returns false only for a play with nothing loaded and the default set to "ask".
@discardableResult
func transport(_ t: Transport) -> Bool {
    if case .seek(let v) = t { noteSeek(v) }
    let sp = StreamPlayer.shared
    if ownPlayerInCharge() {
        switch t {
        case .toggle: sp.toggle()
        case .next: sp.skipNext()
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
    case .next:
        // an Up Next order kept by LyricsBar: its first song, not whatever Spotify has queued itself
        if !SpotifyQueue.shared.handleNext() { run(mediaControl, ["next-track"]) }
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
        let pill = cfg.buttonStyle == "pill"
        v.layer?.backgroundColor = NSColor.white.withAlphaComponent(items[i].action == nil || !pill ? 0 : 0.14).cgColor
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
        for i in items.indices {                   // itemViewForItem is non-nil only for visible items
            guard items[i].hold != nil, let v = scrubber.itemViewForItem(at: i) else { continue }
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

    func scrubber(_ s: NSScrubber, didChangeVisibleRange r: NSRange) { onInteract?() }   // scrolling keeps the picker open
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
    var castBtn: PillButton!
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
    var currentArtist = ""
    var pickerRow: NSStackView!
    var pickerTransport: Capsule!
    var pickerPlayBtn: PillButton!
    var briBtn: PillButton!, appsBtn: PillButton!
    var kbdBtn: PillButton!, siriBtn: PillButton!, shotBtn: PillButton!, regularBtn: PillButton!
    var moreBtn: PillButton!
    var stripExpanded = false
    var stripTimer: Timer?
    /// Folds the strip after its timeout, but never under a swipe (the line's geometry is fixed while dragging).
    func autoFoldStrip() {
        guard swipeDragging || swipeSettling else { setStripExpanded(false); return }
        stripTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.autoFoldStrip() }
    }
    /// Keyboard light, Siri, Screenshot and regular-bar live behind the ‹ button so the bar stays roomy.
    var forceLeft = false                    // the strip is expanded: lyrics move to the left edge
    var onRegularBar: (() -> Void)?
    var anyStripButton: Bool {
        StripSlot.normalized(cfg.stripLayout).contains { $0.place != "off" && ($0.id != "keyboard" || KeyboardLight.available) }
    }
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
            if !up && self.stripIsSpotify { DispatchQueue.main.async { self.syncSpotifyStrip() } }
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
        queueStrip.onClear = { [weak self] in
            guard let self else { return }
            if self.stripIsSpotify {
                SpotifyQueue.shared.clear { err in
                    if let err { self.toast(err, seconds: 3); self.syncSpotifyStrip() }   // put the songs back
                    else { self.toast("Cleared. Spotify stops after this song", seconds: 2) }
                }
                self.queueStrip.entries = []
                self.closePicker()
            } else {
                StreamPlayer.shared.clearUpcoming()
                self.closePicker()
                self.toast("Cleared Up Next", seconds: 1.5)
            }
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
        // Spotify's queue changes (after an edit, or from the Library): follow it, never mid-drag
        spotifySync = SpotifyQueue.shared.$items.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncSpotifyStrip() }
        }
        lyricArea.label = lyric
        setUpSwipe()
        lyricArea.onDragBegan = { [weak self] in self?.beginSwipe() }
        lyricArea.onDrag = { [weak self] dx in self?.updateSwipe(dx) }
        lyricArea.onDragEnded = { [weak self] dx in self?.endSwipe(dx) }
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
        kbdBtn = PillButton(symbol("light.max", 14), self, #selector(openKeyboardLight), width: 52)
        siriBtn = PillButton(symbol("siri", 15), self, #selector(openSiri), width: 52)
        shotBtn = PillButton(symbol("camera.viewfinder", 14), self, #selector(openScreenshot), width: 52)
        regularBtn = PillButton(symbol("rectangle.badge.xmark", 14), self, #selector(regularBar), width: 52)
        castBtn = PillButton(symbol("airplayaudio", 14), self, #selector(openCast), width: 52)
        moreBtn = PillButton(symbol("chevron.left", 13, .bold), self, #selector(toggleStripExpanded), width: 34)
        strip = Capsule([moreBtn, castBtn, kbdBtn, siriBtn, shotBtn, regularBtn, briBtn, volBtn, appsBtn], spacing: 10)
        for (btn, panel) in [(briBtn!, Panel.brightness), (volBtn!, .volume), (kbdBtn!, .keyboard)] {
            let o = SlideOverlay()
            fill(o, in: btn)
            o.onTap = { [weak self] in self?.openPanel(panel) }
            o.onSlide = { [weak self] d in
                guard let self else { return }
                switch panel {
                case .volume:
                    if Sys.muted && d > 0 { Sys.muted = false }
                    Sys.volume = max(0, min(1, Sys.volume + d))
                    self.volBtn.image = symbol(Sys.volumeSymbol, 14)
                    self.toast("Volume  \(Int((Sys.muted ? 0 : Sys.volume) * 100))%")
                case .keyboard:
                    KeyboardLight.level = max(0, min(1, KeyboardLight.level + d))
                    self.toast("Keyboard  \(Int(KeyboardLight.level * 100))%")
                default:
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
        applyStripButtons()
        strip.isHidden = panelMode != .none || !anyStripButton
        if !pickerMode { shuffle = cfg.defaultShuffle }
        applyVisualizer()
        let k = lyricKey; lyricKey = "\u{1}"                 // re-render with new style
        if Date() >= titleCardUntil && !k.hasPrefix("\u{1}") { setLyric(k) }
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
        let centered = cfg.lyricAlignment == "center" && !forceLeft
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

    var lyricCentered: Bool { cfg.lyricAlignment == "center" && !forceLeft }
    /// Re-aligns whatever the lyric line shows now (the strip expanded or folded).
    func realignLyric() {
        let a = NSMutableAttributedString(attributedString: lyric.attributedStringValue)
        a.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: a.length)) { v, r, _ in
            let p = ((v as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            p.alignment = lyricCentered ? .center : .left
            a.addAttribute(.paragraphStyle, value: p, range: r)
        }
        lyric.attributedStringValue = a
    }
    func lyricAttrs(_ color: NSColor, _ weight: NSFont.Weight = .semibold) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = lyricCentered ? .center : .left
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
        if let l = swipeLanded, l.0 == title, Date().timeIntervalSince(l.1) < 8 {
            // the swipe already put this song's title in place: just settle it
            swipeLanded = nil; outroActive = false; pendingSlide = nil
            if !swipeSettling {                     // still sliding: the swipe puts the text in when it lands
                lyric.alphaValue = 1
                lyric.attributedStringValue = titleText(title, artist)
            }
            lyricKey = "\u{1}card"
            if cfg.titleCardSeconds > 0 { titleCardUntil = Date().addingTimeInterval(cfg.titleCardSeconds) }
            else if !swipeSettling { titleCardUntil = .distantPast; lyricKey = "\u{1}" }
            // (while it settles, the swipe's own hold keeps lyrics off the sliding line; they follow after)
            return
        }
        if swipeDragging || swipeSettling {             // applied when the swipe lets go of the line
            swipePendingCard = (title, artist, slideIn); return
        }
        swipeLanded = nil
        let wasOutro = outroActive
        outroActive = false
        guard cfg.titleCardSeconds > 0, !title.isEmpty else {
            if wasOutro { titleCardUntil = .distantPast; lyricKey = "\u{1}" }
            return
        }
        titleCardUntil = Date().addingTimeInterval(cfg.titleCardSeconds)
        lyricKey = "\u{1}card"
        let a = titleText(title, artist)
        lyric.alphaValue = 1
        var sub: CATransitionSubtype? = slideIn ? .fromRight : nil
        if let p = pendingSlide, Date().timeIntervalSince(p.1) < 4 { sub = p.0 }
        pendingSlide = nil
        // after the "NEXT" preview: that title glides from where it was into place, the rest fades away
        if wasOutro, sub == .fromRight, let from = outroNextX, title == outroNextTitle, !lyric.isHidden {
            layoutSubtreeIfNeeded()
            fadeOutSnapshot(upTo: from - lyric.frame.minX)   // the old title and NEXT fade where they are
            lyric.attributedStringValue = a
            layoutSubtreeIfNeeded()
            glideLyric(from: from - (lyric.frame.minX + (textStartX(a) ?? 2)))
            return
        }
        if let sub {
            // the next title slides in (from the right, or from the left after swiping back)
            let t = CATransition(); t.type = .push; t.subtype = sub; t.duration = 0.4
            t.timingFunction = .init(name: .easeInEaseOut)
            lyric.layer?.add(t, forKey: "lyric")
        } else { animateLyric() }
        lyric.attributedStringValue = a
    }

    /// Near the end of a song: its title comes back, with the next song's title to the right.
    func titleText(_ title: String, _ artist: String) -> NSMutableAttributedString {
        let a = NSMutableAttributedString(string: title, attributes: lyricAttrs(.white))
        if !artist.isEmpty {
            a.append(NSAttributedString(string: "   " + artist, attributes: lyricAttrs(NSColor.white.withAlphaComponent(0.6), .regular)))
        }
        return a
    }
    /// A song without lyrics keeps the title card's "Title   Artist" (same key, so nothing re-animates).
    func showTitleLine(_ title: String, _ artist: String) {
        if Date() < titleCardUntil || pausedActive || swipeDragging { return }
        guard lyricKey != "\u{1}card" else { return }
        lyricKey = "\u{1}card"
        animateLyric()
        lyric.attributedStringValue = titleText(title, artist)
    }

    var outroNextTitle: String?, outroNextX: CGFloat?
    /// Where text starts inside the lyric label (nil if it doesn't fit, so it's truncated).
    func textStartX(_ a: NSAttributedString) -> CGFloat? {
        let w = ceil(a.size().width), avail = lyric.bounds.width - 4
        guard w <= avail else { return nil }
        return lyricCentered ? (lyric.bounds.width - w) / 2 : 2
    }
    // MARK: swipe between songs

    let swipeClip = NSView()
    let swipePreview = NSTextField(labelWithString: "")
    /// What a swipe lands on: a song's title, restarting this song (↶), or a song we can't name (⏮ / ⏭).
    enum SwipeTarget: Equatable { case song(String, String), restart, previous, next }
    var swipeNext: SwipeTarget?, swipePrevSong: SwipeTarget?
    var swipeRestartable = false
    private var swipeTarget: SwipeTarget?
    var swipeDragging = false
    var swipeLanded: (String, Date)?
    var swipeSettling = false
    var peekNext: ((@escaping ((String, String)?) -> Void) -> Void)?   // App: the next song for any player
    private var swipeGeo: (start: CGFloat, rest: CGFloat)?
    static let swipeLand: CGFloat = 80                 // ↶ follows the finger this far, then holds
    static let swipeHitch: CGFloat = 70                // ↶ holds for this much pull before the previous song
    static let swipeFade: CGFloat = 110                // the current text fades out over this much drag
    private var swipeLyricEnd: CGFloat = 0
    private var swipeLastDX: CGFloat = 0
    private var swipeRestore: NSAttributedString?      // the line shown before the swipe put the title up
    private var swipeGen = 0                           // one per drag: stale timers and replies check it
    private var swipeFinish: (() -> Void)?             // the settle's last step, still to run
    private var swipeSong = ""                         // the song the drag started on
    private var swipePendingCard: (String, String, Bool)?   // a song change that arrived mid-swipe
    var outroClip: NSView?
    private var swipeShown: SwipeTarget?
    static let swipeGap: CGFloat = 48                  // space between the current text and the incoming one
    static let swipeIconGap: CGFloat = 30              // the same when the incoming one is ↶ / ⏮ / ⏭
    private let swipeMask = CALayer()                  // keeps the dragged text off the cover and buttons

    /// Clips the moving lyric to the swipe area; `tx` is the lyric's current offset.
    /// `cut`: the preview's edge on the bar; the current text is hidden beyond it (the preview slides over it).
    private func placeSwipeMask(_ tx: CGFloat, cut: (x: CGFloat, keepLeft: Bool)? = nil) {
        guard let layer = lyric.layer else { return }
        var lo = swipeClip.frame.minX, hi = swipeClip.frame.maxX
        if let c = cut { if c.keepLeft { hi = min(hi, c.x) } else { lo = max(lo, c.x) } }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        swipeMask.backgroundColor = NSColor.black.cgColor
        swipeMask.anchorPoint = .zero
        swipeMask.bounds = CGRect(x: 0, y: 0, width: max(0, hi - lo), height: max(layer.bounds.height, 40))
        swipeMask.position = CGPoint(x: lo - (lyric.frame.minX + tx), y: -10)
        if layer.mask !== swipeMask { layer.mask = swipeMask }
        CATransaction.commit()
    }

    func setUpSwipe() {
        swipeClip.wantsLayer = true
        swipeClip.layer?.masksToBounds = true
        swipeClip.isHidden = true
        swipePreview.lineBreakMode = .byTruncatingTail
        swipePreview.wantsLayer = true
        swipePreview.layer?.masksToBounds = true
        swipeClip.addSubview(swipePreview)
        addSubview(swipeClip, positioned: .above, relativeTo: lyric)
    }

    func symbolText(_ name: String) -> NSAttributedString {
        let att = NSTextAttachment()
        if let img = coloredSymbol(name, cfg.lyricFontSize, .white) {
            att.image = img
            att.bounds = CGRect(x: 0, y: -2, width: img.size.width, height: img.size.height)
        }
        let a = NSMutableAttributedString(attachment: att)
        a.addAttributes(lyricAttrs(.white), range: NSRange(location: 0, length: a.length))
        return a
    }
    func swipeText(_ t: SwipeTarget) -> NSAttributedString {
        switch t {
        case .song(let title, let artist): return titleText(title, artist)
        case .restart: return symbolText("arrow.uturn.backward")
        case .previous: return symbolText("backward.end.fill")
        case .next: return symbolText("forward.end.fill")
        }
    }

    var ownPlayerActive: Bool { bundleId == Bundle.main.bundleIdentifier && StreamPlayer.shared.active }

    func beginSwipe() {
        guard !currentTitle.isEmpty else { return }
        if let f = swipeFinish { swipeFinish = nil; f() }   // a quick second swipe: land the first one now
        swipeGen += 1
        swipeDragging = true
        swipeSong = currentTitle
        swipePendingCard = nil
        for k in ["swipe", "glide", "align", "lyric"] { lyric.layer?.removeAnimation(forKey: k) }
        outroClip?.removeFromSuperview(); outroClip = nil
        layoutSubtreeIfNeeded()
        // the preview stays between the cover and whatever is on the right
        let left = artButton.frame.maxX + 6
        let right = ([strip, panel, mediaView] as [NSView]).filter { !$0.isHidden }.map(\.frame.minX).min() ?? bounds.maxX
        swipeClip.frame = NSRect(x: left, y: 0, width: max(0, right - 8 - left), height: bounds.height)
        swipeClip.isHidden = false
        swipePreview.isHidden = true
        swipeShown = nil; swipeLastDX = 0
        // while swiping the line shows the song (title and artist), faded in quickly; a cancel fades the line back
        let title = titleText(currentTitle, currentArtist)
        swipeRestore = nil
        if lyric.attributedStringValue.string != title.string, !lyric.isHidden {
            swipeRestore = lyric.attributedStringValue
            let t = CATransition(); t.type = .fade; t.duration = 0.15
            lyric.layer?.add(t, forKey: "lyric")
            lyric.attributedStringValue = title
            layoutSubtreeIfNeeded()
        }
        placeSwipeMask(0)
        let sp = StreamPlayer.shared, own = ownPlayerActive
        // past 3 s, previous restarts the song; pulling further goes to the song before
        swipeRestartable = position > 3
        if own {
            swipePrevSong = sp.tracks.indices.contains(sp.index - 1)
                ? .song(sp.tracks[sp.index - 1].title, sp.tracks[sp.index - 1].artist) : nil
        } else { swipePrevSong = .previous }
        if own, let n = sp.followingIndex { swipeNext = .song(sp.tracks[n].title, sp.tracks[n].artist) }
        else {
            swipeNext = own ? nil : .next
            let gen = swipeGen, song = currentTitle
            peekNext? { [weak self] n in
                guard let self, self.swipeDragging, self.swipeGen == gen, let n, !n.0.isEmpty,
                      n.0 != song else { return }
                self.swipeNext = .song(n.0, n.1)
                self.updateSwipe(self.swipeLastDX)
            }
        }
    }

    func updateSwipe(_ dx: CGFloat) {
        guard swipeDragging else { return }
        swipeLastDX = dx
        let toNext = dx < 0
        // what slides in first: the next song, ↶ when previous would restart this one, else the previous song
        let first: SwipeTarget? = toNext ? swipeNext : (swipeRestartable ? .restart : (swipePrevSong ?? .restart))
        guard let first else {
            lyric.layer?.setAffineTransform(CGAffineTransform(translationX: dx, y: 0)); placeSwipeMask(dx)
            lyric.alphaValue = 1 - min(0.6, abs(dx) / 300)
            swipePreview.isHidden = true; swipeGeo = nil; swipeTarget = nil; return
        }
        func geo(_ t: SwipeTarget) -> (w: CGFloat, rest: CGFloat) {
            // a long title is cut off (…) at the most the line can show, like the line itself does
            let w = min(ceil(swipeText(t).size().width) + 4, swipeClip.frame.maxX - 6 - lyric.frame.minX)
            return (w, lyricCentered ? max(lyric.frame.minX, lyric.frame.midX - w / 2) : lyric.frame.minX)
        }
        // Everything follows the finger 1:1. The preview waits just past the end of the current text (a gap away)
        // and slides in with it; letting go past 60 pt lands it in place. Going back, ↶ moves `swipeLand`,
        // holds for `swipeHitch` (fading out), then the previous song comes in from where ↶ stood.
        var gap = Self.swipeGap
        if case .song = first {} else { gap = Self.swipeIconGap }   // an icon sits closer than a title would
        let cur = lyric.attributedStringValue
        let curLeft = lyric.frame.minX + (textStartX(cur) ?? 2)
        let curW = textStartX(cur) != nil ? ceil(cur.size().width) : lyric.bounds.width - 4
        var target = first
        var tg = geo(target)
        var px = toNext ? curLeft + curW + gap + dx : curLeft - gap - tg.w + dx
        var alpha = min(1, abs(dx) / 40)
        if first == .restart, swipeRestartable {
            let land = Self.swipeLand, hitch = Self.swipeHitch
            let held = curLeft - gap - tg.w + min(dx, land)          // ↶ stops after `swipeLand`
            px = held
            if swipePrevSong != nil {
                let h = hitch / 2
                alpha = min(alpha, 1 - max(0, min(1, (dx - land - h) / h)))
            }
            if let p = swipePrevSong, dx > land + hitch {
                let s = dx - land - hitch
                target = p
                let right = held + tg.w                               // the previous song comes in where ↶ was
                tg = geo(p)
                px = right - tg.w + s
                alpha = min(1, s / 40)
            }
        }
        swipeTarget = target
        lyric.layer?.setAffineTransform(CGAffineTransform(translationX: dx, y: 0))
        placeSwipeMask(dx)
        lyric.alphaValue = max(0, 1 - abs(dx) / Self.swipeFade)
        swipeLyricEnd = dx + (tg.rest - px)                 // landing moves everything by what's left
        let a = swipeText(target)
        if swipeShown != target {
            if let shown = swipeShown, shown != target, shown != .restart, target != .restart {
                let t = CATransition(); t.type = .fade; t.duration = 0.15    // ⏭ → the next song's name
                swipePreview.layer?.add(t, forKey: "swap")
            }
            swipePreview.attributedStringValue = a
            swipeShown = target
        }
        swipeGeo = (px - dx, tg.rest)
        swipePreview.frame = NSRect(x: px - swipeClip.frame.minX, y: lyric.frame.minY,
                                    width: tg.w, height: lyric.frame.height)
        swipePreview.alphaValue = alpha
        swipePreview.isHidden = false
    }

    func endSwipe(_ dx: CGFloat) {
        guard swipeDragging else { return }
        swipeDragging = false
        let toNext = dx < 0
        guard abs(dx) > 60, let target = swipeTarget, let g = swipeGeo, !swipePreview.isHidden else {
            // brought back to the middle: stay on this song
            let restore = swipeRestore; swipeRestore = nil
            moveLyric(to: 0, alpha: 1, follow: true) { [weak self] in
                guard let self else { return }
                // the song changed meanwhile: its title card now
                if let c = self.swipePendingCard { self.swipePendingCard = nil; self.showTitleCard(c.0, c.1, slideIn: c.2); return }
                // back to the line it showed (a lyric that changed meanwhile follows on the next tick)
                guard let restore, self.currentTitle == self.swipeSong, self.lyric.attributedStringValue.string
                        == self.titleText(self.currentTitle, self.currentArtist).string else { return }
                let t = CATransition(); t.type = .fade; t.duration = 0.2
                self.lyric.layer?.add(t, forKey: "lyric")
                self.lyric.attributedStringValue = restore
            }
            if let g = swipeGeo { movePreview(to: g.start, alpha: 0) } else { swipeClip.isHidden = true }
            return
        }
        swipeRestore = nil
        let travel = swipeLyricEnd                          // the text keeps its distance from the landing preview
        movePreview(to: g.rest, alpha: 1)
        // nothing else may write to the line while it slides out (lyrics, the song change's title card)
        swipeSettling = true
        lyricKey = "\u{1}card"
        titleCardUntil = Date().addingTimeInterval(max(cfg.titleCardSeconds, 2))
        let landed = swipeText(target)
        moveLyric(to: travel, alpha: 0, follow: false) { [weak self] in
            guard let self else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.lyric.layer?.removeAnimation(forKey: "swipe")
            self.lyric.layer?.setAffineTransform(.identity)
            self.lyric.layer?.mask = nil
            self.lyric.attributedStringValue = landed
            self.lyric.alphaValue = 1
            self.pausedActive = false
            self.swipeClip.isHidden = true
            CATransaction.commit()
            self.swipeSettling = false
            if case .song = target {} else {
                // an icon isn't the title card: the title (or lyrics) replace it once the hold ends
                self.lyricKey = "\u{1}icon"
            }
            if let c = self.swipePendingCard {          // the song change came in while it slid
                self.swipePendingCard = nil
                self.showTitleCard(c.0, c.1, slideIn: c.2)
            } else if target == .restart {             // same song from the top: its title comes back
                let gen = self.swipeGen
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, self.swipeGen == gen, !self.swipeDragging, self.lyricKey == "\u{1}icon" else { return }
                    self.showTitleCard(self.currentTitle, self.currentArtist)
                }
            }
        }
        pendingSlide = nil
        if case .song(let title, _) = target { swipeLanded = (title, Date()) } else { swipeLanded = nil }
        if toNext { next() }
        else if target == .restart { bumpMediaTimer(); localSeek = (0, Date().timeIntervalSince1970); transport(.seek(0)) }
        else { skipToPreviousSong() }                  // the player's own 3 s rule could restart instead
    }

    /// The song before this one, even when previous would only restart it.
    func skipToPreviousSong() {
        bumpMediaTimer()
        if ownPlayerActive { StreamPlayer.shared.previousTrack(); return }
        transport(.seek(0))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { transport(.previous) }
    }

    /// `follow`: keep the clip fixed on the bar (no preview); otherwise it moves with the text, like the preview does.
    private func moveLyric(to x: CGFloat, alpha: CGFloat, follow: Bool = true, done: (() -> Void)? = nil) {
        guard let layer = lyric.layer else { done?(); return }
        let from = layer.affineTransform().tx
        // timed rather than a CATransaction completion: AppKit can end the layer animation early
        let gen = swipeGen
        swipeFinish = done
        if done != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            guard let self, self.swipeGen == gen, let f = self.swipeFinish else { return }
            self.swipeFinish = nil; f() } }
        CATransaction.begin()
        let m = CABasicAnimation(keyPath: "transform.translation.x")
        m.fromValue = from; m.toValue = x; m.duration = 0.3
        m.timingFunction = .init(name: .easeOut)
        layer.setAffineTransform(CGAffineTransform(translationX: x, y: 0))
        layer.add(m, forKey: "swipe")
        if layer.mask === swipeMask && follow {
            let mx = swipeClip.frame.minX - lyric.frame.minX
            let k = CABasicAnimation(keyPath: "position.x")
            k.fromValue = mx - from; k.toValue = mx - x; k.duration = 0.3
            k.timingFunction = .init(name: .easeOut)
            swipeMask.position.x = mx - x
            swipeMask.add(k, forKey: "follow")
        }
        CATransaction.commit()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) { [weak self] in
            guard let self, self.swipeGen == gen, !self.swipeDragging, layer.mask === self.swipeMask else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            layer.mask = nil
            CATransaction.commit()
        }
        NSAnimationContext.runAnimationGroup { c in c.duration = 0.3; lyric.animator().alphaValue = alpha }
    }

    private func movePreview(to x: CGFloat, alpha: CGFloat) {
        let target = NSPoint(x: x - swipeClip.frame.minX, y: swipePreview.frame.minY)
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.3; c.timingFunction = .init(name: .easeOut)
            swipePreview.animator().setFrameOrigin(target)
            swipePreview.animator().alphaValue = alpha
        }, completionHandler: { [weak self] in
            guard let self, !self.swipeDragging, alpha == 0 else { return }
            self.swipeClip.isHidden = true
        })
    }

    func relayoutLyric() {
        lyric.invalidateIntrinsicContentSize()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Switches the lyric between centred and left-aligned, sliding the text across instead of jumping.
    func slideLyricAlignment(left: Bool) {
        layoutSubtreeIfNeeded()
        let start = { self.lyric.frame.minX + (self.textStartX(self.lyric.attributedStringValue) ?? 2) }
        let from = start()
        forceLeft = left
        applyVisualizer()
        realignLyric()
        layoutSubtreeIfNeeded()
        let dx = from - start()
        guard abs(dx) > 1, !lyric.isHidden else { return }
        let m = CABasicAnimation(keyPath: "transform.translation.x")
        m.fromValue = dx; m.toValue = 0; m.duration = 0.35
        m.timingFunction = .init(name: .easeInEaseOut)
        lyric.layer?.add(m, forKey: "align")
    }

    /// Fades out a still copy of the label's left part (up to `x`), so the text after it can move on its own.
    func fadeOutSnapshot(upTo x: CGFloat) {
        guard x > 1, lyric.bounds.width > 0, let host = layer,
              let rep = lyric.bitmapImageRepForCachingDisplay(in: lyric.bounds) else { return }
        lyric.cacheDisplay(in: lyric.bounds, to: rep)
        let w = min(x, lyric.bounds.width)
        let snap = CALayer()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        snap.contents = rep.cgImage
        snap.contentsRect = CGRect(x: 0, y: 0, width: w / lyric.bounds.width, height: 1)
        snap.frame = CGRect(x: lyric.frame.minX, y: lyric.frame.minY, width: w, height: lyric.frame.height)
        snap.contentsScale = window?.backingScaleFactor ?? 2
        host.addSublayer(snap)
        CATransaction.commit()
        CATransaction.begin()
        CATransaction.setCompletionBlock { snap.removeFromSuperlayer() }
        let f = CABasicAnimation(keyPath: "opacity")
        f.fromValue = 1; f.toValue = 0; f.duration = 0.25
        snap.opacity = 0
        snap.add(f, forKey: "fade")
        CATransaction.commit()
    }

    /// Slides the label's text in from `dx` points away.
    func glideLyric(from dx: CGFloat) {
        let m = CABasicAnimation(keyPath: "transform.translation.x")
        m.fromValue = dx; m.toValue = 0; m.duration = 0.45
        m.timingFunction = .init(name: .easeInEaseOut)
        lyric.layer?.add(m, forKey: "glide")
    }

    func showOutro(_ title: String, _ artist: String, next: (String, String)?) {
        let before = lyric.attributedStringValue
        outroActive = true
        outroNextTitle = nil; outroNextX = nil
        titleCardUntil = .distantFuture
        lyricKey = "\u{1}outro"
        let a = titleText(title, artist)
        var nextPrefix: CGFloat?
        if let n = next, !n.0.isEmpty {
            var small = lyricAttrs(NSColor.white.withAlphaComponent(0.45), .bold)
            small[.font] = NSFont.systemFont(ofSize: max(9, cfg.lyricFontSize - 5), weight: .bold)
            small[.kern] = 1.2
            small[.baselineOffset] = 1.5
            a.append(NSAttributedString(string: "        NEXT  ", attributes: small))
            nextPrefix = a.size().width
            a.append(NSAttributedString(string: n.0, attributes: lyricAttrs(NSColor.white.withAlphaComponent(0.85))))
            if !n.1.isEmpty {
                a.append(NSAttributedString(string: "   " + n.1, attributes: lyricAttrs(NSColor.white.withAlphaComponent(0.45), .regular)))
            }
        }
        // positions are measured on the bar: the label is only as wide as its text and moves when that changes
        layoutSubtreeIfNeeded()
        let oldX = lyric.frame.minX + (textStartX(before) ?? 2)
        let sameTitle = before.string.hasPrefix(title) && !lyric.isHidden
        let titleLen = titleText(title, artist).length
        let tail = NSRange(location: titleLen, length: max(0, a.length - titleLen))
        if sameTitle && tail.length > 0 {
            let hidden = NSMutableAttributedString(attributedString: a)    // same layout, NEXT not drawn yet
            hidden.addAttribute(.foregroundColor, value: NSColor.clear, range: tail)
            lyric.attributedStringValue = hidden
        } else { lyric.attributedStringValue = a }
        layoutSubtreeIfNeeded()
        let newX = lyric.frame.minX + (textStartX(a) ?? 2)
        if let n = next, let p = nextPrefix {
            outroNextTitle = n.0
            outroNextX = min(newX + p, lyric.frame.maxX)       // where the next title starts on the bar
        }
        guard sameTitle else {
            lyric.layer?.masksToBounds = true          // the pushed text stays inside the line
            let t = CATransition(); t.type = .push; t.subtype = .fromRight; t.duration = 0.4
            t.timingFunction = .init(name: .easeInEaseOut)
            lyric.layer?.add(t, forKey: "lyric")
            return
        }
        // the title was already showing: the same text stays (sliding over if it was centred)
        if abs(oldX - newX) > 1 {
            let m = CABasicAnimation(keyPath: "transform.translation.x")
            m.fromValue = oldX - newX; m.toValue = 0; m.duration = 0.45
            m.timingFunction = .init(name: .easeInEaseOut)
            lyric.layer?.add(m, forKey: "glide")
        }
        guard tail.length > 0 else { return }
        // ...and NEXT slides in on its own label, then the line takes over with identical layout
        let part = NSMutableAttributedString(attributedString: a.attributedSubstring(from: tail))
        let ps = NSMutableParagraphStyle(); ps.alignment = .left; ps.lineBreakMode = .byTruncatingTail
        part.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: part.length))
        let x = newX + a.attributedSubstring(from: NSRange(location: 0, length: titleLen)).size().width
        let overlay = NSTextField(labelWithAttributedString: part)
        overlay.lineBreakMode = .byTruncatingTail
        overlay.wantsLayer = true
        // a clip the size of the line, so nothing slides over the buttons
        let clip = NSView(frame: NSRect(x: lyric.frame.minX, y: lyric.frame.minY, width: lyric.frame.width + 2, height: lyric.frame.height))
        clip.wantsLayer = true; clip.layer?.masksToBounds = true
        let end = NSRect(x: x - clip.frame.minX, y: 0, width: max(0, lyric.frame.maxX - x + 2), height: lyric.frame.height)
        overlay.frame = end.offsetBy(dx: (oldX - newX) + 40, dy: 0)   // keeps its distance from the sliding title
        overlay.alphaValue = 0
        clip.addSubview(overlay)
        addSubview(clip, positioned: .above, relativeTo: lyric)
        outroClip = clip
        let key = lyricKey
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.45; c.timingFunction = .init(name: .easeInEaseOut)
            overlay.animator().frame = end
            overlay.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            clip.removeFromSuperview()
            guard let self, self.lyricKey == key, !self.swipeDragging, !self.swipeSettling else { return }
            self.lyric.attributedStringValue = a
        })
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
        if Date() < titleCardUntil || pausedActive || swipeDragging { return }
        guard s != lyricKey else { return }
        lyricKey = s
        animateLyric()
        lyric.attributedStringValue = NSAttributedString(string: s, attributes: lyricAttrs(.white))
    }

    /// What the lyric line shows while paused (Settings → General → While paused).
    var pausedActive = false
    func showPaused(_ a: NSAttributedString, key: String) {
        guard Date() >= titleCardUntil, !outroActive, !swipeDragging else { return }
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
        shown[ObjectIdentifier(v)] = on
        if on { v.isHidden = false }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.2
            v.animator().alphaValue = on ? 1 : 0
        }, completionHandler: { [weak self, weak v] in
            // only if it's still meant to be hidden: shown again within the fade, this would hide it for good
            guard let v, !on, self?.shown[ObjectIdentifier(v)] == false else { return }
            v.isHidden = true
        })
    }
    private var shown: [ObjectIdentifier: Bool] = [:]

    @objc func toggleMedia() {
        if pickerParked { closePicker() }        // tucked away behind the expanded strip: act as if it were closed
        if pickerMode { closePicker() }
        else if currentTitle.isEmpty && !mediaMode { openPicker() }      // nothing loaded → choose something
        // paused or playing → the media controls (☰ in there opens the providers)
        else { setMediaMode(!mediaMode) }
    }

    // MARK: picker

    func openPicker() {
        if mediaMode { setMediaMode(false) }
        if stripExpanded { setStripExpanded(false, restore: false) }
        pickerMode = true
        shuffle = cfg.defaultShuffle
        showProviders()
        show(pickerRow, true); show(lyric, false)
        bumpPickerTimer()
    }

    func closePicker() {
        guard pickerMode else { return }
        pickerParked = false
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
    var spotifySync: AnyCancellable?
    func syncSpotifyStrip() {
        guard stripIsSpotify, pickerMode, showingUpNext else { return }
        if queueStrip.isHolding { return }                    // picked back up after the drop (onLift → showUpNext)
        let items = SpotifyQueue.shared.items
        if items.isEmpty { showUpNext(); return }
        if items.map(\.id) != queueStrip.entries.compactMap(\.uid) {
            queueStrip.entries = items.map { .init(title: $0.title, sub: $0.artist, uid: $0.id) }
        }
    }
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
        pickerPage += 1
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
            let hold: (() -> Void)? = p.provider == "subsonic" ? { [weak self] in self?.queuePlaylistNext(p.playlistId, p.name) }
                : p.provider == "spotify" ? { [weak self] in self?.queueSpotifyPlaylist(p.playlistId, p.name) } : nil
            items.append(.init(title: p.name, hold: hold) { [weak self] in self?.playPlaylist(p.provider, p.playlistId, p.name) })
        }
        picker.items = items
    }

    // MARK: cast (Spotify Connect)

    /// The Cast button. Spotify: the picker lists its Connect devices; a tap moves playback there. Anything
    /// else: Control Center's sound output list opens on screen (macOS can't list AirPlay speakers for an app).
    /// Without the Accessibility permission, LyricsBar's own player falls back to Apple's AirPlay menu.
    @objc func openCast() {
        let own = StreamPlayer.shared.active && bundleId != "com.spotify.client"
        if own || !cfg.showSpotify || (bundleId != "com.spotify.client" && !currentTitle.isEmpty) {
            // anything that isn't Spotify: the Mac's own sound output list, in Control Center
            setStripExpanded(false)
            let fallback = { [weak self] (why: String) in
                if own, AirPlayMenu.shared.show() { self?.toast("Pick a speaker on screen", seconds: 2.5) }
                else { self?.toast(why, seconds: 4) }
            }
            guard ControlCenterSound.trusted else {
                ControlCenterSound.askPermission()
                fallback("Allow LyricsBar under Privacy & Security → Accessibility to open the sound menu")
                return
            }
            ControlCenterSound.open { ok in if !ok { fallback("Couldn't open Control Center's sound menu") } }
            return
        }
        if !pickerMode || pickerParked { closePicker(); openPicker() }
        showCastDevices()
    }
    func showCastDevices(note: String? = nil) {
        pickerPage += 1; let page = pickerPage
        showingUpNext = false
        extras.isHidden = true
        setPickerTransport(false)
        useQueueStrip(false)
        setBack { [weak self] in self?.closePicker() }
        picker.items = [.init(title: note ?? "Looking for Spotify devices…", dim: true, action: nil)]
        bumpPickerTimer()
        libraryJSON(["spotify-devices"]) { [weak self] obj, err in
            guard let self, self.pickerMode, self.pickerPage == page else { return }
            guard let list = obj as? [[String: Any]] else {
                self.picker.items = [.init(title: self.castError(err), dim: true, action: nil)]
                return
            }
            if list.isEmpty {
                self.picker.items = [.init(title: "No Spotify devices found. Open Spotify on one first", dim: true, action: nil)]
                return
            }
            self.picker.items = list.compactMap { d in
                guard let id = d["id"] as? String, let name = d["name"] as? String else { return nil }
                let on = d["active"] as? Bool ?? false
                return .init(title: (on ? "✓ " : "") + name, action: on ? nil : { [weak self] in self?.castTo(id, name) })
            }
        }
    }
    func castError(_ err: String?) -> String {
        let e = err ?? ""
        if e.contains("scope") || e.contains("401") || e.lowercased().contains("reconnect") { return "Reconnect Spotify in Settings → Providers" }
        return e.isEmpty || e == "No response" ? "Couldn't reach Spotify" : e
    }
    func castTo(_ id: String, _ name: String) {
        closePicker()
        toast("Moving to \(name)…", seconds: 6)
        libraryJSON(["spotify-transfer", id]) { [weak self] _, err in
            self?.toast(err.map { self?.castError($0) ?? $0 } ?? "Playing on \(name)", seconds: err == nil ? 2 : 4)
        }
    }

    /// Bumped whenever the picker shows a different page, so a slow load can't overwrite a newer page.
    var pickerPage = 0
    func showPlaylists(_ provider: String) {
        pickerPage += 1; let page = pickerPage
        showingUpNext = false
        extras.isHidden = true
        setPickerTransport(false)
        setBack { [weak self] in self?.showProviders() }
        useQueueStrip(false)
        picker.items = [.init(title: "Loading…", dim: true, action: nil)]
        Task { @MainActor [weak self] in
            let result = await loadPlaylists(provider)
            guard let self, self.pickerMode, self.pickerPage == page else { return }
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
                    let hold: (() -> Void)? = provider == "subsonic" ? { [weak self] in self?.queuePlaylistNext(p.id, p.name) }
                        : provider == "spotify" ? { [weak self] in self?.queueSpotifyPlaylist(p.id, p.name) } : nil
                    items.append(.init(title: p.name, hold: hold) { [weak self] in self?.playPlaylist(provider, p.id, p.name) })
                }
                self.picker.items = items
            }
        }
    }

    /// Upcoming songs for whichever player is active.
    func showUpNext() {
        pickerPage += 1; let page = pickerPage
        showingUpNext = true
        defer { updateExtras() }
        if pickerParked {                        // asked for Up Next while tucked away: bring the picker back
            pickerParked = false
            setStripExpanded(false, restore: false)
            show(pickerRow, true); show(lyric, false)
        }
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
                guard let self, self.pickerMode, self.showingUpNext, self.pickerPage == page, !self.queueStrip.isHolding else { return }
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

    /// Hold on a Spotify playlist: add its songs to the end of Spotify's queue (Spotify only queues one song
    /// per request and has no "play next", so they go after anything already queued).
    func queueSpotifyPlaylist(_ id: String, _ name: String) {
        closePicker()
        guard bundleId == "com.spotify.client" else { toast("Play something in Spotify first", seconds: 2.5); return }
        guard !SpotifyQueue.shared.busy else { toast("Still skipping to a song. Try again in a moment", seconds: 3); return }
        // these songs go into Spotify's own queue, which an Up Next order kept by LyricsBar wouldn't show: reset it
        let dropped = SpotifyQueue.shared.managed
        SpotifyQueue.shared.release()
        toast("Queuing \(name)…" + (dropped ? " (your Up Next order was reset)" : ""), seconds: 6)
        let pid = id.hasSuffix(":collection") ? "spotify:collection" : spotifySafe(id)   // Liked Songs
        libraryJSON(["spotify-queue-playlist", pid]) { [weak self] obj, err in
            guard let self else { return }
            let r = obj as? [String: Any]
            if let n = r?["queued"] as? Int {
                if let e = r?["error"] as? String {          // stopped partway (e.g. rate limited)
                    self.toast("Queued \(n) of \(r?["total"] as? Int ?? n) songs from \(name): \(SpotifyQueue.friendly(e))", seconds: 5)
                } else {
                    self.toast(n == 0 ? "\(name) is empty" : "Queued \(name) (\(n) songs)", seconds: 2.5)
                }
                SpotifyQueue.shared.refresh()
            } else {
                self.toast(SpotifyQueue.friendly(err), seconds: 4)
            }
        }
    }

    func playPlaylist(_ provider: String, _ id: String, _ name: String) {
        closePicker()
        toast("Loading \(name)…", seconds: 3)
        if provider == "spotify" {
            SpotifyQueue.shared.release()                // a kept Up Next order belongs to the music being replaced
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
                guard !songs.isEmpty else { self.toast("\(name) is empty", seconds: 2.5); return }
                playSongs(songs, shuffle: shuffleNow)
            } catch {
                self.toast("Couldn't load \(name): \(error.localizedDescription)", seconds: 4)
            }
        }
    }

    func setMediaMode(_ on: Bool) {
        if on { closePicker(); if stripExpanded { setStripExpanded(false, restore: false) } }
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
            if self.keepControlsWhilePaused { self.bumpMediaTimer(); return }   // set to stay up (paused / playing)
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
        case .keyboard:
            panelIcon.image = symbol("light.min", 14)
            panelSlider.floatValue = KeyboardLight.level
        case .none: break
        }
        volBtn.image = symbol(Sys.volumeSymbol, 14)
    }

    @objc func closePanel() {
        guard panelMode != .none else { return }
        panelMode = .none
        panelTimer?.invalidate()
        show(panel, false)
        if anyStripButton { show(strip, true) }
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
        case .keyboard: KeyboardLight.level = panelSlider.floatValue
        case .none: break
        }
    }

    @objc func panelIconTapped() {
        bumpPanelTimer()
        switch panelMode {
        case .volume: Sys.muted.toggle(); refreshPanel()
        case .brightness: Sys.brightness = 0.05; refreshPanel()
        case .keyboard: KeyboardLight.level = 0; refreshPanel()      // backlight off
        case .none: break
        }
    }

    @objc func openApps() { LibraryWindow.shared.toggle() }
    @objc func openKeyboardLight() { setStripExpanded(false); openPanel(.keyboard) }
    @objc func openSiri() {
        setStripExpanded(false)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Siri.app"))
    }
    /// The screenshot toolbar (same as ⇧⌘5).
    @objc func openScreenshot() {
        setStripExpanded(false)
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app"))
    }
    @objc func regularBar() { setStripExpanded(false); onRegularBar?() }

    /// Extras show only while expanded (‹ / ›); they fold away again after a few seconds.
    var stripButtons: [String: NSView] {
        ["brightness": briBtn, "volume": volBtn, "library": appsBtn, "keyboard": kbdBtn, "siri": siriBtn,
         "screenshot": shotBtn, "regular": regularBtn, "cast": castBtn]
    }
    /// Lays the buttons out in the user's order; "Behind ‹" ones only show while expanded.
    func applyStripButtons() {
        let layout = StripSlot.normalized(cfg.stripLayout)
        let usable = { (s: StripSlot) in s.id != "keyboard" || KeyboardLight.available }
        let extras = cfg.stripExpand != "off" && layout.contains { $0.place == "more" && usable($0) }
        if !extras && stripExpanded { setStripExpanded(false, restore: true) }
        let views: [NSView]
        if cfg.stripExpand == "inline" {
            views = [moreBtn] + layout.compactMap { stripButtons[$0.id] }
        } else {
            // outward: the bar's buttons stay put, extras open to the left of ‹
            let ids = { (p: String) in layout.filter { $0.place == p }.compactMap { self.stripButtons[$0.id] } }
            views = ids("more") + [moreBtn] + ids("bar") + ids("off")
        }
        if strip.stack.arrangedSubviews != views {
            for v in views { strip.stack.removeArrangedSubview(v); v.removeFromSuperview(); strip.stack.addArrangedSubview(v) }
        }
        moreBtn.isHidden = !extras
        moreBtn.image = symbol(stripExpanded ? "chevron.right" : "chevron.left", 13, .bold)
        for s in layout {
            stripButtons[s.id]?.isHidden = !usable(s) || !(s.place == "bar" || (s.place == "more" && stripExpanded))
        }
    }
    @objc func toggleStripExpanded() { setStripExpanded(!stripExpanded) }
    /// Expanding makes room: the media controls / picker step aside and the lyric (or title) moves to the left;
    /// folding back restores what was there.
    var restoreMediaAfterStrip = false
    var pickerParked = false                 // the picker is hidden (not closed) while the strip is expanded
    func setStripExpanded(_ on: Bool, restore: Bool = true) {
        stripTimer?.invalidate()
        if on {
            if !stripExpanded {
                restoreMediaAfterStrip = mediaMode
                if mediaMode { setMediaMode(false) }
                if pickerMode && !pickerParked {
                    // tuck the picker away on whatever page it's on; it comes back when the strip folds
                    pickerParked = true
                    pickerTimer?.invalidate()
                    extras.isHidden = true
                    show(pickerRow, false); show(lyric, true)
                }
            }
            stripTimer = Timer.scheduledTimer(withTimeInterval: max(4, cfg.panelAutoHide), repeats: false) { [weak self] _ in
                self?.autoFoldStrip()
            }
        }
        guard on != stripExpanded else { return }
        let expandStrip = {
            self.stripExpanded = on
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.25; c.allowsImplicitAnimation = true
                self.applyStripButtons()
                self.layoutSubtreeIfNeeded()
            }
        }
        // opening: the text slides to the left edge first, then the buttons open (and the reverse on close),
        // so the text never jumps while the label resizes
        if !on { expandStrip() }
        slideLyricAlignment(left: on)
        if on { expandStrip() }
        if !on {
            if pickerParked {
                pickerParked = false
                if restore && !mediaMode && pickerMode {
                    show(pickerRow, true); show(lyric, false)
                    updateExtras(); bumpPickerTimer()
                } else { closePicker() }
            } else if restore && restoreMediaAfterStrip && !mediaMode && !pickerMode { setMediaMode(true) }
            restoreMediaAfterStrip = false
        }
    }

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
    var npIgnored = false          // Now Playing is a stale paused app (NowPlayingFilter)
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
        signal(SIGPIPE, SIG_IGN)          // a helper that exits before reading stdin must not kill the app
        AudioOutput.watch()
        // Spotify Up Next edits that were waiting for a song's end when LyricsBar quit (once Now Playing is known)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { SpotifyQueue.shared.restore() }
        NotificationCenter.default.addObserver(forName: .lyricsBarToast, object: nil, queue: .main) { [weak self] n in
            if let t = n.object as? String { self?.view.toast(t, seconds: 3) }
        }
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
        tray.view = ControlStripButton(coloredSymbol("music.note", 15, .white), self, #selector(showOnBar))
        view.onRegularBar = { [weak self] in self?.setBarHidden(true) }
        view.peekNext = { [weak self] done in self?.fetchNext(done) ?? done(nil) }
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
            self.updateBackgroundMode()            // switching to album art: use the cover right away
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
                               if c.hasPrefix("seektest") { SeekTest.run(out: home + "/debug.out"); return }
                               if c.hasPrefix("skiptime") {      // skiptime [cold] = time a skip takes to produce audio
                                   StreamPlayer.shared.debugSkipTime(cold: c.contains("cold")) {
                                       try? $0.write(toFile: home + "/debug.out", atomically: true, encoding: .utf8)
                                   }
                                   return
                               }
                               if c.hasPrefix("ppos") {          // ppos = the built-in player's real position (debug.out)
                                   let sp = StreamPlayer.shared
                                   try? String(format: "%.3f %.3f %d", sp.player.currentTime().seconds, Date().timeIntervalSince1970,
                                               sp.player.timeControlStatus.rawValue)
                                       .write(toFile: home + "/debug.out", atomically: true, encoding: .utf8)
                               }
                               if c.hasPrefix("qstate") {
                                   let sp = StreamPlayer.shared
                                   try? "active=\(sp.active) n=\(sp.tracks.count) i=\(sp.index) title=\(sp.tracks.indices.contains(sp.index) ? sp.tracks[sp.index].title : "-") status=\(sp.player.currentItem?.status.rawValue ?? -1) tint=\(String(describing: self.view.likeBtn.contentTintColor)) liked=\(LikedCache.shared.ids.count)".write(toFile: home + "/debug.out", atomically: true, encoding: .utf8)
                               }
                               if c.hasPrefix("toast ") { self.view.toast(String(c.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines), seconds: 3) }
                               if c.hasPrefix("media") { self.view.setMediaMode(true) }
                               if c.trimmingCharacters(in: .whitespacesAndNewlines) == "apps" { self.view.openApps() }
                               // "regular on|off": hand the Touch Bar to macOS / take it back
                               // "playingshows lyrics|controls|title", "buttons on|off" (all optional strip buttons), "kbd"
                               let w = c.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
                               if w.first == "regular", w.count == 2 { self.setBarHidden(w[1] == "on"); return }
                               if w.first == "playingshows", w.count == 2 { ConfigStore.shared.c.playingShows = w[1]; return }
                               if w.first == "buttons", w.count == 2 {
                                   let on = w[1] == "on"
                                   ConfigStore.shared.c.stripLayout = StripSlot.normalized(cfg.stripLayout).map {
                                       ["keyboard", "siri", "screenshot", "regular"].contains($0.id)
                                           ? StripSlot(id: $0.id, place: on ? "more" : "off") : $0 }
                                   return
                               }
                               if w.first == "more" { self.view.toggleStripExpanded(); return }
                               if w.first == "swipe", w.count >= 2, let dx = Double(w[1]) {   // swipe DX [back] = simulated drag
                                   let v = self.view, back = w.count > 2
                                   v.beginSwipe()
                                   for i in 1...20 {
                                       DispatchQueue.main.asyncAfter(deadline: .now() + 0.05 * Double(i)) {
                                           let f = Double(i) / 20, x = back ? dx * (f < 0.5 ? f * 2 : (1 - f) * 2) : dx * f
                                           v.updateSwipe(CGFloat(x))
                                           if i == 20 { v.endSwipe(CGFloat(x)) }
                                       }
                                   }
                                   return
                               }
                               if w.first == "lyricstate" {      // lyricstate = what the lyric line is doing (debug.out)
                                   let v = self.view, l = v.lyric
                                   let info = "hidden=\(l.isHidden) alpha=\(l.alphaValue) text=\(l.stringValue.prefix(40)) key=\(v.lyricKey.debugDescription) frame=\(l.frame) paused=\(v.pausedActive) card=\(v.titleCardUntil) media=\(v.mediaMode) picker=\(v.pickerMode) anims=\(l.layer?.animationKeys() ?? []) transform=\(l.layer?.affineTransform() ?? .identity) mask=\(l.layer?.mask != nil) layerOpacity=\(l.layer?.opacity ?? -1)"
                                   try? info.write(toFile: home + "/debug.out", atomically: true, encoding: .utf8); return
                               }
                               if w.first == "outro" {           // outro = show Up Next now with a sample next song
                                   self.view.showOutro(self.lastTitle, self.lastArtist, next: ("Sample Song", "Sample Artist"))
                                   let v = self.view, o = v.subviews.last
                                   try? "lyric=\(v.lyric.frame) super=\(v.lyric.superview === v) overlay=\(o.map { "\($0.frame) \(type(of: $0))" } ?? "-")"
                                       .write(toFile: home + "/debug.out", atomically: true, encoding: .utf8)
                                   return
                               }
                               if w.first == "kbd" {
                                   try? "keyboard light: available=\(KeyboardLight.available) level=\(KeyboardLight.level)"
                                       .write(toFile: home + "/debug.out", atomically: true, encoding: .utf8)
                                   return
                               }
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
                               if c.hasPrefix("spqpl") {                 // spqpl = list Spotify playlists; spqpl N = hold-queue #N
                                   let arg = c.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                                   Task { @MainActor in
                                       guard case .success(let list) = await loadPlaylists("spotify") else { return }
                                       if let i = Int(arg), list.indices.contains(i) {
                                           libraryJSON(["spotify-queue-playlist", spotifySafe(list[i].id)]) { obj, err in
                                               try? "queued \(list[i].name): \(obj.map { String(describing: $0) } ?? err ?? "?")"
                                                   .write(toFile: home + "/debug.out", atomically: true, encoding: .utf8)
                                           }
                                       } else {
                                           try? list.enumerated().map { "\($0.offset): \($0.element.name) (\($0.element.count))" }
                                               .joined(separator: "\n").write(toFile: home + "/debug.out", atomically: true, encoding: .utf8)
                                       }
                                   }
                                   return
                               }
                               if c.hasPrefix("cast") {                   // opens the Cast list; writes what it shows after 4 s
                                   if c.contains("ax") {                  // "cast ax": is the Accessibility permission there?
                                       try? "accessibility: \(ControlCenterSound.trusted)".write(toFile: home + "/debug.out", atomically: true, encoding: .utf8)
                                       return
                                   }
                                   if c.contains("cc") {                  // "cast cc": Control Center's sound list, whatever is playing
                                       ControlCenterSound.open { ok in
                                           try? "control center: \(ok)".write(toFile: home + "/debug.out", atomically: true, encoding: .utf8)
                                       }
                                       return
                                   }
                                   if c.contains("self") {                // "cast self": move playback to the device it's already on
                                       libraryJSON(["spotify-devices"]) { obj, err in
                                           guard let id = (obj as? [[String: Any]])?.first(where: { $0["active"] as? Bool == true })?["id"] as? String else {
                                               try? "no active device: \(err ?? "-")".write(toFile: home + "/debug.out", atomically: true, encoding: .utf8); return
                                           }
                                           libraryJSON(["spotify-transfer", id]) { _, err in
                                               try? "transfer: \(err ?? "ok")".write(toFile: home + "/debug.out", atomically: true, encoding: .utf8)
                                           }
                                       }
                                       return
                                   }
                                   self.view.openCast()
                                   DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                       let lines = self.view.picker.items.map { ($0.action == nil ? "- " : "> ") + $0.title }
                                       try? (["picker: \(self.view.pickerMode)", "accessibility: \(ControlCenterSound.trusted)"] + lines).joined(separator: "\n")
                                           .write(toFile: home + "/debug.out", atomically: true, encoding: .utf8)
                                   }
                                   return
                               }
                               if c.hasPrefix("spq") {                    // Spotify queue: spq [skip N (= play entry N) | remove N | move A B]
                                   let q = SpotifyQueue.shared
                                   let w = c.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").map(String.init)
                                   let dump: (String?) -> Void = { err in
                                       q.refresh {
                                           let lines = q.items.enumerated().map { "\($0.offset): \($0.element.title) — \($0.element.artist)  [\($0.element.uri)]" }
                                           try? (["action error: \(err ?? "none")", "queue error: \(q.error ?? "none")", q.debugState] + lines)
                                               .joined(separator: "\n").write(toFile: home + "/debug.out", atomically: true, encoding: .utf8)
                                       }
                                   }
                                   let n = w.count > 1 ? Int(w[2 < w.count ? 2 : 1].trimmingCharacters(in: .whitespacesAndNewlines)) : nil
                                   q.refresh {
                                       let items = q.items
                                       switch w.count > 1 ? w[1] : "" {
                                       case "state": dump(nil)
                                       case "next": _ = transport(.next); DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dump(nil) }
                                       case "skip": if let n, items.indices.contains(n) { q.jump(id: items[n].id) { e in DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dump(e) } } }
                                       case "clear": q.clear { e in DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dump(e) } }
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

    /// Re-shows LyricsBar's bar (it can be pushed aside by the system); does nothing while switched off.
    @objc func present() {
        guard !cfg.barHidden else { return }
        presentSystemModal(bar, trayId: trayId.rawValue)
        // while off the Touch Bar the view had no room and the lyric collapsed to nothing; lay it out again
        for d in [0.05, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) { [weak self] in self?.view.relayoutLyric() }
        }
    }
    @objc func showOnBar() { setBarHidden(false) }
    @objc func toggleBarHidden() { setBarHidden(!cfg.barHidden) }
    /// Hand the Touch Bar back to macOS (the ♪ stays in the Control Strip to come back), or take it again.
    func setBarHidden(_ hidden: Bool) {
        if cfg.barHidden != hidden { ConfigStore.shared.c.barHidden = hidden }
        if hidden {
            view.closePicker(); if view.mediaMode { view.setMediaMode(false) }
            dismissSystemModal(bar)
            dfrSetControlStripPresence(trayId.rawValue, true)   // keep the ♪ in the Control Strip
        } else {
            present()
        }
        if let s = statusItem { NSStatusBar.system.removeStatusItem(s); statusItem = nil }
        updateStatusItem()        // menu title follows the state
    }

    func updateStatusItem() {
        if !cfg.showMenuBarIcon { if let s = statusItem { NSStatusBar.system.removeStatusItem(s) }; statusItem = nil; return }
        guard statusItem == nil else { return }
        let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        s.button?.image = symbol("music.note", 14, .medium)
        s.button?.image?.isTemplate = true
        let m = NSMenu()
        m.addItem(withTitle: "Library…", action: #selector(openLibrary), keyEquivalent: "l").target = self
        m.addItem(withTitle: cfg.barHidden ? "Show LyricsBar on the Touch Bar" : "Use the Regular Touch Bar",
                  action: #selector(toggleBarHidden), keyEquivalent: "").target = self
        // only offer the switch when the other version is actually installed
        let other = NSHomeDirectory() + "/Applications/" + (isBeta ? "LyricsBar.app" : "LyricsBar Beta.app")
        if FileManager.default.fileExists(atPath: other) {
            m.addItem(withTitle: isBeta ? "Switch to Stable Version" : "Switch to Beta Version",
                      action: #selector(switchVersion), keyEquivalent: "").target = self
        }
        m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        m.addItem(withTitle: "Playlists…", action: #selector(openPlaylists), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Restart LyricsBar", action: #selector(restart), keyEquivalent: "").target = self
        s.menu = m
        statusItem = s
    }
    /// The LaunchAgent runs ~/.touchbar-lyrics/active.app, a link to ~/Applications/LyricsBar.app (stable)
    /// or ~/Applications/LyricsBar Beta.app.
    var isBeta: Bool { Bundle.main.bundleURL.resolvingSymlinksInPath().lastPathComponent.contains("Beta") }
    @objc func switchVersion() {
        let target = NSHomeDirectory() + "/Applications/" + (isBeta ? "LyricsBar.app" : "LyricsBar Beta.app")
        guard FileManager.default.fileExists(atPath: target) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ln")
        p.arguments = ["-sfn", target, home + "/active.app"]
        try? p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { return }
        StreamPlayer.shared.save()
        exit(0)      // launchd (KeepAlive) relaunches through the link → the other version
    }

    @objc func openLibrary() { LibraryWindow.shared.show() }
    @objc func openSettings() { SettingsWindow.shared.show(.general) }
    @objc func openPlaylists() { LibraryWindow.shared.show(.playlists) }
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
                // a newer background was asked for meanwhile (e.g. the wallpaper's slower blur finishing after
                // the album art's): don't let this one land on top of it
                guard self.wallpaperKey == key else { return }
                let t = CATransition(); t.type = .fade; t.duration = 0.6
                self.view.bg.layer?.add(t, forKey: "bg")
                self.view.bg.image = img
            }
        }
    }

    func tick() {
        DiscordPresence.shared.tick()
        if let d = FileManager.default.contents(atPath: home + "/state.json"), d != lastState,
           let raw = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            lastState = d
            npIgnored = NowPlayingFilter.ignored(raw)
            let j: [String: Any] = npIgnored ? [:] : raw         // a stale paused app: as if nothing were playing
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
            view.currentArtist = lastArtist
            let sp = StreamPlayer.shared
            if (j["playing"] as? Bool ?? false), (j["bundle"] as? String ?? "") != Bundle.main.bundleIdentifier,
               sp.isPlaying, Date().timeIntervalSince(sp.startedAt) > 3 {
                sp.pause()   // another player took over
            }
        }
        useOwnPlayerFallback()
        if !npIgnored, let s = try? String(contentsOfFile: home + "/current.txt", encoding: .utf8) {
            let line = s.trimmingCharacters(in: .whitespacesAndNewlines)
            // no lyrics: lyricsd writes "♪ Title — Artist"; keep the title display instead
            let noLyrics = "♪ \(lastTitle) — \(lastArtist)".trimmingCharacters(in: .whitespacesAndNewlines)
            if !lastTitle.isEmpty && line == noLyrics { view.showTitleLine(lastTitle, lastArtist) }
            else { view.setLyric(line) }
        }
        view.updateScrubber()
        let artPath = home + "/artwork.jpg"
        let m = (try? FileManager.default.attributesOfItem(atPath: artPath)[.modificationDate]) as? Date
        if m != lastArtMtime, !npIgnored {
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
        followSpotifyQueue()
        view.updateProgress()
        driveVisualizer()
        checkOutro()
    }

    // MARK: while paused

    var pausedSince: Date?
    var controlsOpenedForPause = false
    /// What the lyric area shows instead of lyrics: while paused (`pausedShows`, after a delay) or while
    /// playing (`playingShows`).
    func updatePausedScreen() {
        let playing = view.isPlaying && !lastTitle.isEmpty
        let mode = playing ? cfg.playingShows : cfg.pausedShows
        let paused = !view.isPlaying && !lastTitle.isEmpty
        if !paused { pausedSince = nil } else if pausedSince == nil { pausedSince = Date() }
        let since = pausedSince.map { Date().timeIntervalSince($0) } ?? 0
        let active = mode != "lyrics" && (playing || (paused && since >= cfg.pausedDelay))
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
        // switching away from "Media controls": close the controls that mode opened, right away
        if controlsOpenedForPause { controlsOpenedForPause = false; if view.mediaMode { view.setMediaMode(false) } }
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

    /// While Spotify's Up Next is open on the bar, reload it when the song changes and every few seconds.
    var spotifyQueueCheck = Date.distantPast
    var spotifyQueueTitle = ""
    func followSpotifyQueue() {
        guard view.pickerMode, view.showingUpNext, view.stripIsSpotify, !view.queueStrip.isHolding,
              !SpotifyQueue.shared.busy else { return }
        let changed = lastTitle != spotifyQueueTitle
        guard changed || Date().timeIntervalSince(spotifyQueueCheck) > 6 else { return }
        spotifyQueueTitle = lastTitle; spotifyQueueCheck = Date()
        // a song change takes Spotify a moment to reflect in its queue
        DispatchQueue.main.asyncAfter(deadline: .now() + (changed ? 1.0 : 0)) { SpotifyQueue.shared.refresh() }
    }

    func checkOutro() {
        let window = cfg.outroSeconds
        guard window > 0, view.duration > 20, !lastTitle.isEmpty else { return }
        let remaining = view.duration - view.position
        if view.isPlaying, remaining <= window, remaining > 0.3, outroFor != lastTitle,
           !view.swipeDragging, !view.swipeSettling {
            outroFor = lastTitle
            let title = lastTitle, artist = lastArtist
            fetchNext { [weak self] next in
                guard let self, self.lastTitle == title, self.outroFor == title else { return }
                if self.view.swipeDragging { self.outroFor = ""; return }     // try again after the drag
                self.view.showOutro(title, artist, next: next)
            }
        } else if remaining > window + 2, !outroFor.isEmpty {
            view.cancelOutro(); outroFor = ""       // seeked back (or restarted): the end gets its Up Next again
        }
    }

    /// Title/artist of the song after this one, for whichever player is active.
    func fetchNext(_ done: @escaping ((String, String)?) -> Void) {
        let sp = StreamPlayer.shared
        if view.bundleId == Bundle.main.bundleIdentifier, sp.active {
            let i = sp.index + 1
            done(sp.tracks.indices.contains(i) ? (sp.tracks[i].title, sp.tracks[i].artist) : nil)
        } else if view.bundleId == "com.spotify.client", SpotifyQueue.shared.managed {
            done(SpotifyQueue.shared.managedNext)            // LyricsBar's own order
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
