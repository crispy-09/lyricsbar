// Audio visualizer: listens to the music at its source, runs an FFT and exposes smoothed band levels;
// VisualizerView draws them as bars.
//  • LyricsBar's own player: samples come straight from the stream (MTAudioProcessingTap) — no recording at all.
//  • Another app (Spotify, Music…): a Core Audio process tap on just that app's processes.
//  • Only if the app's audio process can't be found: the whole system output, as before.
import AppKit
import AVFoundation
import MediaToolbox
import CoreAudio
import AudioToolbox
import Accelerate
import QuartzCore

final class AudioTap {
    static let shared = AudioTap()
    static let bands = 32

    private(set) var running = false
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "lyricsbar.audiotap", qos: .userInteractive)
    private let lock = NSLock()
    private var _levels = [Float](repeating: 0, count: AudioTap.bands)
    private var sampleRate: Double = 48000
    private var lastError = ""
    var debugError: String { lastError }
    private(set) var framesSeen = 0

    // FFT state (touched only on `queue`)
    private let n = 2048
    private lazy var log2n = vDSP_Length(log2(Double(n)))
    private lazy var setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
    private lazy var window: [Float] = {
        var w = [Float](repeating: 0, count: n)
        vDSP_hann_window(&w, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        return w
    }()
    private var ring = [Float]()
    private var bandEdges: [Int] = []
    private var agcPeak: Float = 40   // running loudness reference (dB), so quiet and loud songs both move

    var levels: [Float] { lock.lock(); defer { lock.unlock() }; return _levels }
    var sensitivity: Float = 1

    enum Source: Equatable { case own, app(String) }
    private(set) var source: Source?
    private(set) var tappedProcesses = 0       // 0 = whole system
    var debugSource: String {
        switch source {
        case .own?: return "own stream (no recording) frames=\(framesSeen)"
        case .app(let b)?: return tappedProcesses > 0 ? "app \(b): \(tappedProcesses) process(es) frames=\(framesSeen)" : "system (fallback) for \(b) frames=\(framesSeen)"
        case nil: return "stopped \(lastError)"
        }
    }

    // own player: which AVPlayerItem's samples count (set on main, read on the audio thread)
    private var ownItem: ObjectIdentifier?
    private var ownFeeding = false            // mirrors running && source == .own, guarded by `lock` for the audio thread
    func setOwnItem(_ it: AVPlayerItem?) { lock.lock(); ownItem = it.map(ObjectIdentifier.init); lock.unlock() }

    func start(_ src: Source) {
        if running && src == source { return }
        if running { stop() }
        source = src
        switch src {
        case .own:
            running = true                     // samples arrive via feedOwn()
            lock.lock(); ownFeeding = true; lock.unlock()
        case .app(let bundle):
            do { try setupTap(bundle: bundle); running = true }
            catch { lastError = "\(error)"; teardown(); source = nil }
        }
    }

    /// Samples from LyricsBar's own player (called on Core Audio's render thread).
    func feedOwn(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, rate: Double, item: ObjectIdentifier) {
        guard frames > 0 else { return }
        lock.lock(); let current = ownFeeding && ownItem == item; lock.unlock()
        guard current else { return }
        let abl = UnsafeMutableAudioBufferListPointer(list)
        var mono = [Float](repeating: 0, count: frames)
        var chans = 0
        for b in abl {
            guard let d = b.mData else { continue }
            let ch = max(1, Int(b.mNumberChannels))
            let f = d.assumingMemoryBound(to: Float.self)
            let n = min(frames, Int(b.mDataByteSize) / (4 * ch))
            for i in 0..<n { for c in 0..<ch { mono[i] += f[i * ch + c] } }
            chans += ch
        }
        guard chans > 0 else { return }
        var k = 1 / Float(chans)
        vDSP_vsmul(mono, 1, &k, &mono, 1, vDSP_Length(frames))
        queue.async {
            if abs(self.sampleRate - rate) > 1 { self.sampleRate = rate; self.computeBandEdges() }
            if self.bandEdges.isEmpty { self.computeBandEdges() }
            self.framesSeen += frames
            self.ring.append(contentsOf: mono)
            while self.ring.count >= self.n {
                self.analyze(Array(self.ring[0..<self.n]))
                self.ring.removeFirst(self.n / 2)
            }
        }
    }

    func stop() {
        guard running else { return }
        teardown()
        running = false; source = nil
        lock.lock(); ownFeeding = false; lock.unlock()
        lock.lock(); _levels = [Float](repeating: 0, count: AudioTap.bands); lock.unlock()
    }

    struct TapError: Error, CustomStringConvertible { let description: String }

    private func check(_ s: OSStatus, _ what: String) throws {
        if s != noErr { throw TapError(description: "\(what) failed (\(s))") }
    }

    /// Core Audio process objects belonging to an app (its main process plus helpers like com.x.helper).
    static func audioProcesses(for bundle: String) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundle).map(\.processIdentifier))
        return ids.filter { id in
            var a = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID, mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
            var b: CFString = "" as CFString
            var sz = UInt32(MemoryLayout<CFString>.size)
            if withUnsafeMutablePointer(to: &b, { AudioObjectGetPropertyData(id, &a, 0, nil, &sz, $0) }) == noErr,
               (b as String) == bundle || (b as String).hasPrefix(bundle + ".") { return true }
            a.mSelector = kAudioProcessPropertyPID
            var pid: pid_t = 0
            sz = UInt32(MemoryLayout<pid_t>.size)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &pid) == noErr && pids.contains(pid)
        }
    }

    private func setupTap(bundle: String) throws {
        let procs = bundle.isEmpty ? [] : Self.audioProcesses(for: bundle)
        tappedProcesses = procs.count
        let desc = procs.isEmpty ? CATapDescription(stereoGlobalTapButExcludeProcesses: [])
                                 : CATapDescription(stereoMixdownOfProcesses: procs)
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true
        try check(AudioHardwareCreateProcessTap(desc, &tapID), "create tap")

        // the tap's UID and format
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        try check(withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, $0) }, "tap uid")
        addr.mSelector = kAudioTapPropertyFormat
        var asbd = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd), "tap format")
        sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000
        let channels = max(1, Int(asbd.mChannelsPerFrame))
        let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        computeBandEdges()

        // private aggregate device that contains the tap
        let outUID = Self.defaultOutputUID() ?? ""
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LyricsBar Visualizer",
            kAudioAggregateDeviceUIDKey: "lyricsbar.tap." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: uid as String]],
        ]
        try check(AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID), "aggregate device")

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue) { [weak self] _, input, _, _, _ in
            self?.consume(input, channels: channels, interleaved: interleaved)
        }, "io proc")
        try check(AudioDeviceStart(aggID, procID), "start")
    }

    private func teardown() {
        if aggID != kAudioObjectUnknown {
            if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p) }
            AudioHardwareDestroyAggregateDevice(aggID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        aggID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown); procID = nil
        queue.async { self.ring.removeAll() }
    }

    static func defaultOutputUID() -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var dev = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr else { return nil }
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString = "" as CFString; size = UInt32(MemoryLayout<CFString>.size)
        let s = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0) }
        return s == noErr ? uid as String : nil
    }

    // MARK: DSP

    private func computeBandEdges() {
        // log-spaced bands from 40 Hz to 16 kHz, mapped to FFT bins
        let lo = 40.0, hi = min(16000.0, sampleRate / 2 - 1), binHz = sampleRate / Double(n)
        bandEdges = (0...AudioTap.bands).map { i in
            let f = lo * pow(hi / lo, Double(i) / Double(AudioTap.bands))
            return max(1, min(n / 2 - 1, Int(f / binHz)))
        }
        for i in 1..<bandEdges.count where bandEdges[i] <= bandEdges[i - 1] { bandEdges[i] = min(n / 2 - 1, bandEdges[i - 1] + 1) }
    }

    private func consume(_ list: UnsafePointer<AudioBufferList>, channels: Int, interleaved: Bool) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = abl.first, let data = first.mData else { return }
        framesSeen += Int(first.mDataByteSize) / 4
        let floats = data.assumingMemoryBound(to: Float.self)
        if interleaved {
            let frames = Int(first.mDataByteSize) / (4 * channels)
            for f in 0..<frames {
                var s: Float = 0
                for c in 0..<channels { s += floats[f * channels + c] }
                ring.append(s / Float(channels))
            }
        } else {
            let frames = Int(first.mDataByteSize) / 4
            for f in 0..<frames {
                var s: Float = 0
                for b in abl { if let d = b.mData { s += d.assumingMemoryBound(to: Float.self)[f] } }
                ring.append(s / Float(abl.count))
            }
        }
        while ring.count >= n {
            analyze(Array(ring[0..<n]))
            ring.removeFirst(n / 2)   // 50% overlap
        }
    }

    private func analyze(_ samples: [Float]) {
        var windowed = [Float](repeating: 0, count: n)
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        var real = [Float](repeating: 0, count: n / 2), imag = [Float](repeating: 0, count: n / 2)
        var mags = [Float](repeating: 0, count: n / 2)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }
        var dbs = [Float](repeating: -120, count: AudioTap.bands)
        for b in 0..<AudioTap.bands {
            let a = bandEdges[b], z = max(a + 1, bandEdges[b + 1])
            var sum: Float = 0
            for i in a..<z { sum += mags[i] }
            // tilt the highs up a little (music has less energy there)
            dbs[b] = 10 * log10(sum / Float(z - a) + 1e-12) + Float(b) / Float(AudioTap.bands) * 10
        }
        // automatic gain: follow the loudest band quickly, let it fall back slowly
        let frameMax = dbs.max() ?? -120
        agcPeak = frameMax > agcPeak ? frameMax : max(frameMax, agcPeak - 0.08)
        let range: Float = 38 / max(0.3, sensitivity)       // higher sensitivity = smaller window = taller bars
        let floor = agcPeak - range
        var out = [Float](repeating: 0, count: AudioTap.bands)
        for b in 0..<AudioTap.bands {
            let x = max(0, min(1, (dbs[b] - floor) / range))
            out[b] = frameMax < -60 ? 0 : pow(x, 1.6)          // silence → flat; curve adds contrast
        }
        lock.lock()
        for i in 0..<out.count {
            // fast attack, slow release
            _levels[i] = out[i] > _levels[i] ? out[i] * 0.7 + _levels[i] * 0.3 : _levels[i] * 0.82 + out[i] * 0.18
        }
        lock.unlock()
    }
}

// MARK: - Bars

final class VisualizerView: NSView {
    enum Style { case background, compact }
    let style: Style
    let count: Int
    var color: NSColor = .white { didSet { for b in bars { b.backgroundColor = color.cgColor } } }
    private var bars: [CALayer] = []
    private var current: [CGFloat]

    init(style: Style) {
        self.style = style
        count = style == .background ? 48 : 5
        current = Array(repeating: 0, count: count)
        super.init(frame: .zero)
        wantsLayer = true
        for _ in 0..<count {
            let l = CALayer()
            l.backgroundColor = color.cgColor
            l.cornerRadius = style == .background ? 1.5 : 1
            layer?.addSublayer(l)
            bars.append(l)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// levels: AudioTap band levels (0…1); resampled to this view's bar count.
    func update(_ levels: [Float]) {
        guard !levels.isEmpty else { return }
        for i in 0..<count {
            // compact uses a few representative bands; background spreads all of them
            let pos = Double(i) / Double(max(1, count - 1)) * Double(levels.count - 1)
            let lo = Int(pos), hi = min(levels.count - 1, lo + 1), t = Float(pos - Double(lo))
            current[i] = CGFloat(levels[lo] * (1 - t) + levels[hi] * t)
        }
        needsLayout = true
        layout()
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let w = bounds.width, h = bounds.height
        switch style {
        case .background:
            let slot = w / CGFloat(count), bw = max(2, slot * 0.55)
            for (i, b) in bars.enumerated() {
                let bh = current[i] < 0.02 ? 0 : max(1.5, current[i] * h)
                b.frame = CGRect(x: CGFloat(i) * slot + (slot - bw) / 2, y: 0, width: bw, height: bh)
            }
        case .compact:
            let bw: CGFloat = 3, gap: CGFloat = 2
            let total = CGFloat(count) * bw + CGFloat(count - 1) * gap
            let x0 = (w - total) / 2
            for (i, b) in bars.enumerated() {
                let bh = max(3, current[i] * (h - 4))
                b.frame = CGRect(x: x0 + CGFloat(i) * (bw + gap), y: (h - bh) / 2, width: bw, height: bh)
            }
        }
        CATransaction.commit()
    }
}

/// A bright, saturated version of an image's average colour (for tinting from album art).
func accentColor(of image: NSImage) -> NSColor? {
    guard let tiff = image.tiffRepresentation, let ci = CIImage(data: tiff) else { return nil }
    let avg = ci.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: ci.extent)])
    var px = [UInt8](repeating: 0, count: 4)
    CIContext().render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    let c = NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
    c.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &a)
    // stay close to the cover's own colour: never add saturation, cap it so it reads as a tint,
    // and only lift brightness enough to be visible on the dark bar
    return NSColor(hue: hue, saturation: min(0.38, sat * 0.85), brightness: min(0.88, max(0.68, bri * 1.5)), alpha: 1)
}


// MARK: - Own-player tap (reads LyricsBar's decoded stream; nothing is recorded)

private final class OwnTapInfo {
    let item: ObjectIdentifier
    var rate: Double = 44100
    init(_ i: ObjectIdentifier) { item = i }
}

/// Attach to every item StreamPlayer creates; only the current one feeds the visualizer.
func attachVisualizerTap(to item: AVPlayerItem) {
    let id = ObjectIdentifier(item)
    Task {
        guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first else { return }
        let info = Unmanaged.passRetained(OwnTapInfo(id)).toOpaque()
        var cb = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: info,
            init: { _, client, storage in storage.pointee = client },
            finalize: { tap in Unmanaged<OwnTapInfo>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, fmt in
                Unmanaged<OwnTapInfo>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().rate = fmt.pointee.mSampleRate
            },
            unprepare: nil,
            process: { tap, frames, _, buf, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buf, flagsOut, nil, framesOut) == noErr else { return }
                let i = Unmanaged<OwnTapInfo>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                AudioTap.shared.feedOwn(buf, frames: Int(framesOut.pointee), rate: i.rate, item: i.item)
            })
        var tapRef: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb, kMTAudioProcessingTapCreationFlag_PostEffects, &tapRef) == noErr,
              let tapRef else { Unmanaged<OwnTapInfo>.fromOpaque(info).release(); return }
        let p = AVMutableAudioMixInputParameters(track: track)
        p.audioTapProcessor = tapRef
        nonisolated(unsafe) let mix = AVMutableAudioMix()      // made here, used only on the main actor from now on
        mix.inputParameters = [p]
        await MainActor.run { item.audioMix = mix }
    }
}
