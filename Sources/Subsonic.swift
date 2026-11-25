// Native Subsonic / Navidrome client (playlists, search, management).
import Foundation
import CryptoKit

struct SubsonicAuth: Codable { var server: String; var u: String; var t: String; var s: String }

struct SPlaylist: Identifiable, Hashable {
    let id: String
    var name: String
    var songCount: Int
    var duration: Int
}

struct SSong: Identifiable, Hashable {
    let uid = UUID()              // playlists may contain the same song twice
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Int
    let coverArt: String?
    static func == (a: SSong, b: SSong) -> Bool { a.uid == b.uid }
    func hash(into h: inout Hasher) { h.combine(uid) }
}

struct SAlbum: Identifiable, Hashable {
    let id: String
    let name: String
    let artist: String
    let artistId: String?
    let coverArt: String?
    let songCount: Int
    let year: Int?
}

struct SArtist: Identifiable, Hashable {
    let id: String
    let name: String
    let albumCount: Int
    let coverArt: String?
}

let likedSongsId = "__liked__"

/// Decodes HTML entities some servers leave in tags ("It&#039;s" → "It's").
extension String {
    var htmlDecoded: String {
        guard contains("&") else { return self }
        var out = "", i = startIndex
        let named = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]
        while i < endIndex {
            if self[i] == "&", let semi = self[i...].prefix(12).firstIndex(of: ";") {
                let ent = String(self[index(after: i)..<semi])
                var rep: String?
                if ent.hasPrefix("#x") || ent.hasPrefix("#X") {
                    rep = UInt32(ent.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if ent.hasPrefix("#") {
                    rep = UInt32(ent.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else { rep = named[ent] }
                if let rep { out += rep; i = index(after: semi); continue }
            }
            out.append(self[i]); i = index(after: i)
        }
        return out
    }
}
func txt(_ v: Any?) -> String { (v as? String)?.htmlDecoded ?? "" }

struct SubsonicError: LocalizedError {
    let message: String
    var code: Int? = nil
    var errorDescription: String? { message }
}

enum Subsonic {
    static let userAgent = "LyricsBar/1.0"   // the server's firewall blocks some default agents

    static var auth: SubsonicAuth? {
        guard let c = Creds.get("subsonic"), let server = c["server"], let u = c["u"], let t = c["t"], let s = c["s"]
        else { return nil }
        return SubsonicAuth(server: server, u: u, t: t, s: s)
    }

    static func saveAuth(_ a: SubsonicAuth) throws {
        guard Creds.set("subsonic", ["server": a.server, "u": a.u, "t": a.t, "s": a.s]) else {
            throw SubsonicError(message: "Signed in, but couldn't save the login to the Keychain")
        }
        ConfigStore.shared.claimDefault("subsonic")
    }

    static func url(_ endpoint: String, _ params: [(String, String)] = [], json: Bool = true, auth a: SubsonicAuth? = nil) -> URL? {
        guard let a = a ?? auth, var comps = URLComponents(string: a.server + "/rest/" + endpoint) else { return nil }
        var q = [URLQueryItem(name: "u", value: a.u), URLQueryItem(name: "t", value: a.t),
                 URLQueryItem(name: "s", value: a.s), URLQueryItem(name: "v", value: "1.16.1"),
                 URLQueryItem(name: "c", value: "lyricsbar")]
        if json { q.append(URLQueryItem(name: "f", value: "json")) }
        q += params.map { URLQueryItem(name: $0.0, value: $0.1) }
        comps.queryItems = q
        // URLComponents leaves "+" as it is, and servers read that as a space (searches, names, e-mail logins)
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url
    }

    static func streamURL(_ id: String) -> URL? { url("stream", [("id", id)], json: false) }
    static func coverURL(_ id: String?, size: Int = 300) -> URL? {
        guard let id else { return nil }
        return url("getCoverArt", [("id", id), ("size", String(size))], json: false)
    }

    @discardableResult
    /// `post`: send `params` as a form body (long lists, e.g. every song of a big playlist, can exceed URL limits).
    static func call(_ endpoint: String, _ params: [(String, String)] = [], auth a: SubsonicAuth? = nil,
                     post: Bool = false) async throws -> [String: Any] {
        let post = post || params.count > 30       // long id lists (star, add to playlist, scrobble) don't fit a URL
        guard let u = url(endpoint, post ? [] : params, auth: a) else { throw SubsonicError(message: "Subsonic isn't set up") }
        var req = URLRequest(url: u, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if post {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            req.httpMethod = "POST"
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = params.map { "\($0.0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
                .joined(separator: "&").data(using: .utf8)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            throw SubsonicError(message: "Server answered HTTP \(h.statusCode)")
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let r = root["subsonic-response"] as? [String: Any] else { throw SubsonicError(message: "Unexpected answer") }
        if r["status"] as? String != "ok" {
            let e = r["error"] as? [String: Any]
            throw SubsonicError(message: e?["message"] as? String ?? "Subsonic error", code: (e?["code"] as? NSNumber)?.intValue)
        }
        return r
    }

    static func song(_ e: [String: Any]) -> SSong {
        SSong(id: e["id"] as? String ?? "", title: txt(e["title"]),
              artist: txt(e["artist"]), album: txt(e["album"]),
              duration: (e["duration"] as? NSNumber)?.intValue ?? 0, coverArt: e["coverArt"] as? String)
    }

    static func playlistInfo(_ p: [String: Any]) -> SPlaylist {
        SPlaylist(id: p["id"] as? String ?? "", name: txt(p["name"]),
                  songCount: (p["songCount"] as? NSNumber)?.intValue ?? 0,
                  duration: (p["duration"] as? NSNumber)?.intValue ?? 0)
    }

    static func playlists() async throws -> [SPlaylist] {
        let r = try await call("getPlaylists")
        let list = (r["playlists"] as? [String: Any])?["playlist"] as? [[String: Any]] ?? []
        return list.map(playlistInfo)
    }

    static func playlist(_ id: String) async throws -> (SPlaylist, [SSong]) {
        let r = try await call("getPlaylist", [("id", id)])
        let p = r["playlist"] as? [String: Any] ?? [:]
        return (playlistInfo(p), (p["entry"] as? [[String: Any]] ?? []).map(song))
    }

    static func album(_ a: [String: Any]) -> SAlbum {
        SAlbum(id: a["id"] as? String ?? "", name: txt(a["name"] ?? a["title"]),
               artist: txt(a["artist"]), artistId: a["artistId"] as? String,
               coverArt: a["coverArt"] as? String, songCount: (a["songCount"] as? NSNumber)?.intValue ?? 0,
               year: (a["year"] as? NSNumber)?.intValue)
    }
    static func artist(_ a: [String: Any]) -> SArtist {
        SArtist(id: a["id"] as? String ?? "", name: txt(a["name"]),
                albumCount: (a["albumCount"] as? NSNumber)?.intValue ?? 0, coverArt: a["coverArt"] as? String)
    }

    /// type: alphabeticalByName | newest | recent | frequent | random | alphabeticalByArtist
    static func albums(_ type: String = "alphabeticalByName", size: Int = 500, offset: Int = 0) async throws -> [SAlbum] {
        let r = try await call("getAlbumList2", [("type", type), ("size", String(size)), ("offset", String(offset))])
        return ((r["albumList2"] as? [String: Any])?["album"] as? [[String: Any]] ?? []).map(album)
    }
    /// Every album: the server returns at most 500 per request, so page through (up to 10,000).
    static func allAlbums(_ type: String = "alphabeticalByName") async throws -> [SAlbum] {
        if type == "random" { return try await albums(type) }       // each page would be a new shuffle
        var all: [SAlbum] = [], seen = Set<String>()
        for page in 0..<20 {
            let part = try await albums(type, size: 500, offset: page * 500)
            all += part.filter { seen.insert($0.id).inserted }
            if part.count < 500 { break }
        }
        return all
    }
    static func albumDetail(_ id: String) async throws -> (SAlbum, [SSong]) {
        let r = try await call("getAlbum", [("id", id)])
        let a = r["album"] as? [String: Any] ?? [:]
        return (album(a), (a["song"] as? [[String: Any]] ?? []).map(song))
    }
    static func artists() async throws -> [SArtist] {
        let r = try await call("getArtists")
        let idx = (r["artists"] as? [String: Any])?["index"] as? [[String: Any]] ?? []
        return idx.flatMap { ($0["artist"] as? [[String: Any]] ?? []).map(artist) }
    }
    static func artistAlbums(_ id: String) async throws -> [SAlbum] {
        let r = try await call("getArtist", [("id", id)])
        return ((r["artist"] as? [String: Any])?["album"] as? [[String: Any]] ?? []).map(album)
    }
    static func searchAll(_ q: String) async throws -> (songs: [SSong], albums: [SAlbum], artists: [SArtist]) {
        let r = try await call("search3", [("query", q), ("songCount", "50"), ("albumCount", "24"), ("artistCount", "12")])
        let res = r["searchResult3"] as? [String: Any] ?? [:]
        return ((res["song"] as? [[String: Any]] ?? []).map(song),
                (res["album"] as? [[String: Any]] ?? []).map(album),
                (res["artist"] as? [[String: Any]] ?? []).map(artist))
    }

    /// Starred ("liked") songs.
    static func starred() async throws -> [SSong] {
        let r = try await call("getStarred2")
        return ((r["starred2"] as? [String: Any])?["song"] as? [[String: Any]] ?? []).map(song)
    }
    /// Report a play. submission=false → "now playing"; true → counts as played (Navidrome forwards to Last.fm / ListenBrainz).
    static func scrobble(_ id: String, submission: Bool, at time: Date = Date()) async throws {
        _ = try await call("scrobble", [("id", id), ("submission", submission ? "true" : "false"),
                                        ("time", String(Int64(time.timeIntervalSince1970 * 1000)))])
    }
    static func star(_ ids: [String]) async throws { _ = try await call("star", ids.map { ("id", $0) }) }
    static func unstar(_ ids: [String]) async throws { _ = try await call("unstar", ids.map { ("id", $0) }) }

    static func search(_ q: String) async throws -> [SSong] {
        let r = try await call("search3", [("query", q), ("songCount", "40"), ("albumCount", "0"), ("artistCount", "0")])
        return ((r["searchResult3"] as? [String: Any])?["song"] as? [[String: Any]] ?? []).map(song)
    }

    static func create(_ name: String, songs: [String] = []) async throws {
        try await call("createPlaylist", [("name", name)] + songs.map { ("songId", $0) })
    }
    static func rename(_ id: String, _ name: String) async throws {
        try await call("updatePlaylist", [("playlistId", id), ("name", name)])
    }
    static func delete(_ id: String) async throws { try await call("deletePlaylist", [("id", id)]) }
    static func add(_ id: String, songs: [String]) async throws {
        try await call("updatePlaylist", [("playlistId", id)] + songs.map { ("songIdToAdd", $0) })
    }
    static func remove(_ id: String, indexes: [Int]) async throws {
        try await call("updatePlaylist", [("playlistId", id)] + indexes.map { ("songIndexToRemove", String($0)) })
    }
    /// Replaces the playlist's songs (used for reordering).
    static func setSongs(_ id: String, _ songs: [String]) async throws {
        try await call("createPlaylist", [("playlistId", id)] + songs.map { ("songId", $0) }, post: true)
    }

    /// Sign in with a password; only the salted token is stored.
    static func login(server: String, user: String, password: String) async throws {
        var srv = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while srv.hasSuffix("/") { srv.removeLast() }
        if !srv.contains("://") { srv = "https://" + srv }
        let salt = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
        let token = Insecure.MD5.hash(data: Data((password + salt).utf8)).map { String(format: "%02x", $0) }.joined()
        let a = SubsonicAuth(server: srv, u: user, t: token, s: salt)
        try await call("ping", auth: a)
        try saveAuth(a)
    }
}
