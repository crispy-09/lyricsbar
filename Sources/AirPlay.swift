// The Cast button for LyricsBar's own player: Apple's AirPlay menu, opened on screen at the mouse pointer.
// macOS has no public way to list AirPlay speakers or pick one in code, and a menu can't open on the Touch
// Bar, so this holds Apple's route picker button in an invisible window and clicks it.

import AVKit

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
