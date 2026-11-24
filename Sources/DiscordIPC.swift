// Minimal Discord Rich Presence client: the local IPC protocol over a Unix socket.
// Works with the Discord app and with clients that speak the same protocol (Vesktop / arRPC, Legcord…).
// Frames are: UInt32 opcode (LE) + UInt32 length (LE) + JSON. 0 = handshake, 1 = frame, 2 = close, 3 = ping, 4 = pong.
import Foundation

final class DiscordIPC {
    private var fd: Int32 = -1
    private(set) var clientId: String?
    var isConnected: Bool { fd >= 0 }

    /// Where Discord-compatible clients put their socket: discord-ipc-0…9 in the temp dirs.
    static func socketPaths() -> [String] {
        var dirs: [String] = []
        for k in ["XDG_RUNTIME_DIR", "TMPDIR", "TMP", "TEMP"] {
            if let v = ProcessInfo.processInfo.environment[k], !v.isEmpty { dirs.append(v) }
        }
        dirs += [NSTemporaryDirectory(), "/tmp"]
        var seen = Set<String>(), out: [String] = []
        for d in dirs {
            let dir = d.hasSuffix("/") ? String(d.dropLast()) : d
            guard seen.insert(dir).inserted else { continue }
            for i in 0..<10 { out.append("\(dir)/discord-ipc-\(i)") }
        }
        return out
    }

    /// Connects and does the handshake. `paths` overrides the search (tests).
    func connect(clientId id: String, paths: [String]? = nil) -> Bool {
        close()
        for p in paths ?? Self.socketPaths() where FileManager.default.fileExists(atPath: p) {
            let s = socket(AF_UNIX, SOCK_STREAM, 0)
            guard s >= 0 else { continue }
            var one: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 3, tv_usec: 0)          // never hang the presence queue on a stuck client
            setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(p.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(s); continue }
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                for (i, b) in bytes.enumerated() { buf[i] = b }
                buf[bytes.count] = 0
            }
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard rc == 0 else { Darwin.close(s); continue }
            fd = s
            if send(op: 0, ["v": 1, "client_id": id]), let r = readFrame(), r.op == 1, (r.json["evt"] as? String) == "READY" {
                clientId = id
                return true
            }
            close()
        }
        return false
    }

    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        clientId = nil
    }

    @discardableResult
    func send(op: UInt32, _ obj: [String: Any]) -> Bool {
        guard fd >= 0, let body = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        var frame = Data()
        withUnsafeBytes(of: op.littleEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(body)
        var sent = 0
        while sent < frame.count {
            let n = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), frame.count - sent) }
            if n <= 0 { close(); return false }
            sent += n
        }
        return true
    }

    /// Reads one frame, answering pings along the way.
    func readFrame() -> (op: UInt32, json: [String: Any])? {
        func readN(_ n: Int) -> Data? {
            var d = Data(count: n), got = 0
            while got < n {
                let r = d.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: got), n - got) }
                if r <= 0 { return nil }
                got += r
            }
            return d
        }
        while fd >= 0 {
            guard let h = readN(8) else { close(); return nil }
            let op = UInt32(littleEndian: h.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) })
            let len = Int(UInt32(littleEndian: h.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }))
            guard len < 1 << 20, let b = (len == 0 ? Data() : readN(len)) else { close(); return nil }
            let json = (try? JSONSerialization.jsonObject(with: b) as? [String: Any]) ?? [:]
            switch op {
            case 3: send(op: 4, json)                 // ping → pong, keep reading
            case 2: close(); return nil               // the client closed us (bad app ID, etc.)
            default: return (op, json)
            }
        }
        return nil
    }

    /// Sets (or with nil, clears) this process's activity. Returns the client's reply, nil if the connection dropped.
    func setActivity(_ activity: [String: Any]?) -> [String: Any]? {
        let nonce = UUID().uuidString
        let args: [String: Any] = ["pid": Int(getpid()), "activity": activity ?? NSNull()]
        guard send(op: 1, ["cmd": "SET_ACTIVITY", "args": args, "nonce": nonce]) else { return nil }
        for _ in 0..<5 {                              // skip unrelated events until our reply
            guard let r = readFrame() else { return nil }
            if (r.json["nonce"] as? String) == nonce { return r.json }
        }
        return [:]
    }
}
