// The Cast button for LyricsBar's own player: Apple's AirPlay menu, opened on screen at the mouse pointer.
// macOS has no public way to list AirPlay speakers or pick one in code, and a menu can't open on the Touch
// Bar, so this holds Apple's route picker button in an invisible window and clicks it.

import AVKit
import ApplicationServices
import CoreAudio

final class AirPlayMenu: NSObject, AVRoutePickerViewDelegate {
    static let shared = AirPlayMenu()
    private var window: NSWindow?

    /// False if the menu couldn't be opened.
    @discardableResult func show() -> Bool {
        close()
        let m = NSEvent.mouseLocation
        let w = NSWindow(contentRect: NSRect(x: m.x - 14, y: m.y - 14, width: 28, height: 28), styleMask: .borderless,
                         backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.level = .popUpMenu
        w.isReleasedWhenClosed = false
        let picker = AVRoutePickerView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        picker.player = StreamPlayer.shared.player
        picker.delegate = self
        picker.alphaValue = 0.02                      // there to be clicked, not seen
        w.contentView = picker
        func button(_ v: NSView) -> NSButton? { (v as? NSButton) ?? v.subviews.lazy.compactMap(button).first }
        guard let b = button(picker) else { return false }
        window = w
        w.orderFrontRegardless()
        DispatchQueue.main.async { b.performClick(nil) }
        // if the menu never reports closing, don't leave the window behind
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self, weak w] in if self?.window === w { self?.close() } }
        return true
    }
    func close() { window?.orderOut(nil); window = nil }
    func routePickerViewDidEndPresentingRoutes(_ v: AVRoutePickerView) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.close() }
    }
}

/// Control Center's sound output list (speakers, headphones, AirPlay), opened by pressing its controls through
/// Accessibility: the Sound item in the menu bar if it's there, otherwise Control Center and then its AirPlay
/// button. Needs the Accessibility permission. What's picked there carries all of the Mac's sound.
enum ControlCenterSound {
    static var trusted: Bool { AXIsProcessTrusted() }
    /// Shows the system's "allow in Accessibility" dialog, once per launch.
    private static var asked = false
    static func askPermission() {
        guard !asked else { return }                 // once per launch: the dialog on every press is a nuisance
        asked = true
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    /// First element with one of these identifiers, at most `depth` levels down.
    private static func find(_ ids: [String], in e: AXUIElement, depth: Int) -> AXUIElement? {
        if let id = attr(e, "AXIdentifier") as? String, ids.contains(id) { return e }
        guard depth > 0 else { return nil }
        for k in attr(e, "AXChildren") as? [AXUIElement] ?? [] {
            if let hit = find(ids, in: k, depth: depth - 1) { return hit }
        }
        return nil
    }
    private static func app(_ bundle: String) -> AXUIElement? {
        guard let p = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return nil }
        let e = AXUIElementCreateApplication(p.processIdentifier)
        AXUIElementSetMessagingTimeout(e, 2)
        return e
    }
    private static func windows(_ bundle: String) -> [AXUIElement] {
        app(bundle).flatMap { attr($0, "AXWindows") as? [AXUIElement] } ?? []
    }
    private static func press(_ e: AXUIElement) -> Bool { AXUIElementPerformAction(e, "AXPress" as CFString) == .success }

    /// `done(true)` once the list is open.
    static func open(_ done: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let finish = { (ok: Bool) in DispatchQueue.main.async { done(ok) } }
            // the menu bar's items belong to MenuBarAgent on newer macOS, to Control Center itself before
            func item(_ id: String) -> AXUIElement? {
                for b in ["com.apple.MenuBarAgent", "com.apple.controlcenter"] {
                    for w in windows(b) { if let e = find([id], in: w, depth: 4) { return e } }
                    if let a = app(b), let bar = attr(a, "AXExtrasMenuBar"), let e = find([id], in: bar as! AXUIElement, depth: 3) { return e }
                }
                return nil
            }
            if let sound = item("com.apple.menuextra.sound") { finish(press(sound)); return }
            guard let cc = item("com.apple.menuextra.controlcenter") else { finish(false); return }
            // already open: on Control Center's first page go on to the sound list. On the sound list a second
            // press of Cast closes it: the menu bar item only steps back to the first page, so press it twice
            let airplay = { windows("com.apple.controlcenter").lazy.compactMap { find(["controlcenter-airplay"], in: $0, depth: 5) }.first }
            if !windows("com.apple.controlcenter").isEmpty {
                if let b = airplay() { finish(press(b)); return }
                _ = press(cc)
                for _ in 0..<15 {
                    Thread.sleep(forTimeInterval: 0.1)
                    if windows("com.apple.controlcenter").isEmpty { finish(true); return }
                    if airplay() != nil { finish(press(cc)); return }
                }
                finish(true); return
            }
            guard press(cc) else { finish(false); return }
            for _ in 0..<20 {                                   // Control Center takes a moment to draw
                Thread.sleep(forTimeInterval: 0.1)
                for w in windows("com.apple.controlcenter") {
                    if let b = find(["controlcenter-airplay"], in: w, depth: 5) { finish(press(b)); return }
                }
            }
            finish(true)                                        // Control Center is open; its Sound row is one tap away
        }
    }
}

/// Is the music going to an AirPlay speaker? Those play about a second late and don't report the delay, so
/// lyrics are held back by `airplayLyricDelay` while this is true. The lyrics daemon reads it from output.json.
enum AudioOutput {
    private(set) static var airplay = false
    static var lyricDelay: Double { airplay ? max(0, ConfigStore.shared.c.airplayLyricDelay) : 0 }

    /// The Mac's sound output is an AirPlay device (picked in Control Center or the Sound menu).
    static var systemAirPlay: Bool {
        var t: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                           mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(Sys.outputDevice, &a, 0, nil, &size, &t) == noErr else { return false }
        return t == kAudioDeviceTransportTypeAirPlay
    }
    private static var timer: Timer?
    static func watch() {
        check(force: true)
        // polled: covers the system output and a speaker picked for LyricsBar's own player alone (AirPlayMenu)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in check(force: false) }
    }
    private static func check(force: Bool) {
        let sp = StreamPlayer.shared
        let now = systemAirPlay || (sp.isPlaying && sp.player.isExternalPlaybackActive)
        guard force || now != airplay else { return }
        airplay = now
        if let d = try? JSONSerialization.data(withJSONObject: ["airplay": now]) {
            try? d.write(to: URL(fileURLWithPath: home + "/output.json"), options: .atomic)
        }
    }
}
