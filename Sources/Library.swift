// Library window: browse the Subsonic library (albums, artists, playlists, search), Spotify playlists,
// and edit the LyricsBar queue. Opened from the Touch Bar's right-hand button or the menu bar.
import SwiftUI
import AppKit
import CryptoKit

// MARK: - Window + activation policy shared with Settings

final class LibraryWindow: NSObject, NSWindowDelegate {
    static let shared = LibraryWindow()
    var window: NSWindow?

    func show(_ section: LibSection? = nil) {
        if let section { LibraryModel.shared.section = section }
        open()
    }

    func show(settings section: SettingsSection) {
        LibraryModel.shared.item = .settings(section)
        open()
    }

    private func open() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "LyricsBar"
            w.contentViewController = NSHostingController(rootView: LibraryView())
            w.setContentSize(NSSize(width: 1040, height: 680))
            w.minSize = NSSize(width: 760, height: 480)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Touch Bar buttons. 📚 (settings: false) and holding the art (settings: true):
    /// window in front on that side → close it; in front on the other side → switch over; otherwise open / bring forward.
    func toggle(settings: Bool = false) {
        let m = LibraryModel.shared
        let front = window.map { $0.isVisible && !$0.isMiniaturized && NSApp.isActive && ($0.isKeyWindow || $0.isMainWindow) } ?? false
        if front && m.showingSettings == settings { window?.performClose(nil); return }
        if settings { m.item = .settings(m.lastSettings) } else { m.item = .lib(m.section) }
        open()
    }

    func windowWillClose(_ n: Notification) { windowClosing(n.object as? NSWindow) }
}

/// Go back to being a Dock-less accessory once no LyricsBar window is open.
func windowClosing(_ w: NSWindow?) {
    let open = [LibraryWindow.shared.window]
        .compactMap { $0 }.filter { $0 !== w && $0.isVisible }
    if open.isEmpty { NSApp.setActivationPolicy(.accessory) }
}

// MARK: - Covers (custom User-Agent + cache)

final class CoverCache {
    static let shared = CoverCache()
    let cache = NSCache<NSString, NSImage>()
    func image(_ id: String?, size: Int = 300) async -> NSImage? {
        guard let id, let url = Subsonic.coverURL(id, size: size) else { return nil }
        let key = "\(id)@\(size)" as NSString
        if let i = cache.object(forKey: key) { return i }
        var req = URLRequest(url: url); req.setValue(Subsonic.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (d, _) = try? await URLSession.shared.data(for: req), let img = NSImage(data: d) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }
}

struct Cover: View {
    let id: String?
    var size: CGFloat = 150
    var radius: CGFloat = 8
    @State private var img: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius).fill(.quaternary)
            if let img { Image(nsImage: img).resizable().aspectRatio(contentMode: .fill) }
            else { Image(systemName: "music.note").font(.system(size: size * 0.3)).foregroundStyle(.tertiary) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .task(id: id) { img = await CoverCache.shared.image(id, size: size > 80 ? 300 : 120) }
    }
}

// MARK: - Model

enum LibSection: String, CaseIterable, Identifiable, Hashable {
    case queue = "Up Next", search = "Search", albums = "Albums", artists = "Artists"
    case playlists = "Playlists", spotify = "Spotify", liked = "Liked Songs", lyrics = "Lyrics"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .queue: return "text.line.first.and.arrowtriangle.forward"
        case .search: return "magnifyingglass"
        case .albums: return "square.stack"
        case .artists: return "music.mic"
        case .playlists: return "music.note.list"
        case .spotify: return "dot.radiowaves.left.and.right"
        case .liked: return "heart"
        case .lyrics: return "quote.bubble"
        }
    }
}

enum SidebarItem: Hashable {
    case lib(LibSection)
    case settings(SettingsSection)
}

final class LibraryModel: ObservableObject {
    static let shared = LibraryModel()
    @Published var item: SidebarItem = .lib(.albums) {
        didSet {
            switch item {
            case .lib(let s): lastLib = s
            case .settings(let s): lastSettings = s
            }
        }
    }
    private(set) var lastLib: LibSection = .albums
    private(set) var lastSettings: SettingsSection = .general
    var showingSettings: Bool { if case .settings = item { return true } else { return false } }
    /// The library section (the last one used while Settings is showing). Setting it shows that section.
    var section: LibSection {
        get { lastLib }
        set { item = .lib(newValue) }
    }
}

/// Polls the shared Now Playing state so the bottom bar works for any player.
final class NowPlayingModel: ObservableObject {
    @Published var title = ""
    @Published var artist = ""
    @Published var playing = false
    @Published var bundle = ""
    @Published var art: NSImage?
    private var timer: Timer?
    private var lastState = Data(), lastArt: Date?
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }
    deinit { timer?.invalidate() }
    private var sysTitle = "", sysArtist = "", sysPlaying = false
    func poll() {
        if let d = FileManager.default.contents(atPath: home + "/state.json"), d != lastState,
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            lastState = d
            sysTitle = j["title"] as? String ?? ""; sysArtist = j["artist"] as? String ?? ""
            sysPlaying = j["playing"] as? Bool ?? false
            set(\.bundle, j["bundle"] as? String ?? "")
        }
        let sp = StreamPlayer.shared
        if sysTitle.isEmpty || bundle == Bundle.main.bundleIdentifier, sp.active, sp.tracks.indices.contains(sp.index) {
            // macOS hasn't listed LyricsBar as Now Playing yet (e.g. a restored, paused queue): show it directly
            let t = sp.tracks[sp.index]
            set(\.title, t.title); set(\.artist, t.artist); set(\.playing, sp.player.rate > 0)
            if ownCover != t.cover {
                ownCover = t.cover
                if let u = t.cover {
                    URLSession.shared.dataTask(with: u) { d, _, _ in
                        let img = d.flatMap(NSImage.init(data:))
                        DispatchQueue.main.async { if self.ownCover == u { self.art = img } }
                    }.resume()
                } else { art = nil }
            }
            return
        }
        if ownCover != nil { ownCover = nil; lastArt = nil }     // back to the system player: reload its artwork
        set(\.title, sysTitle); set(\.artist, sysArtist); set(\.playing, sysPlaying)
        let p = home + "/artwork.jpg"
        let m = (try? FileManager.default.attributesOfItem(atPath: p)[.modificationDate]) as? Date
        if m != lastArt || (m == nil && art != nil) { lastArt = m; art = m.flatMap { _ in NSImage(contentsOfFile: p) } }
    }
    /// Publish only real changes, so SwiftUI doesn't redraw every half second.
    private func set<T: Equatable>(_ k: ReferenceWritableKeyPath<NowPlayingModel, T>, _ v: T) {
        if self[keyPath: k] != v { self[keyPath: k] = v }
    }
    private var ownCover: URL?
}

// MARK: - Root

struct LibraryView: View {
    @ObservedObject var model = LibraryModel.shared
    var body: some View {
        NavigationSplitView {
            List(selection: $model.item) {
                Section("Now") {
                    ForEach([LibSection.queue, .lyrics, .search]) { s in Label(s.rawValue, systemImage: s.icon).tag(SidebarItem.lib(s)) }
                }
                Section("Library") {
                    ForEach([LibSection.liked, .albums, .artists, .playlists]) { s in Label(s.rawValue, systemImage: s.icon).tag(SidebarItem.lib(s)) }
                }
                Section("Spotify") {
                    Label("Playlists", systemImage: LibSection.spotify.icon).tag(SidebarItem.lib(.spotify))
                }
                Section("Settings") {
                    ForEach(SettingsSection.allCases) { s in
                        Label(s.rawValue, systemImage: s.icon).tag(SidebarItem.settings(s))
                    }
                }
            }
            .background {      // ⌘, jumps to Settings
                Button("") { model.item = .settings(model.lastSettings) }.keyboardShortcut(",", modifiers: .command).hidden()
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            VStack(spacing: 0) {
                NavigationStack {
                    Group {
                        if case .settings(let ss) = model.item {
                            SettingsDetail(section: ss)
                        } else if Subsonic.auth == nil && ![.spotify, .queue, .lyrics].contains(model.section) {
                            ContentUnavailableView("Subsonic isn't connected", systemImage: "server.rack",
                                                   description: Text("Sign in under Settings → Providers in the sidebar."))
                        } else {
                            switch model.section {
                            case .queue: QueueView()
                            case .search: SearchView()
                            case .albums: AlbumsView()
                            case .artists: ArtistsView()
                            case .playlists: PlaylistsView()
                            case .spotify: SpotifyPlaylistsView()
                            case .liked: LikedView()
                            case .lyrics: LyricsView()
                            }
                        }
                    }
                    .navigationDestination(for: SAlbum.self) { AlbumDetail(album: $0) }
                    .navigationDestination(for: SArtist.self) { ArtistDetail(artist: $0) }
                    .navigationDestination(for: SPlaylist.self) { PlaylistDetail(playlist: $0) }
                }
                .id(model.item)               // reset the navigation path when switching sections
                Divider()
                NowPlayingBar()
            }
        }
    }
}

struct NowPlayingBar: View {
    @StateObject var np = NowPlayingModel()
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let a = np.art { Image(nsImage: a).resizable().aspectRatio(contentMode: .fill) }
                else { Image(systemName: "music.note").foregroundStyle(.tertiary) }
            }
            .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(np.title.isEmpty ? "Not playing" : np.title).font(.headline).lineLimit(1)
                Text(np.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            HStack(spacing: 18) {
                Button { transport(.previous) } label: { Image(systemName: "backward.fill") }
                Button { transport(.toggle) } label: {
                    Image(systemName: np.playing ? "pause.fill" : "play.fill").font(.title2)
                }
                Button { transport(.next) } label: { Image(systemName: "forward.fill") }
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
    }
}

// MARK: - Shared song list

struct SongActions {
    static func menu(_ songs: [SSong], all: [SSong], index: Int) -> some View {
        Group {
            Button("Play") { playSongs(all, start: index) }
            Button("Play Next") { queueNext(songs) }
            Button("Add to Queue") { queueLater(songs) }
            AddToPlaylistMenu(songs: songs)
            Divider()
            Button("Add to Liked Songs") { Task { try? await Subsonic.star(songs.map(\.id)); LikedModel.shared.reload() } }
            Button("Remove from Liked Songs") { Task { try? await Subsonic.unstar(songs.map(\.id)); LikedModel.shared.reload() } }
        }
    }
}

final class LikedModel: ObservableObject {
    static let shared = LikedModel()
    @Published var songs: [SSong] = []
    @Published var error: String?
    func reload() {
        Task { @MainActor in
            do { songs = try await Subsonic.starred(); error = nil; LikedCache.shared.reload() } catch { self.error = error.localizedDescription }
        }
    }
}

struct LikedView: View {
    @ObservedObject var liked = LikedModel.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom, spacing: 20) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(LinearGradient(colors: [.pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "heart.fill").font(.system(size: 64)).foregroundStyle(.white)
                    }
                    .frame(width: 180, height: 180).shadow(radius: 8, y: 4)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PLAYLIST").font(.caption.bold()).foregroundStyle(.secondary)
                        Text("Liked Songs").font(.largeTitle.bold())
                        Text("\(liked.songs.count) songs · \(mmss(liked.songs.reduce(0) { $0 + $1.duration }))").foregroundStyle(.secondary)
                        PlayButtons(songs: liked.songs).padding(.top, 6)
                    }
                }
                if let e = liked.error { Text(e).foregroundStyle(.red) }
                if liked.songs.isEmpty && liked.error == nil {
                    Text("Right-click any song and choose “Add to Liked Songs”.").foregroundStyle(.secondary)
                }
                SongList(songs: liked.songs)
            }
            .padding(24)
        }
        .navigationTitle("Liked Songs")
        .onAppear { liked.reload() }
    }
}

struct AddToPlaylistMenu: View {
    let songs: [SSong]
    @State private var playlists: [SPlaylist] = []
    var body: some View {
        Menu("Add to Playlist") {
            ForEach(playlists) { p in
                Button(p.name) { Task { try? await Subsonic.add(p.id, songs: songs.map(\.id)) } }
            }
        }
        .task { playlists = (try? await Subsonic.playlists()) ?? [] }
    }
}

struct SongList: View {
    let songs: [SSong]
    var showAlbum = true
    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(songs.enumerated()), id: \.offset) { i, s in
                SongRow(song: s, number: i + 1, showAlbum: showAlbum)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { playSongs(songs, start: i) }
                    .contextMenu { SongActions.menu([s], all: songs, index: i) }
                Divider().padding(.leading, 44)
            }
        }
    }
}

struct SongRow: View {
    let song: SSong
    let number: Int
    var showAlbum = true
    @State private var hover = false
    var body: some View {
        HStack(spacing: 12) {
            Text("\(number)").foregroundStyle(.secondary).monospacedDigit().frame(width: 28, alignment: .trailing)
            if showAlbum { Cover(id: song.coverArt, size: 32, radius: 4) }
            VStack(alignment: .leading, spacing: 1) {
                Text(song.title).lineLimit(1)
                Text(showAlbum ? "\(song.artist) — \(song.album)" : song.artist)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if hover {
                Button { queueNext([song]) } label: { Image(systemName: "text.insert") }.help("Play Next")
                Button { queueLater([song]) } label: { Image(systemName: "text.append") }.help("Add to Queue")
            }
            Text(mmss(song.duration)).foregroundStyle(.secondary).monospacedDigit()
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(hover ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { hover = $0 }
    }
}

struct PlayButtons: View {
    let songs: [SSong]
    var body: some View {
        HStack {
            Button { playSongs(songs) } label: { Label("Play", systemImage: "play.fill") }.buttonStyle(.borderedProminent)
            Button { playSongs(songs, shuffle: true) } label: { Label("Shuffle", systemImage: "shuffle") }
            Menu {
                Button("Play Next") { queueNext(songs) }
                Button("Add to Queue") { queueLater(songs) }
                AddToPlaylistMenu(songs: songs)
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .disabled(songs.isEmpty)
    }
}

// MARK: - Albums / artists / playlists

struct AlbumCell: View {
    let album: SAlbum
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Cover(id: album.coverArt, size: 150)
            Text(album.name).font(.callout.weight(.medium)).lineLimit(1)
            Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(width: 150)
        .contextMenu {
            Button("Play") { Task { if let s = try? await Subsonic.albumDetail(album.id).1 { playSongs(s) } } }
            Button("Shuffle") { Task { if let s = try? await Subsonic.albumDetail(album.id).1 { playSongs(s, shuffle: true) } } }
            Button("Play Next") { Task { if let s = try? await Subsonic.albumDetail(album.id).1 { queueNext(s) } } }
            Button("Add to Queue") { Task { if let s = try? await Subsonic.albumDetail(album.id).1 { queueLater(s) } } }
        }
    }
}

struct AlbumGrid: View {
    let albums: [SAlbum]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 170), spacing: 18)], alignment: .leading, spacing: 20) {
            ForEach(albums) { a in NavigationLink(value: a) { AlbumCell(album: a) }.buttonStyle(.plain) }
        }
    }
}

struct AlbumsView: View {
    @State private var sort = "alphabeticalByName"
    @State private var albums: [SAlbum] = []
    @State private var error: String?
    var body: some View {
        ScrollView {
            if let error { Text(error).foregroundStyle(.red).padding() }
            AlbumGrid(albums: albums).padding(20)
        }
        .navigationTitle("Albums")
        .toolbar {
            Picker("Sort", selection: $sort) {
                Text("A–Z").tag("alphabeticalByName")
                Text("Artist").tag("alphabeticalByArtist")
                Text("Recently Added").tag("newest")
                Text("Recently Played").tag("recent")
                Text("Most Played").tag("frequent")
                Text("Random").tag("random")
            }
        }
        .task(id: sort) {
            do { albums = try await Subsonic.albums(sort); error = nil } catch { self.error = error.localizedDescription }
        }
    }
}

struct AlbumDetail: View {
    let album: SAlbum
    @State private var songs: [SSong] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom, spacing: 20) {
                    Cover(id: album.coverArt, size: 180, radius: 10).shadow(radius: 8, y: 4)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ALBUM").font(.caption.bold()).foregroundStyle(.secondary)
                        Text(album.name).font(.largeTitle.bold()).lineLimit(2)
                        if let id = album.artistId {
                            NavigationLink(value: SArtist(id: id, name: album.artist, albumCount: 0, coverArt: nil)) {
                                Text(album.artist).font(.title3)
                            }.buttonStyle(.plain)
                        } else { Text(album.artist).font(.title3) }
                        Text([album.year.map(String.init), "\(songs.count) songs",
                              mmss(songs.reduce(0) { $0 + $1.duration })].compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        PlayButtons(songs: songs).padding(.top, 6)
                    }
                }
                SongList(songs: songs, showAlbum: false)
            }
            .padding(24)
        }
        .navigationTitle(album.name)
        .task { songs = (try? await Subsonic.albumDetail(album.id).1) ?? [] }
    }
}

struct ArtistsView: View {
    @State private var artists: [SArtist] = []
    @State private var filter = ""
    var shown: [SArtist] { filter.isEmpty ? artists : artists.filter { $0.name.localizedCaseInsensitiveContains(filter) } }
    var body: some View {
        List(shown) { a in
            NavigationLink(value: a) {
                HStack {
                    Cover(id: a.coverArt, size: 36, radius: 18)
                    Text(a.name)
                    Spacer()
                    Text("\(a.albumCount) albums").foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $filter, prompt: "Filter artists")
        .navigationTitle("Artists")
        .task { artists = (try? await Subsonic.artists()) ?? [] }
    }
}

struct ArtistDetail: View {
    let artist: SArtist
    @State private var albums: [SAlbum] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(artist.name).font(.largeTitle.bold())
                    Spacer()
                    Button { Task { await playAll(shuffle: true) } } label: { Label("Shuffle All", systemImage: "shuffle") }
                }
                AlbumGrid(albums: albums)
            }
            .padding(24)
        }
        .navigationTitle(artist.name)
        .task { albums = (try? await Subsonic.artistAlbums(artist.id)) ?? [] }
    }
    func playAll(shuffle: Bool) async {
        var all: [SSong] = []
        for a in albums { all += (try? await Subsonic.albumDetail(a.id).1) ?? [] }
        playSongs(all, shuffle: shuffle)
    }
}

struct PlaylistsView: View {
    @StateObject var m = SubsonicManager()
    @ObservedObject var store = ConfigStore.shared
    @State private var nameDraft = ""
    @State private var showNew = false
    @State private var renaming: SPlaylist?
    @State private var deleting: SPlaylist?
    @State private var editing: SPlaylist?
    var body: some View {
        List {
            if !store.c.pinned.isEmpty {
                Section {
                    ForEach(store.c.pinned) { p in
                        HStack {
                            Image(systemName: "pin.fill").foregroundStyle(.orange).frame(width: 24)
                            Text(p.name)
                            Spacer()
                            Text(p.provider == "subsonic" ? "Subsonic" : p.provider.capitalized).foregroundStyle(.secondary)
                            Button { store.c.pinned.removeAll { $0.id == p.id } } label: { Image(systemName: "pin.slash") }
                                .buttonStyle(.borderless).help("Unpin")
                        }
                    }
                    .onMove { store.c.pinned.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Pinned on the Touch Bar")
                } footer: {
                    Text("Shown first in the Touch Bar picker. Drag to reorder.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Playlists") {
                if let e = m.error { Text(e).foregroundStyle(.secondary) }
                ForEach(m.playlists) { p in
                    NavigationLink(value: p) {
                        HStack {
                            Image(systemName: "music.note.list").foregroundStyle(.secondary).frame(width: 24)
                            Text(p.name)
                            if store.isPinned("subsonic", p.id) { Image(systemName: "pin.fill").foregroundStyle(.orange).font(.caption) }
                            Spacer()
                            Text("\(p.songCount) songs").foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("Play") { Task { if let s = try? await Subsonic.playlist(p.id).1 { playSongs(s) } } }
                        Button("Shuffle") { Task { if let s = try? await Subsonic.playlist(p.id).1 { playSongs(s, shuffle: true) } } }
                        Divider()
                        Button(store.isPinned("subsonic", p.id) ? "Unpin from Touch Bar" : "Pin to Touch Bar") {
                            store.togglePin("subsonic", p.id, p.name)
                        }
                        Button("Edit Songs…") { editing = p }
                        Button("Rename…") { nameDraft = p.name; renaming = p }
                        Button("Delete…", role: .destructive) { deleting = p }
                    }
                }
            }
        }
        .navigationTitle("Playlists")
        .toolbar {
            if m.busy { ProgressView().controlSize(.small) }
            Button { nameDraft = ""; showNew = true } label: { Label("New Playlist", systemImage: "plus") }
        }
        .onAppear { m.reloadPlaylists() }
        .alert("New playlist", isPresented: $showNew) {
            TextField("Name", text: $nameDraft)
            Button("Create") { m.create(nameDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $nameDraft)
            Button("Rename") { if let p = renaming { m.rename(p.id, nameDraft) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")” from your server?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let p = deleting { m.delete(p.id) } }
        }
        .sheet(item: $editing, onDismiss: { m.reloadPlaylists() }) { p in
            PlaylistEditor(playlistId: p.id) { editing = nil }
        }
    }
}

struct PlaylistDetail: View {
    let playlist: SPlaylist
    @State private var songs: [SSong] = []
    @State private var editing = false
    @State private var deleted = false
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store = ConfigStore.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .bottom, spacing: 20) {
                    Cover(id: songs.first?.coverArt, size: 180, radius: 10).shadow(radius: 8, y: 4)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PLAYLIST").font(.caption.bold()).foregroundStyle(.secondary)
                        Text(playlist.name).font(.largeTitle.bold()).lineLimit(2)
                        Text("\(songs.count) songs · \(mmss(songs.reduce(0) { $0 + $1.duration }))").foregroundStyle(.secondary)
                        HStack {
                            PlayButtons(songs: songs)
                            Button("Edit") { editing = true }
                            Button {
                                store.togglePin("subsonic", playlist.id, playlist.name)
                            } label: {
                                Image(systemName: store.isPinned("subsonic", playlist.id) ? "pin.fill" : "pin")
                            }
                            .help("Pin to Touch Bar")
                        }
                        .padding(.top, 6)
                    }
                }
                SongList(songs: songs)
            }
            .padding(24)
        }
        .navigationTitle(playlist.name)
        .task { songs = (try? await Subsonic.playlist(playlist.id).1) ?? [] }
        .sheet(isPresented: $editing, onDismiss: {
            if deleted { dismiss() } else { Task { songs = (try? await Subsonic.playlist(playlist.id).1) ?? [] } }
        }) {
            PlaylistEditor(playlistId: playlist.id, onDeleted: { deleted = true }) { editing = false }
        }
    }
}

// MARK: - Search

struct SearchView: View {
    @State private var query = ""
    @State private var songs: [SSong] = []
    @State private var albums: [SAlbum] = []
    @State private var artists: [SArtist] = []
    @State private var searching = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if query.isEmpty {
                    ContentUnavailableView("Search your library", systemImage: "magnifyingglass",
                                           description: Text("Songs, albums and artists from your Subsonic server."))
                        .frame(maxWidth: .infinity).padding(.top, 60)
                }
                if !artists.isEmpty {
                    Text("Artists").font(.title2.bold())
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            ForEach(artists) { a in
                                NavigationLink(value: a) {
                                    VStack { Cover(id: a.coverArt, size: 90, radius: 45); Text(a.name).lineLimit(1).frame(width: 100) }
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                if !albums.isEmpty { Text("Albums").font(.title2.bold()); AlbumGrid(albums: albums) }
                if !songs.isEmpty {
                    HStack { Text("Songs").font(.title2.bold()); Spacer(); PlayButtons(songs: songs) }
                    SongList(songs: songs)
                }
            }
            .padding(24)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Songs, albums, artists")
        .navigationTitle("Search")
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { songs = []; albums = []; artists = []; return }
            try? await Task.sleep(nanoseconds: 300_000_000)   // debounce typing
            guard !Task.isCancelled, let r = try? await Subsonic.searchAll(q) else { return }
            songs = r.songs; albums = r.albums; artists = r.artists
        }
    }
}

// MARK: - Spotify

struct SpotifyPlaylistsView: View {
    @State private var rows: [PlaylistRow] = []
    @State private var error: String?
    @ObservedObject var store = ConfigStore.shared
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.secondary) }
            ForEach(rows) { r in
                HStack {
                    Image(systemName: "music.note.list").foregroundStyle(.green).frame(width: 24)
                    Text(r.name)
                    Spacer()
                    if r.count > 0 { Text("\(r.count) songs").foregroundStyle(.secondary) }
                    Button { store.togglePin("spotify", r.id, r.name) } label: {
                        Image(systemName: store.isPinned("spotify", r.id) ? "pin.fill" : "pin")
                    }.buttonStyle(.borderless).help("Pin to Touch Bar")
                    Button("Play") { playSpotify(r.id) }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { playSpotify(r.id) }
            }
        }
        .navigationTitle("Spotify Playlists")
        .task {
            switch await loadPlaylists("spotify") {
            case .success(let r): rows = r; error = nil
            case .failure(let e): error = e.localizedDescription
            }
        }
    }
    func playSpotify(_ uri: String) {
        StreamPlayer.shared.stop()
        run(mediaControl, ["pause"])
        let u = spotifySafe(uri)
        run("/usr/bin/osascript", ["-e", "tell application \"Spotify\" to play track \"\(u)\""])
    }
}

// MARK: - Queue

struct QueueView: View {
    @ObservedObject var sp = StreamPlayer.shared
    @StateObject var np = NowPlayingModel()
    @State private var external: [(String, String)] = []
    var body: some View {
        Group {
            // Spotify is the current player (and ours isn't playing): show Spotify's queue, not our paused one
            if np.bundle == "com.spotify.client" && !np.title.isEmpty && !sp.isPlaying {
                SpotifyQueueList(np: np)
            } else if sp.active {
                List {
                    Section("Now Playing") {
                        if sp.tracks.indices.contains(sp.index) { trackRow(sp.tracks[sp.index], playing: true) }
                    }
                    Section {
                        // act by song identity (uid), so a crossfade to the next song in between can't hit the wrong row
                        ForEach(sp.upcoming, id: \.uid) { t in
                            trackRow(t, playing: false)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { sp.jump(uid: t.uid) }
                                .contextMenu {
                                    Button("Play Now") { sp.jump(uid: t.uid) }
                                    Button("Remove from Queue", role: .destructive) { sp.remove(uid: t.uid) }
                                }
                        }
                        .onMove { from, to in
                            var ids = sp.upcoming.map(\.uid)
                            ids.move(fromOffsets: from, toOffset: to)
                            sp.reorderUpcoming(ids)
                        }
                        .onDelete { offs in
                            let ids = offs.compactMap { sp.upcoming.indices.contains($0) ? sp.upcoming[$0].uid : nil }
                            ids.forEach { sp.remove(uid: $0) }
                        }
                    } header: {
                        HStack {
                            Text("Up Next · \(sp.upcoming.count) songs")
                            Spacer()
                            Button("Clear") { sp.clearUpcoming() }.buttonStyle(.borderless).disabled(sp.upcoming.isEmpty)
                        }
                    } footer: {
                        Text("Drag to reorder · right-click to remove · double-click to play").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if np.bundle == "com.spotify.client" && !np.title.isEmpty {
                SpotifyQueueList(np: np)
            } else if !np.title.isEmpty {
                List {
                    Section("Now Playing") { Text("\(np.title) — \(np.artist)") }
                    Section("Up Next (read-only for this player)") {
                        ForEach(Array(external.enumerated()), id: \.offset) { _, t in
                            VStack(alignment: .leading) { Text(t.0); Text(t.1).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                .task(id: np.title) { await loadExternal() }
            } else {
                ContentUnavailableView("Nothing queued", systemImage: "text.line.first.and.arrowtriangle.forward",
                                       description: Text("Play an album or playlist, or use Play Next / Add to Queue."))
            }
        }
        .navigationTitle("Up Next")
    }

    func trackRow(_ t: StreamTrack, playing: Bool) -> some View {
        HStack(spacing: 12) {
            TrackCover(url: t.cover)
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title).fontWeight(playing ? .semibold : .regular).lineLimit(1)
                Text("\(t.artist) — \(t.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if playing { Image(systemName: sp.isPlaying ? "speaker.wave.2.fill" : "pause.fill").foregroundStyle(.secondary) }
            Text(mmss(Int(t.duration))).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    func loadExternal() async {
        if np.bundle == "com.spotify.client" {
            external = await withCheckedContinuation { c in
                libraryJSON(["queue", "spotify"]) { obj, _ in
                    c.resume(returning: (obj as? [[String: Any]])?.map { ($0["title"] as? String ?? "", $0["artist"] as? String ?? "") } ?? [])
                }
            }
        }
    }
}

/// Spotify's Up Next, laid out like our own queue: drag to reorder, right-click to remove, double-click to play.
struct SpotifyQueueList: View {
    @ObservedObject var np: NowPlayingModel
    @ObservedObject var q = SpotifyQueue.shared
    @State private var note: String?
    var body: some View {
        List {
            Section("Now Playing") {
                HStack(spacing: 12) {
                    TrackCover(url: nil, image: np.art)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(np.title).fontWeight(.semibold).lineLimit(1)
                        Text(np.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: np.playing ? "speaker.wave.2.fill" : "pause.fill").foregroundStyle(.secondary)
                }
            }
            Section {
                if let e = q.error {
                    Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else if q.loaded && q.items.isEmpty {
                    Text("Nothing queued after this song").foregroundStyle(.secondary)
                }
                ForEach(q.items) { t in
                    HStack(spacing: 12) {
                        TrackCover(url: t.image, plain: true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).lineLimit(1)
                            Text(t.album.isEmpty ? t.artist : "\(t.artist) — \(t.album)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(mmss(Int(t.duration))).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { q.jump(id: t.id, report) }
                    .contextMenu {
                        Button("Play Now") { q.jump(id: t.id, report) }
                        Button("Remove from Queue", role: .destructive) { q.remove(id: t.id, report) }
                    }
                }
                .onMove { from, to in
                    var ids = q.items.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    q.reorder(ids, report)
                }
                .onDelete { offs in
                    if let i = offs.first, q.items.indices.contains(i) { q.remove(id: q.items[i].id, report) }
                }
            } header: {
                HStack {
                    Text("Up Next · Spotify · \(q.items.count) songs")
                    Spacer()
                    if q.busy { ProgressView().controlSize(.small) }
                    Button { q.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                    Button("Clear") { q.clear(report) }.buttonStyle(.borderless).disabled(q.items.isEmpty)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Drag to reorder · right-click to remove · double-click to play").font(.caption).foregroundStyle(.secondary)
                    Text("Spotify can't edit its queue directly, so an edit mutes Spotify for a few seconds, skips through the queue to empty it, then plays the current song again from the same spot followed by your edited list. Shuffle turns off, and the original playlist doesn't continue afterwards (needs Premium).")
                        .font(.caption).foregroundStyle(.tertiary)
                    if let note { Text(note).font(.caption).foregroundStyle(.orange) }
                }
            }
        }
        .task(id: np.title) { q.refresh() }
    }
    func report(_ err: String?) { note = err }
}

struct TrackCover: View {
    let url: URL?
    var image: NSImage? = nil              // already loaded (Now Playing)
    var plain = false                      // not a Subsonic URL: no Subsonic user agent
    @State private var img: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
            if let i = image ?? img { Image(nsImage: i).resizable().aspectRatio(contentMode: .fill) }
        }
        .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            guard let url else { return }
            var req = URLRequest(url: url)
            if !plain { req.setValue(Subsonic.userAgent, forHTTPHeaderField: "User-Agent") }
            if let (d, _) = try? await URLSession.shared.data(for: req) { img = NSImage(data: d) }
        }
    }
}


// MARK: - Synced lyrics (reads the daemon's lrclib cache + playback position)

final class LyricsModel: ObservableObject {
    @Published var lines: [(t: Double, text: String)] = []
    @Published var current = -1
    @Published var title = ""
    @Published var artist = ""
    private var key = ""
    private var nextRetry = Date.distantPast
    private var state: (elapsed: Double, anchor: Double, rate: Double) = (0, 0, 0)
    private var timer: Timer?
    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }
    deinit { timer?.invalidate() }

    var position: Double { state.elapsed + (Date().timeIntervalSince1970 - state.anchor) * state.rate + cfg.lyricOffset }

    func poll() {
        guard let d = FileManager.default.contents(atPath: home + "/state.json"),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
        let t = j["title"] as? String ?? "", a = j["artist"] as? String ?? ""
        state = ((j["elapsed"] as? NSNumber)?.doubleValue ?? 0, (j["anchor"] as? NSNumber)?.doubleValue ?? 0,
                 (j["rate"] as? NSNumber)?.doubleValue ?? 0)
        let k = "\(a)|\(t)".lowercased()
        if k != key {
            key = k; title = t; artist = a; current = -1
            lines = load(k)
        } else if lines.isEmpty && !t.isEmpty, Date() >= nextRetry {
            nextRetry = Date().addingTimeInterval(1)   // the daemon may still be fetching them; once a second is plenty
            lines = load(k)
        }
        let p = position
        let i = lines.lastIndex { $0.t <= p } ?? -1
        if i != current { current = i }
    }

    private func load(_ k: String) -> [(t: Double, text: String)] {
        let hash = Insecure.MD5.hash(data: Data(k.utf8)).map { String(format: "%02x", $0) }.joined()
        guard let d = FileManager.default.contents(atPath: home + "/cache/\(hash).json"),
              let arr = try? JSONSerialization.jsonObject(with: d) as? [[Any]] else { return [] }
        return arr.compactMap { e in
            guard e.count >= 2, let t = (e[0] as? NSNumber)?.doubleValue else { return nil }
            return (t, e[1] as? String ?? "")
        }
    }
}

struct LyricsView: View {
    @StateObject var m = LyricsModel()
    var body: some View {
        Group {
            if m.title.isEmpty {
                ContentUnavailableView("Nothing playing", systemImage: "quote.bubble")
            } else if m.lines.isEmpty {
                ContentUnavailableView("No synced lyrics", systemImage: "quote.bubble",
                                       description: Text("\(m.title) — \(m.artist)"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.title).font(.title.bold())
                                Text(m.artist).font(.title3).foregroundStyle(.secondary)
                            }
                            .padding(.bottom, 20)
                            ForEach(Array(m.lines.enumerated()), id: \.offset) { i, l in
                                Text(l.text.isEmpty ? "♪" : l.text)
                                    .font(.system(size: 26, weight: .bold))
                                    .foregroundStyle(i == m.current ? Color.primary : Color.secondary.opacity(i < m.current ? 0.35 : 0.55))
                                    .scaleEffect(i == m.current ? 1.0 : 0.97, anchor: .leading)
                                    .animation(.easeOut(duration: 0.25), value: m.current)
                                    .id(i)
                                    .onTapGesture { transport(.seek(max(0, l.t - cfg.lyricOffset))) }
                                    .help("Jump here")
                            }
                        }
                        .padding(.horizontal, 40).padding(.vertical, 60)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: m.current) { _, i in
                        withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(max(0, i), anchor: .center) }
                    }
                }
            }
        }
        .navigationTitle("Lyrics")
    }
}
