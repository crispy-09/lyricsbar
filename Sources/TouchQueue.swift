// Touch Bar widgets: an editable Up Next strip (tap to play, hold + drag to reorder, drop on 🗑 to remove)
// and a lyric label you can swipe to skip songs.
import AppKit

final class QueueStrip: NSView {
    struct Entry { let title: String; let sub: String; var uid: UUID? = nil }
    /// Setting this rebuilds the pills; reordering while dragging only moves existing layers.
    var entries: [Entry] { get { items } set { items = newValue; rebuild() } }
    var onTap: ((Entry) -> Void)?
    var onMove: (() -> Void)?                   // order changed; read `entries`
    var onRemove: ((Entry) -> Void)?
    var onLift: ((Bool) -> Void)?              // picked up / dropped
    var onTrashHover: ((Bool) -> Void)?
    var onInteract: (() -> Void)?
    /// Swipe right again at the start of the list to reveal a Clear pill; tapping it calls this.
    var onClear: (() -> Void)?
    weak var trash: NSView?
    var isHolding: Bool { lifted != nil }

    private var items: [Entry] = []
    private var pills: [CALayer] = []          // one pre-rendered layer per song, moved by the GPU
    private let content = CALayer()
    private let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    private let subFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    private let spacing: CGFloat = 8, pillH: CGFloat = 30
    private var widths: [CGFloat] = [], xs: [CGFloat] = []
    private var contentW: CGFloat = 0
    private var offset: CGFloat = 0

    private var startX: CGFloat = 0, startOffset: CGFloat = 0, startTime = Date()
    private var moved = false
    private var holdTimer: Timer?
    // one display-synced link drives both edge auto-scroll (while holding) and fling momentum
    private var link: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var coastV: CGFloat = 0          // pt/s, momentum after a fling
    private var lifted: Int?
    private var liftOrigin = 0
    private var grabDX: CGFloat = 0
    private var fingerX: CGFloat = 0
    private var overTrash = false {
        didSet { if overTrash != oldValue { onTrashHover?(overTrash); styleLifted() } }
    }
    private var velocity: CGFloat = 0, lastSample: (x: CGFloat, t: TimeInterval) = (0, 0)
    // pull-to-reveal Clear
    private let clearW: CGFloat = 62
    private var maxPull: CGFloat { clearW + spacing }
    private var pull: CGFloat = 0
    private var pullStart: CGFloat = 0
    private var pulling = false
    private var revealed: Bool { pull >= maxPull - 0.5 }
    private let clearLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.direct]
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = 8          // clipped edges get the same rounding as the pills
        layer?.addSublayer(content)
        clearLayer.anchorPoint = .zero
        clearLayer.opacity = 0
        layer?.addSublayer(clearLayer)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 30) }
    override var isFlipped: Bool { false }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func render(_ e: Entry, width w: CGFloat) -> CGImage? {
        let s = scale
        let img = NSImage(size: NSSize(width: w, height: pillH), flipped: false) { r in
            NSColor.white.withAlphaComponent(cfg.buttonStyle == "pill" ? 0.14 : 0).setFill()   // minimal: text only
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            // title on top, artist smaller underneath, both centred
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail; para.alignment = .center
            let t = NSAttributedString(string: e.title, attributes: [.font: self.font, .foregroundColor: NSColor.white, .paragraphStyle: para])
            let a = NSAttributedString(string: e.sub, attributes: [.font: self.subFont,
                .foregroundColor: NSColor.white.withAlphaComponent(0.6), .paragraphStyle: para])
            let th = ceil(self.font.ascender - self.font.descender), ah = e.sub.isEmpty ? 0 : ceil(self.subFont.ascender - self.subFont.descender)
            let gap: CGFloat = e.sub.isEmpty ? 0 : -1
            let total = th + ah + gap
            let y0 = (r.height - total) / 2
            let box = { (y: CGFloat, h: CGFloat) in NSRect(x: 12, y: y, width: r.width - 24, height: h) }
            if !e.sub.isEmpty { a.draw(with: box(y0, ah), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]) }
            t.draw(with: box(y0 + ah + gap, th), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return true
        }
        var rect = NSRect(x: 0, y: 0, width: w * s, height: pillH * s)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func measure(_ e: Entry) -> CGFloat {
        let w = max((e.title as NSString).size(withAttributes: [.font: font]).width,
                    (e.sub as NSString).size(withAttributes: [.font: subFont]).width)
        return max(70, min(200, ceil(w) + 26))
    }

    private func rebuild() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        pills.forEach { $0.removeFromSuperlayer() }
        widths = items.map(measure)
        pills = zip(items, widths).map { e, w in
            let l = CALayer()
            l.contentsScale = scale
            l.contents = render(e, width: w)
            l.bounds = CGRect(x: 0, y: 0, width: w, height: pillH)
            l.anchorPoint = .zero
            content.addSublayer(l)
            return l
        }
        lifted = nil
        clearLayer.contentsScale = scale
        clearLayer.contents = renderClear()
        clearLayer.bounds = CGRect(x: 0, y: 0, width: clearW, height: pillH)
        setPull(items.isEmpty ? 0 : pull, animated: false)   // a refresh keeps a revealed (or half-pulled) Clear
        place(animated: false)
        CATransaction.commit()
    }

    private func renderClear() -> CGImage? {
        let s = scale
        let img = NSImage(size: NSSize(width: clearW, height: pillH), flipped: false) { r in
            NSColor.systemRed.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
            let para = NSMutableParagraphStyle(); para.alignment = .center
            let t = NSAttributedString(string: "Clear", attributes: [.font: self.font, .foregroundColor: NSColor.white, .paragraphStyle: para])
            let h = ceil(self.font.ascender - self.font.descender)
            t.draw(with: NSRect(x: 0, y: (r.height - h) / 2, width: r.width, height: h), options: .usesLineFragmentOrigin)
            return true
        }
        var rect = NSRect(x: 0, y: 0, width: clearW * s, height: pillH * s)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// Slides the list right by `p` and the Clear pill in from the left edge.
    private func setPull(_ p: CGFloat, animated: Bool) {
        pull = max(0, min(maxPull, p))
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.2)
        clearLayer.position = CGPoint(x: pull - maxPull, y: (bounds.height - pillH) / 2)
        clearLayer.opacity = Float(pull / maxPull)
        content.frame = CGRect(x: -offset + pull, y: 0, width: max(contentW, bounds.width), height: bounds.height)
        CATransaction.commit()
    }

    /// Compute slot positions and move every non-held pill to its slot.
    private func place(animated: Bool) {
        xs = []; var x: CGFloat = 0
        for w in widths { xs.append(x); x += w + spacing }
        contentW = max(0, x - spacing)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.18)
        let y = (bounds.height - pillH) / 2
        for (i, l) in pills.enumerated() where i != lifted { l.position = CGPoint(x: xs[i], y: y) }
        CATransaction.commit()
        setOffset(offset)
    }

    private func clamp(_ o: CGFloat) -> CGFloat { max(0, min(max(0, contentW - bounds.width), o)) }
    private func setOffset(_ o: CGFloat) {
        offset = clamp(o)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        content.frame = CGRect(x: -offset + pull, y: 0, width: max(contentW, bounds.width), height: bounds.height)
        if let l = lifted { pills[l].position = CGPoint(x: fingerX - grabDX + offset - 3, y: (bounds.height - pillH) / 2 - 1) }
        CATransaction.commit()
    }
    override func layout() { super.layout(); place(animated: false) }

    private func index(at x: CGFloat) -> Int? {
        let cx = x - pull + offset
        return xs.indices.first { cx >= xs[$0] && cx <= xs[$0] + widths[$0] }
    }

    private func styleLifted() {
        guard let l = lifted else { return }
        CATransaction.begin(); CATransaction.setAnimationDuration(0.12)
        let p = pills[l]
        p.backgroundColor = (overTrash ? NSColor.systemRed.withAlphaComponent(0.55) : NSColor.white.withAlphaComponent(0.2)).cgColor
        p.opacity = overTrash ? 0.85 : 1
        CATransaction.commit()
    }

    // MARK: touches

    override func touchesBegan(with event: NSEvent) {
        guard let t = event.touches(matching: .began, in: self).first else { return }
        stopTick()
        startX = t.location(in: self).x; fingerX = startX
        startOffset = offset; startTime = Date(); moved = false
        pullStart = pull; pulling = false
        lastSample = (startX, ProcessInfo.processInfo.systemUptime); velocity = 0
        onInteract?()
        holdTimer?.invalidate()
        let h = Timer(timeInterval: 0.45, repeats: false) { [weak self] _ in self?.pickUp() }
        RunLoop.main.add(h, forMode: .common)
        holdTimer = h
    }

    private func pickUp() {
        guard !moved, startX >= pull, let i = index(at: startX) else { return }
        lifted = i; liftOrigin = i
        grabDX = startX - pull - (xs[i] - offset)   // the finger's spot on the pill once Clear tucks away
        if pull > 0 { setPull(0, animated: true) }
        let p = pills[i]
        p.cornerRadius = 8
        p.zPosition = 10
        CATransaction.begin(); CATransaction.setAnimationDuration(0.15)
        p.setAffineTransform(CGAffineTransform(scaleX: 1.04, y: 1.04))
        CATransaction.commit()
        styleLifted()
        onLift?(true)
        startTick()
    }

    override func touchesMoved(with event: NSEvent) {
        guard let t = event.touches(matching: .moved, in: self).first else { return }
        let x = t.location(in: self).x
        fingerX = x
        if lifted != nil {
            onInteract?()
            if let tr = trash { overTrash = tr.bounds.insetBy(dx: -8, dy: -20).contains(t.location(in: tr)) }
            reorder()
            setOffset(offset)
            return
        }
        if !moved && abs(x - startX) > 6 {
            moved = true; holdTimer?.invalidate(); onInteract?()
            // at the start of the list, a swipe right (or any swipe while Clear shows) moves the Clear pill
            pulling = onClear != nil && !items.isEmpty && startOffset <= 0.5 && (x > startX || pullStart > 0)
        }
        if moved && pulling {
            let dx = x - startX
            setPull(pullStart + (dx > 0 ? dx * 0.6 : dx), animated: false)
            return
        }
        if moved {
            setOffset(startOffset - (x - startX))
            let now = ProcessInfo.processInfo.systemUptime
            let dt = now - lastSample.t
            if dt > 0.008 { velocity = 0.6 * (x - lastSample.x) / CGFloat(dt) + 0.4 * velocity; lastSample = (x, now) }
        }
    }

    override func touchesEnded(with event: NSEvent) { finish(cancelled: false) }
    override func touchesCancelled(with event: NSEvent) { finish(cancelled: true) }

    private func finish(cancelled: Bool) {
        holdTimer?.invalidate()
        stopTick()
        onInteract?()
        if pulling {
            pulling = false
            setPull(pull > maxPull * 0.55 && !cancelled ? maxPull : 0, animated: true)
            return
        }
        if pull > 0 && !moved && !cancelled && lifted == nil {
            if startX < pull { setPull(0, animated: true); onClear?(); return }   // tapped Clear
            setPull(0, animated: true); return                                   // tapped elsewhere: tuck it away
        }
        if let l = lifted {
            let p = pills[l]
            let trashIt = overTrash && !cancelled
            lifted = nil
            overTrash = false
            onLift?(false)
            if trashIt {
                p.removeFromSuperlayer()
                pills.remove(at: l); widths.remove(at: l)
                let gone = items.remove(at: l)
                onRemove?(gone)
            } else {
                CATransaction.begin(); CATransaction.setAnimationDuration(0.15)
                p.setAffineTransform(.identity); p.backgroundColor = nil; p.opacity = 1; p.zPosition = 0
                CATransaction.commit()
                if l != liftOrigin { onMove?() }
            }
            place(animated: true)
            return
        }
        if !moved && !cancelled && Date().timeIntervalSince(startTime) < 0.45, let i = index(at: startX) {
            onTap?(items[i]); return
        }
        // finger rested before lifting → no fling
        if ProcessInfo.processInfo.systemUptime - lastSample.t > 0.08 { velocity = 0 }
        if moved && abs(velocity) > 80 { coast() }
    }

    /// Swap the held song with a neighbour once it passes the neighbour's middle; neighbours glide over.
    private func reorder() {
        guard var l = lifted else { return }
        let left = fingerX - grabDX + offset
        var changed = false
        while l + 1 < items.count, left + widths[l] > xs[l + 1] + widths[l + 1] / 2 {
            swap(l, l + 1); l += 1; changed = true; lifted = l; recalcXs()
        }
        while l > 0, left < xs[l - 1] + widths[l - 1] / 2 {
            swap(l, l - 1); l -= 1; changed = true; lifted = l; recalcXs()
        }
        if changed { place(animated: true) }
    }
    private func swap(_ a: Int, _ b: Int) { items.swapAt(a, b); pills.swapAt(a, b); widths.swapAt(a, b) }
    private func recalcXs() { xs = []; var x: CGFloat = 0; for w in widths { xs.append(x); x += w + spacing } }

    private func startLink() {
        if link == nil {
            let l = displayLink(target: self, selector: #selector(frame(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        lastFrame = CACurrentMediaTime()
    }
    private func stopTick() { link?.invalidate(); link = nil; coastV = 0 }
    private func startTick() { coastV = 0; startLink() }
    private func coast() { coastV = -velocity; startLink() }

    @objc private func frame(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(0.05, max(0.001, now - lastFrame)))
        lastFrame = now
        if lifted != nil {
            // auto-scroll when the held song nears an edge (~300 pt/s)
            var d: CGFloat = 0
            if fingerX > 0 && fingerX < 36 { d = -300 }
            if fingerX > bounds.width - 36 { d = 300 }
            if d != 0 { setOffset(offset + d * dt); reorder() }
            return
        }
        guard coastV != 0 else { stopTick(); return }
        let before = offset
        setOffset(offset + coastV * dt)
        coastV *= pow(0.015, dt)              // frame-rate independent friction (~same feel as before at 60 Hz)
        if abs(coastV) < 15 || offset == before { stopTick() }
    }
}

/// The lyric line itself (touches are handled by LyricTouchArea, which covers the whole lyric region).
final class SwipeLabel: NSTextField {
    // let touches on the text fall through to the LyricTouchArea underneath
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
}

/// Covers the free middle of the bar: swipe left/right = next/previous, tap and long-press = configurable.
/// Moves `label` with the finger for feedback. Ignores touches while the label is hidden (menus open).
final class LyricTouchArea: NSView {
    weak var label: NSView?
    var onTap: (() -> Void)?
    var onLongPress: (() -> Void)?
    // horizontal drags: the owner moves the text (and a preview of the next/previous song) and decides on release
    var onDragBegan: (() -> Void)?
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnded: ((CGFloat) -> Void)?
    private var startX: CGFloat?
    private var startTime = Date()
    private var held = false
    private var dragging = false
    private var holdTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.direct]
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ p: NSPoint) -> NSView? {
        guard let l = label, !l.isHidden, l.alphaValue > 0.05 else { return nil }
        return super.hitTest(p)
    }

    override func touchesBegan(with event: NSEvent) {
        guard let t = event.touches(matching: .began, in: self).first else { return }
        startX = t.location(in: self).x; startTime = Date(); held = false; dragging = false
        holdTimer?.invalidate()
        let h = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self, self.startX != nil, !self.dragging else { return }
            self.held = true
            self.onLongPress?()
        }
        RunLoop.main.add(h, forMode: .common)
        holdTimer = h
    }
    override func touchesMoved(with event: NSEvent) {
        guard let s = startX, !held, let t = event.touches(matching: .moved, in: self).first else { return }
        let dx = t.location(in: self).x - s
        if !dragging && abs(dx) > 10 { dragging = true; holdTimer?.invalidate(); onDragBegan?() }
        if dragging { onDrag?(dx) }
    }
    override func touchesEnded(with event: NSEvent) {
        holdTimer?.invalidate()
        guard let s = startX else { return }
        startX = nil
        if held { return }                      // the hold's action owns the label now (it may be fading out)
        let x = event.touches(matching: .ended, in: self).first?.location(in: self).x ?? s
        if dragging { dragging = false; onDragEnded?(x - s); return }
        if abs(x - s) < 10 && Date().timeIntervalSince(startTime) < 0.5 { onTap?() }
    }
    override func touchesCancelled(with event: NSEvent) {
        holdTimer?.invalidate()
        startX = nil
        if dragging { dragging = false; onDragEnded?(0) }   // back where it was
    }
}

/// Transparent layer over an icon button: tap = the button's action, horizontal slide = adjust a value.
final class SlideOverlay: NSView {
    var onTap: (() -> Void)?
    var onSlide: ((Float) -> Void)?      // change as a fraction of the full range
    var onEnd: (() -> Void)?
    private var startX: CGFloat = 0, lastX: CGFloat = 0
    private var sliding = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.direct]
    }
    required init?(coder: NSCoder) { fatalError() }

    override func touchesBegan(with event: NSEvent) {
        guard let t = event.touches(matching: .began, in: self).first else { return }
        startX = t.location(in: self).x; lastX = startX; sliding = false
        superview?.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        superview?.layer?.cornerRadius = 7
    }
    override func touchesMoved(with event: NSEvent) {
        guard let t = event.touches(matching: .moved, in: self).first else { return }
        let x = t.location(in: self).x
        if !sliding && abs(x - startX) > 8 { sliding = true }
        if sliding { onSlide?(Float((x - lastX) / 160)) }     // ~160pt of travel = full range
        lastX = x
    }
    override func touchesEnded(with event: NSEvent) {
        superview?.layer?.backgroundColor = NSColor.clear.cgColor
        sliding ? onEnd?() : onTap?()
    }
    override func touchesCancelled(with event: NSEvent) {
        superview?.layer?.backgroundColor = NSColor.clear.cgColor
        if sliding { onEnd?() }
    }
}
