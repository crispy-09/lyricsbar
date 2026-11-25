// Debug self-test (hook "seektest"): after a seek, does the audio that comes out match the time the
// player reports? Plays the current song on a separate, muted player, seeks around, and matches the
// loudness envelope of what it decodes against a straight decode of the same file (which is exact).
// Nothing is recorded or kept; the result goes to debug.out.

import AVFoundation
import MediaToolbox
import Accelerate

private final class SeekTapStore {
    var rate: Double = 44100
    let lock = NSLock()
    var hops: [(t: Double, e: Float)] = []        // reported item time of each 10 ms hop, and its level
    func add(_ list: UnsafeMutablePointer<AudioBufferList>, frames: Int, start: Double) {
        guard frames > 0, start.isFinite else { return }
        var mono = [Float](repeating: 0, count: frames)
        var chans = 0
        for b in UnsafeMutableAudioBufferListPointer(list) {
            guard let d = b.mData else { continue }
            let ch = max(1, Int(b.mNumberChannels))
            let f = d.assumingMemoryBound(to: Float.self)
            let n = min(frames, Int(b.mDataByteSize) / (4 * ch))
            for i in 0..<n { for c in 0..<ch { mono[i] += f[i * ch + c] } }
            chans += ch
        }
        guard chans > 0 else { return }
        let hop = max(1, Int(rate * 0.01))
        var out: [(Double, Float)] = []
        var i = 0
        while i + hop <= frames {
            var r: Float = 0
            mono.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + i, 1, &r, vDSP_Length(hop)) }
            out.append((start + Double(i) / rate, r / Float(chans)))
            i += hop
        }
        lock.lock(); hops.append(contentsOf: out.map { (t: $0.0, e: $0.1) }); lock.unlock()
    }
    func take() -> [(t: Double, e: Float)] { lock.lock(); defer { lock.unlock() }; return hops }
    func clear() { lock.lock(); hops.removeAll(); lock.unlock() }
}

enum SeekTest {
    private static var running = false
    private static var keep: [Any] = []

    static func run(out: String) {
        guard !running else { return }
        let sp = StreamPlayer.shared
        guard sp.tracks.indices.contains(sp.index) else { try? "no song loaded".write(toFile: out, atomically: true, encoding: .utf8); return }
        let track = sp.tracks[sp.index]
        running = true
        try? "running…".write(toFile: out, atomically: true, encoding: .utf8)
        Task {
            var log = "song: \(track.title) (\(Int(track.duration)) s)\n"
            defer {
                try? log.write(toFile: out, atomically: true, encoding: .utf8)
                running = false; keep.removeAll()
            }
            // 1. the same bytes the player gets, decoded start to end: the true time of every sound
            guard let (data, resp) = try? await URLSession.shared.data(from: track.stream), let http = resp as? HTTPURLResponse else {
                log += "download failed\n"; return
            }
            let mime = http.mimeType ?? "?"
            log += "server: status \(http.statusCode), type \(mime), \(data.count / 1024) KB, "
                + "accept-ranges \(http.value(forHTTPHeaderField: "Accept-Ranges") ?? "-"), "
                + "content-length \(http.value(forHTTPHeaderField: "Content-Length") ?? "-")\n"
            let ext = ["audio/mpeg": "mp3", "audio/mp3": "mp3", "audio/flac": "flac", "audio/x-flac": "flac", "audio/mp4": "m4a",
                       "audio/x-m4a": "m4a", "audio/aac": "aac", "audio/wav": "wav", "audio/x-wav": "wav", "audio/ogg": "ogg",
                       "audio/opus": "opus"][mime.lowercased()] ?? "mp3"
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("lyricsbar-seektest." + ext)
            defer { try? FileManager.default.removeItem(at: tmp) }
            guard (try? data.write(to: tmp)) != nil, let ref = await envelope(of: tmp, log: &log), ref.count > 2000 else {
                log += "couldn't decode the downloaded file\n"; return
            }
            log += "reference: \(ref.count / 100) s decoded\n"
            // 2. the player: as LyricsBar plays it, and a plain one (no precise timing) for comparison
            log += "\n== as LyricsBar plays it ==\n"
            await measure(asset: StreamPlayer.asset(track.stream), duration: Double(ref.count) / 100, ref: ref, log: &log)
            log += "\n== plain AVPlayer (no precise timing) ==\n"
            await measure(asset: AVURLAsset(url: track.stream), duration: Double(ref.count) / 100, ref: ref, log: &log)
        }
    }

    /// Level per 10 ms of the whole file, decoded linearly.
    private static func envelope(of file: URL, log: inout String) async -> [Float]? {
        let asset = AVURLAsset(url: file, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
        if let fd = try? await track.load(.formatDescriptions).first {
            let sub = CMFormatDescriptionGetMediaSubType(fd)
            let cc = String(bytes: [UInt8(sub >> 24 & 255), UInt8(sub >> 16 & 255), UInt8(sub >> 8 & 255), UInt8(sub & 255)], encoding: .ascii) ?? "?"
            let rate = (try? await track.load(.estimatedDataRate)) ?? 0
            log += "format: '\(cc)', about \(Int(rate / 1000)) kbps\n"
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                       AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
                                       AVNumberOfChannelsKey: 1, AVSampleRateKey: 44100]
        let outp = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        guard reader.canAdd(outp) else { return nil }
        reader.add(outp)
        guard reader.startReading() else { return nil }
        var env: [Float] = [], carry: [Float] = []
        let hop = 441
        while let sb = outp.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(bb)
            var chunk = [Float](repeating: 0, count: len / 4)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: $0.baseAddress!) }
            carry.append(contentsOf: chunk)
            var i = 0
            while i + hop <= carry.count {
                var r: Float = 0
                carry.withUnsafeBufferPointer { vDSP_rmsqv($0.baseAddress! + i, 1, &r, vDSP_Length(hop)) }
                env.append(r); i += hop
            }
            carry.removeFirst(i)
        }
        return env
    }

    private static func measure(asset: AVURLAsset, duration: Double, ref: [Float], log: inout String) async {
        let item = AVPlayerItem(asset: asset)
        let store = SeekTapStore()
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { log += "no audio track\n"; return }
        var cb = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0, clientInfo: Unmanaged.passRetained(store).toOpaque(),
            init: { _, client, storage in storage.pointee = client },
            finalize: { tap in Unmanaged<SeekTapStore>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
            prepare: { tap, _, fmt in
                Unmanaged<SeekTapStore>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().rate = fmt.pointee.mSampleRate
            },
            unprepare: nil,
            process: { tap, frames, _, buf, framesOut, flagsOut in
                var range = CMTimeRange()
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, buf, flagsOut, &range, framesOut) == noErr else { return }
                Unmanaged<SeekTapStore>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .add(buf, frames: Int(framesOut.pointee), start: range.start.seconds)
            })
        var tapRef: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &cb, kMTAudioProcessingTapCreationFlag_PostEffects, &tapRef) == noErr, let tapRef else {
            log += "no tap\n"; return
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tapRef
        let mix = AVMutableAudioMix(); mix.inputParameters = [params]
        let t0 = Date()
        let player = await MainActor.run { () -> AVPlayer in
            item.audioMix = mix
            let p = AVPlayer(playerItem: item)
            p.isMuted = true
            p.play()
            return p
        }
        keep.append(player)
        defer { Task { @MainActor in player.pause(); player.replaceCurrentItem(with: nil) } }

        // waits until `n` hops with a reported time in [from, to] have come through
        func collect(from: Double, to: Double, n: Int, timeout: Double) async -> [(t: Double, e: Float)] {
            let end = Date().addingTimeInterval(timeout)
            while Date() < end {
                let h = store.take().filter { $0.t >= from && $0.t <= to }
                if h.count >= n { return h }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return store.take().filter { $0.t >= from && $0.t <= to }
        }
        // how far the real position is from the reported one: best match of the levels against the reference
        func offset(_ h: [(t: Double, e: Float)]) -> (lag: Double, score: Double)? {
            guard h.count >= 100 else { return nil }
            let x = h.map { Foundation.log($0.e + 1e-4) }
            let mx = x.reduce(0, +) / Float(x.count)
            let dx = x.map { $0 - mx }
            let sx = sqrt(dx.reduce(0) { $0 + $1 * $1 })
            guard sx > 0.5 else { return nil }                       // silence: nothing to match
            var best = (lag: 0.0, score: -2.0)
            for step in -3000...3000 {
                let lag = Double(step) * 0.01
                var y = [Float](repeating: 0, count: h.count), ok = true
                for (i, s) in h.enumerated() {
                    let k = Int(((s.t + lag) * 100).rounded())
                    guard k >= 0, k < ref.count else { ok = false; break }
                    y[i] = Foundation.log(ref[k] + 1e-4)
                }
                guard ok else { continue }
                let my = y.reduce(0, +) / Float(y.count)
                var num: Float = 0, sy: Float = 0
                for i in 0..<y.count { let d = y[i] - my; num += dx[i] * d; sy += d * d }
                guard sy > 0 else { continue }
                let sc = Double(num / (sx * sqrt(sy)))
                if sc > best.score { best = (lag, sc) }
            }
            return best
        }
        func line(_ name: String, _ h: [(t: Double, e: Float)]) -> String {
            guard let o = offset(h) else { return "\(name): not enough audio (\(h.count) hops)\n" }
            return String(format: "%@: audio is %+.2f s from the reported time (match %.2f)\n", name, o.lag, o.score)
        }

        let first = await collect(from: 1.0, to: 3.5, n: 240, timeout: 25)
        log += String(format: "start to audio: %.1f s\n", Date().timeIntervalSince(t0) - 3.5)
        log += line("from the start", first)
        var targets: [Double] = [60, 20, 100, 45, 130, 10, 80, 150, 30].filter { $0 < duration - 12 }
        if targets.isEmpty { targets = [duration / 2] }
        for t in targets {
            store.clear()
            await player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            store.clear()
            let h = await collect(from: t + 0.4, to: t + 2.9, n: 240, timeout: 12)
            let reported = await MainActor.run { player.currentTime().seconds }
            log += line(String(format: "seek to %3.0f s (player now says %.1f)", t, reported), h)
        }
    }
}
