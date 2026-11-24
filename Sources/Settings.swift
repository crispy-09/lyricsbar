// Settings window (SwiftUI): behaviour, appearance, pinned playlists, Subsonic playlist manager, accounts.
import SwiftUI
import AppKit

// MARK: - Window

/// Settings now live in the main LyricsBar window (sidebar → Settings). This keeps the old entry points working.
final class SettingsWindow {
    static let shared = SettingsWindow()
    func toggle() { LibraryWindow.shared.toggle(settings: true) }
    func show(_ section: SettingsSection = .general) { LibraryWindow.shared.show(settings: section) }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General", appearance = "Appearance", providers = "Providers"
    case discord = "Discord"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .providers: return "square.stack.3d.up"
        case .discord: return "bubble.left.and.bubble.right"
        }
    }
}

/// The settings page for a sidebar section.
struct SettingsDetail: View {
    let section: SettingsSection
    var body: some View {
        switch section {
        case .general: GeneralPane()
        case .appearance: AppearancePane()
        case .providers: ProvidersPane()
        case .discord: DiscordPane()
        }
    }
}

// MARK: - Simple panes

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.01
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(format(value)).monospacedDigit().frame(width: 56, alignment: .trailing).foregroundStyle(.secondary)
            }
        }
    }
}

struct GeneralPane: View {
    @ObservedObject var store = ConfigStore.shared
    var secs: (Double) -> String = { String(format: "%.0fs", $0) }
    var body: some View {
        Form {
            Section("Playback") {
                Picker("When nothing is loaded, ▶ starts", selection: $store.c.defaultApp) {
                    Text("Subsonic").tag("subsonic"); Text("Spotify").tag("spotify")
                    Text("Apple Music").tag("applemusic"); Text("Nothing (open the picker)").tag("ask")
                }
                Text(store.c.defaultApp == "subsonic"
                     ? "Resumes your last LyricsBar queue, or shuffles your Liked Songs."
                     : "Also stops macOS from opening Apple Music when you press play with nothing loaded.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Shuffle Subsonic playlists by default", isOn: $store.c.defaultShuffle)
                Toggle("Pause other players when starting a playlist", isOn: $store.c.pauseOthers)
                Toggle("Resume the LyricsBar queue after a restart (paused)", isOn: $store.c.resumeQueue)
                LabeledSlider(title: "Crossfade", value: $store.c.crossfadeSeconds, range: 0...12, step: 0.5,
                              format: { $0 == 0 ? "Off" : String(format: "%.1fs", $0) })
                Text("Fades between songs in Subsonic playlists played by LyricsBar. Other players use their own settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Lyrics gestures") {
                Picker("Tap on lyrics", selection: $store.c.lyricTapAction) {
                    Text("Play / Pause").tag("pause"); Text("Show controls").tag("controls"); Text("Nothing").tag("none")
                }
                Picker("Hold on lyrics", selection: $store.c.lyricHoldAction) {
                    Text("Play / Pause").tag("pause"); Text("Show controls").tag("controls"); Text("Nothing").tag("none")
                }
                Text("Show controls opens the scrubber with play, skip and the queue. Swipe left or right to skip songs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Touch Bar sleep") {
                Picker("Let the Touch Bar sleep", selection: $store.c.barSleepMinutes) {
                    Text("Like macOS (after about a minute)").tag(0.0)
                    Text("After 2 minutes").tag(2.0); Text("After 5 minutes").tag(5.0)
                    Text("After 10 minutes").tag(10.0); Text("After 15 minutes").tag(15.0)
                    Text("After 30 minutes").tag(30.0); Text("After 1 hour").tag(60.0)
                    Text("Never").tag(-1.0)
                }
                if store.c.barSleepMinutes != 0 {
                    Toggle("Only keep it awake while music plays", isOn: $store.c.barAwakeOnlyWhilePlaying)
                    Text("Counted from your last keyboard or trackpad use. macOS has no separate Touch Bar timer, so this also keeps your screen from sleeping for that long.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Auto-hide after") {
                LabeledSlider(title: "Media controls", value: $store.c.mediaAutoHide, range: 3...30, step: 1, format: secs)
                LabeledSlider(title: "Playlist picker", value: $store.c.pickerAutoHide, range: 5...60, step: 1, format: secs)
                LabeledSlider(title: "Brightness / volume slider", value: $store.c.panelAutoHide, range: 2...20, step: 1, format: secs)
            }
            Section("App") {
                Toggle("Show menu bar icon", isOn: $store.c.showMenuBarIcon)
                LabeledContent("Lyrics service") {
                    Button("Restart") { run("/bin/launchctl", ["kickstart", "-k", "gui/\(getuid())/com.crispy.touchbar-lyrics"]) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

struct LyricsSections: View {
    @ObservedObject var store = ConfigStore.shared
    var body: some View {
        Group {
            Section("Lyrics") {
                LabeledSlider(title: "Font size", value: $store.c.lyricFontSize, range: 11...20, step: 0.5,
                              format: { String(format: "%.1f pt", $0) })
                Picker("Alignment", selection: $store.c.lyricAlignment) {
                    Text("Left").tag("left"); Text("Centre").tag("center")
                }
                Picker("Line change", selection: $store.c.lyricTransition) {
                    Text("Slide").tag("slide"); Text("Fade").tag("fade"); Text("None").tag("none")
                }
                Toggle("Show song title when there are no synced lyrics", isOn: $store.c.showTitleWhenNoLyrics)
            }
            Section("Lyrics timing") {
                LabeledSlider(title: "Timing offset", value: $store.c.lyricOffset, range: -2...2, step: 0.05,
                              format: { String(format: "%+.2fs", $0) })
                Text("Positive shows each line earlier. Use it if lyrics feel late.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Title cards") {
                LabeledSlider(title: "Song title card", value: $store.c.titleCardSeconds, range: 0...10, step: 0.5,
                              format: { $0 == 0 ? "Off" : String(format: "%.1fs", $0) })
                Text("When a new song starts, its title and artist show for this long before the lyrics.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledSlider(title: "“Next” card before song ends", value: $store.c.outroSeconds, range: 0...20, step: 1,
                              format: { $0 == 0 ? "Off" : String(format: "%.0fs", $0) })
                Text("Near the end of a song its title comes back with the next song on the right, which slides in when the song changes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct AppearancePane: View {
    var secs: (Double) -> String = { String(format: "%.0fs", $0) }
    @ObservedObject var store = ConfigStore.shared
    var color: Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hex: store.c.solidColor) ?? .black) },
                set: { store.c.solidColor = NSColor($0).hexString })
    }
    var body: some View {
        Form {
            Section("Background") {
                Picker("Style", selection: $store.c.backgroundStyle) {
                    Text("Wallpaper").tag("wallpaper")
                    Text("Album art").tag("album")
                    Text("Solid colour").tag("solid")
                }
                .pickerStyle(.segmented)
                if store.c.backgroundStyle != "solid" {
                    Text("With a rotating wallpaper the bar goes black: macOS doesn't say which picture is showing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.c.backgroundStyle == "solid" {
                    ColorPicker("Colour", selection: color, supportsOpacity: false)
                } else {
                    LabeledSlider(title: "Blur", value: $store.c.blurAmount, range: 0...40, step: 1,
                                  format: { String(format: "%.0f", $0) })
                    LabeledSlider(title: "Brightness", value: $store.c.targetBrightness, range: 0.05...0.6)
                    LabeledSlider(title: "Saturation", value: $store.c.saturation, range: 0...2.5)
                }
                LabeledSlider(title: "Darken", value: $store.c.dimAmount, range: 0...0.7)
                Picker("After pausing, keep the cover for", selection: $store.c.artLinger) {
                    Text("3 seconds").tag(3.0); Text("10 seconds").tag(10.0); Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0); Text("5 minutes").tag(300.0); Text("Until something else plays").tag(-1.0)
                }
                if store.c.backgroundStyle == "album" {
                    Text("Uses the current song's cover, blurred. Falls back to your wallpaper when there's no artwork.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            LyricsSections()
            Section("While paused") {
                Picker("The bar shows", selection: $store.c.pausedShows) {
                    Text("The lyrics (as now)").tag("lyrics")
                    Text("Media controls").tag("controls")
                    Text("Title and artist").tag("title")
                    Text("Rotating quotes").tag("quotes")
                    Text("My own phrase").tag("phrase")
                }
                if store.c.pausedShows != "lyrics" {
                    LabeledSlider(title: "After pausing for", value: $store.c.pausedDelay, range: 0...15, step: 1, format: secs)
                }
                switch store.c.pausedShows {
                case "controls":
                    Text("The scrubber and buttons stay up until you play again.").font(.caption).foregroundStyle(.secondary)
                case "phrase":
                    TextField("Phrase", text: $store.c.pausedPhrase, prompt: Text("Paused · {title}"))
                    Text("{title} and {artist} are filled in.").font(.caption).foregroundStyle(.secondary)
                case "quotes":
                    LabeledSlider(title: "Next quote every", value: $store.c.pausedQuoteSeconds, range: 60...600, step: 60,
                                  format: { let m = Int(($0 / 60).rounded()); return m == 1 ? "1 min" : "\(m) min" })
                    Toggle("Include the built-in music quotes", isOn: $store.c.pausedBuiltinQuotes)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your quotes, one per line")
                        TextEditor(text: $store.c.pausedQuotes)
                            .font(.body).frame(minHeight: 70).scrollContentBackground(.hidden)
                            .padding(4).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                        Text("Write \"quote — author\" to show who said it.").font(.caption).foregroundStyle(.secondary)
                    }
                default: EmptyView()
                }
            }
            VisualizerSections()
            Section("Buttons") {
                Picker("Style", selection: $store.c.buttonStyle) {
                    Text("Minimal").tag("minimal"); Text("Pill").tag("pill")
                }
                .pickerStyle(.segmented)
                Toggle("Brightness", isOn: $store.c.showBrightness)
                Toggle("Volume", isOn: $store.c.showVolume)
                Toggle("Library", isOn: $store.c.showApps)
            }
            Section("Extras") {
                Toggle("Song progress line along the bottom edge", isOn: $store.c.showProgress)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
    }
}

struct VisualizerSections: View {
    @ObservedObject var store = ConfigStore.shared
    var body: some View {
        Group {
            Section("Visualizer") {
                Picker("Style", selection: $store.c.visualizerStyle) {
                    Text("Off").tag("off"); Text("Behind lyrics").tag("background"); Text("Compact").tag("compact")
                }
                .pickerStyle(.segmented)
                Text("Behind lyrics: faint bars across the whole bar. Compact: a small equalizer next to the album art.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.c.visualizerStyle != "off" {
                Section {
                    Picker("Colour", selection: $store.c.visualizerColor) {
                        Text("White").tag("white"); Text("From album art").tag("album")
                    }
                    LabeledSlider(title: "Sensitivity", value: $store.c.visualizerSensitivity, range: 0.4...2.5)
                    if store.c.visualizerStyle == "background" {
                        LabeledSlider(title: "Opacity", value: $store.c.visualizerOpacity, range: 0.05...0.8)
                    }
                }
                Section {
                    Text("The visualizer listens to your Mac's audio output (macOS asks once for “system audio recording” permission). Audio is analysed on the fly and never stored. It only runs while music is playing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}


// MARK: - Pinned playlists

struct PlaylistRow: Identifiable, Hashable { let id: String; let name: String; let count: Int }

func loadPlaylists(_ provider: String) async -> Result<[PlaylistRow], Error> {
    if provider == "subsonic" {
        do { return .success(try await Subsonic.playlists().map { PlaylistRow(id: $0.id, name: $0.name, count: $0.songCount) }) }
        catch { return .failure(error) }
    }
    return await withCheckedContinuation { cont in
        libraryJSON(["playlists", provider]) { obj, err in
            if let list = obj as? [[String: Any]] {
                cont.resume(returning: .success(list.map {
                    PlaylistRow(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "?",
                                count: ($0["count"] as? NSNumber)?.intValue ?? 0)
                }))
            } else {
                cont.resume(returning: .failure(SubsonicError(message: (err ?? "").contains("isn't connected")
                    ? "Spotify isn't connected. Connect it under Providers." : (err ?? "Couldn't load playlists"))))
            }
        }
    }
}

// MARK: - Subsonic playlist manager

@MainActor final class SubsonicManager: ObservableObject {
    @Published var playlists: [SPlaylist] = []
    @Published var selected: String?
    @Published var songs: [SSong] = []
    @Published var results: [SSong] = []
    @Published var error: String?
    @Published var busy = false

    func run(_ work: @escaping () async throws -> Void) {
        Task {
            busy = true; error = nil
            do { try await work() } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    func reloadPlaylists() {
        run {
            self.playlists = try await Subsonic.playlists()
            if self.selected == nil { self.selected = self.playlists.first?.id }
        }
    }
    func reloadSongs() {
        guard let id = selected else { songs = []; return }
        run { self.songs = try await Subsonic.playlist(id).1 }
    }
    func create(_ name: String) {
        run { try await Subsonic.create(name); self.playlists = try await Subsonic.playlists()
              self.selected = self.playlists.last { $0.name == name }?.id }
    }
    func rename(_ id: String, _ name: String) {
        run { try await Subsonic.rename(id, name); self.playlists = try await Subsonic.playlists()
              ConfigStore.shared.c.pinned = ConfigStore.shared.c.pinned.map {
                  $0.provider == "subsonic" && $0.playlistId == id ? PinnedPlaylist(provider: "subsonic", playlistId: id, name: name) : $0 } }
    }
    func delete(_ id: String) {
        run { try await Subsonic.delete(id); self.selected = nil; self.songs = []
              ConfigStore.shared.c.pinned.removeAll { $0.provider == "subsonic" && $0.playlistId == id }
              self.playlists = try await Subsonic.playlists() }
    }
    func remove(_ offsets: IndexSet) {
        guard let id = selected else { return }
        run { try await Subsonic.remove(id, indexes: Array(offsets)); self.songs = try await Subsonic.playlist(id).1
              self.playlists = try await Subsonic.playlists() }
    }
    func move(_ from: IndexSet, _ to: Int) {
        guard let id = selected else { return }
        songs.move(fromOffsets: from, toOffset: to)
        let ids = songs.map(\.id)
        run { try await Subsonic.setSongs(id, ids) }
    }
    func add(_ s: SSong) {
        guard let id = selected else { return }
        run { try await Subsonic.add(id, songs: [s.id]); self.songs = try await Subsonic.playlist(id).1
              self.playlists = try await Subsonic.playlists() }
    }
    func search(_ q: String) {
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else { results = []; return }
        run { self.results = try await Subsonic.search(q) }
    }
}

func mmss(_ s: Int) -> String {
    s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// Edit a Subsonic playlist: reorder, remove, search to add, rename, delete. Opened from Library → Playlists.
struct PlaylistEditor: View {
    @StateObject var m = SubsonicManager()
    @ObservedObject var store = ConfigStore.shared
    let playlistId: String
    var onClose: () -> Void
    @State var query = ""
    @State var nameDraft = ""
    @State var showRename = false
    @State var confirmDelete = false

    var current: SPlaylist? { m.playlists.first { $0.id == m.selected } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(current?.name ?? "Playlist").font(.title2.bold()).lineLimit(1).truncationMode(.tail)
                    if let p = current { Text("\(p.songCount) songs · \(mmss(p.duration))").foregroundStyle(.secondary) }
                }
                .layoutPriority(1)
                Spacer()
                if m.busy { ProgressView().controlSize(.small) }
                if let p = current {
                    Button { store.togglePin("subsonic", p.id, p.name) } label: {
                        Label(store.isPinned("subsonic", p.id) ? "Pinned" : "Pin",
                              systemImage: store.isPinned("subsonic", p.id) ? "pin.fill" : "pin")
                    }
                    Button("Rename…") { nameDraft = p.name; showRename = true }
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                }
                Button("Done") { onClose() }.keyboardShortcut(.defaultAction)
            }
            if let e = m.error { Text(e).foregroundStyle(.red) }
            List {
                ForEach(Array(m.songs.enumerated()), id: \.element.uid) { i, s in
                    HStack {
                        Text("\(i + 1)").foregroundStyle(.secondary).monospacedDigit().frame(width: 28, alignment: .trailing)
                        VStack(alignment: .leading) {
                            Text(s.title)
                            Text("\(s.artist) — \(s.album)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(mmss(s.duration)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .contextMenu { Button("Remove from playlist", role: .destructive) { m.remove(IndexSet(integer: i)) } }
                }
                .onMove { m.move($0, $1) }
                .onDelete { m.remove($0) }
            }
            .frame(minHeight: 200)
            Text("Drag to reorder · right-click a song to remove it").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search your library to add songs…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { m.search(query) }
            }
            if !m.results.isEmpty {
                List(m.results, id: \.uid) { s in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(s.title)
                            Text("\(s.artist) — \(s.album)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { m.add(s) } label: { Image(systemName: "plus.circle.fill") }.buttonStyle(.borderless)
                    }
                }
                .frame(minHeight: 120, maxHeight: 200)
            }
        }
        .padding()
        .frame(minWidth: 620, minHeight: 560)
        .onAppear { m.selected = playlistId; m.reloadPlaylists(); m.reloadSongs() }
        .alert("Rename playlist", isPresented: $showRename) {
            TextField("Name", text: $nameDraft)
            Button("Rename") { m.rename(playlistId, nameDraft) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(current?.name ?? "")” from your server?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { m.delete(playlistId); onClose() }
        }
    }
}

// MARK: - Accounts

struct AccountsSections: View {
    var changed: () -> Void = {}
    @State var server = Subsonic.auth?.server ?? ""
    @State var user = Subsonic.auth?.u ?? ""
    @State var password = ""
    @State var subStatus = Subsonic.auth == nil ? "Not connected" : "Connected"
    @State var subBusy = false
    @State var clientId = AccountsSections.spotifyClientId() ?? ""
    @State var spStatus = AccountsSections.spotifyClientId() == nil ? "Not connected" : "Connected"
    @State var spBusy = false

    static func spotifyClientId() -> String? {
        Creds.get("spotify")?["client_id"]
    }

    var body: some View {
        Group {
            Section("Subsonic account") {
                LabeledContent("Status", value: subStatus)
                TextField("Server", text: $server, prompt: Text("https://music.example.com"))
                TextField("Username", text: $user)
                SecureField("Password", text: $password)
                HStack {
                    Button("Sign In") { subsonic { try await Subsonic.login(server: server, user: user, password: password) } }
                        .disabled(server.isEmpty || user.isEmpty || password.isEmpty)
                    if subBusy { ProgressView().controlSize(.small) }
                }
                Text("Only a salted token is saved, in your login Keychain. Your password is never stored.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Spotify account") {
                LabeledContent("Status", value: spStatus)
                TextField("Client ID", text: $clientId)
                HStack {
                    Button(spStatus == "Connected" ? "Reconnect" : "Connect") { connectSpotify() }.disabled(clientId.isEmpty || spBusy)
                    Button("Disconnect") {
                        Creds.set("spotify", nil); spStatus = "Not connected"; changed()
                    }
                    if spBusy { ProgressView().controlSize(.small) }
                }
                Text("Create an app at developer.spotify.com with redirect URI http://127.0.0.1:8898/callback. Reconnect once to enable Up Next for Spotify.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func subsonic(_ work: @escaping () async throws -> Void) {
        subBusy = true
        Task { @MainActor in
            do {
                try await work()
                subStatus = "Connected"; password = ""
                server = Subsonic.auth?.server ?? server; user = Subsonic.auth?.u ?? user
                changed()
            } catch { subStatus = "Failed: \(error.localizedDescription)" }
            subBusy = false
        }
    }

    func connectSpotify() {
        spBusy = true; spStatus = "Waiting for you to approve in the browser…"
        let id = clientId.trimmingCharacters(in: .whitespaces)
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-I", home + "/library.py", "spotify-login", id]
            let pipe = Pipe(), input = Pipe()
            p.standardOutput = pipe; p.standardError = pipe; p.standardInput = input
            try? p.run()
            try? input.fileHandleForWriting.close()          // nothing to send; new tokens come back on stdout
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            let last = out.split(separator: "\n").last.map(String.init) ?? ""
            let j = (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any]
            if p.terminationStatus == 0, let j { Creds.absorb(fromHelper: j) }
            DispatchQueue.main.async {
                spBusy = false
                spStatus = p.terminationStatus == 0 && Creds.get("spotify") != nil ? "Connected" : "Failed: " + last
                changed()
            }
        }
    }
}

// MARK: - Colour helpers

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}


// MARK: - Providers

struct ProvidersPane: View {
    @ObservedObject var store = ConfigStore.shared
    @State private var rev = 0      // bumps after sign-in so the status badges refresh
    var body: some View {
        Form {
            Section {
                row("Subsonic", icon: "server.rack", on: $store.c.showSubsonic,
                    status: Subsonic.auth.map { "Signed in as \($0.u)" } ?? "Not signed in", ready: Subsonic.auth != nil,
                    detail: "Streams your server's playlists in LyricsBar (crossfade, editable queue, Liked Songs).")
                row("Spotify", icon: "dot.radiowaves.left.and.right", on: $store.c.showSpotify,
                    status: Creds.get("spotify") != nil ? "Connected" : "Not connected",
                    ready: Creds.get("spotify") != nil,
                    detail: "Lists your playlists and Liked Songs; plays them in the Spotify app.")
                row("Apple Music", icon: "music.note", on: $store.c.showAppleMusic,
                    status: FileManager.default.fileExists(atPath: "/System/Applications/Music.app") ? "Uses the Music app" : "Not installed",
                    ready: FileManager.default.fileExists(atPath: "/System/Applications/Music.app"),
                    detail: "Lists your Music playlists and plays them in the Music app. macOS asks once to let LyricsBar control Music.")
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "waveform").frame(width: 22).foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TIDAL").foregroundStyle(.secondary)
                        Text("Not available: the TIDAL Mac app can't be controlled by other apps. Lyrics and controls still work while it plays.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: .constant(false)).labelsHidden().disabled(true)
                }
            } header: {
                Text("Shown in the Touch Bar picker").id(rev)
            } footer: {
                Text("Lyrics, the album art and media controls work with any player, whether or not it's listed here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrobbleSections()
            AccountsSections(changed: { rev += 1 })
        }
        .formStyle(.grouped)
        .navigationTitle("Providers")
    }

    func row(_ name: String, icon: String, on: Binding<Bool>, status: String, ready: Bool, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                    Text(status).font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background((ready ? Color.green : Color.orange).opacity(0.18), in: SwiftUI.Capsule())
                        .foregroundStyle(ready ? .green : .orange)
                }
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: on).labelsHidden()
        }
    }
}


// MARK: - Scrobbling

struct ScrobbleSections: View {
    @ObservedObject var store = ConfigStore.shared
    @State private var lfKey = LastFM.creds?["api_key"] ?? ""
    @State private var lfSecret = ""
    @State private var lfUser = LastFM.user
    @State private var lfStatus = ""
    @State private var lfBusy = false
    @State private var lbToken = ""
    @State private var lbUser = ListenBrainz.user
    @State private var lbStatus = ""
    @State private var lbBusy = false

    var body: some View {
        Group {
            Section {
                Text("You can scrobble either way: let Navidrome forward your plays (link Last.fm / ListenBrainz in Navidrome under your profile → Personal settings), or have LyricsBar send them directly below. Pick one per service; doing both counts every song twice. Either way a song counts after you've heard half of it or 4 minutes. This covers songs played by LyricsBar; Spotify can scrobble through Last.fm's own Spotify connection.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Report plays to your Subsonic server", isOn: $store.c.reportPlays)
                Text("Updates Navidrome's play counts and Recently Played, and forwards to any services linked there.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Scrobbling") }

            Section("Last.fm (direct)") {
                if let u = lfUser {
                    LabeledContent("Account", value: u)
                    Toggle("Scrobble to Last.fm", isOn: $store.c.scrobbleLastfm)
                    Button("Disconnect") { LastFM.disconnect(); lfUser = nil; store.c.scrobbleLastfm = false }
                } else {
                    TextField("API key", text: $lfKey)
                    SecureField("Shared secret", text: $lfSecret)
                    HStack {
                        Button("Connect…") { connectLastfm() }.disabled(lfKey.isEmpty || lfSecret.isEmpty || lfBusy)
                        if lfBusy { ProgressView().controlSize(.small) }
                        if !lfStatus.isEmpty { Text(lfStatus).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("Create an API account at last.fm/api/account/create (any name; leave the callback URL empty), paste its key and secret, then approve LyricsBar in the browser.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("ListenBrainz (direct)") {
                if let u = lbUser {
                    LabeledContent("Account", value: u)
                    Toggle("Scrobble to ListenBrainz", isOn: $store.c.scrobbleListenBrainz)
                    Button("Disconnect") { ListenBrainz.disconnect(); lbUser = nil; store.c.scrobbleListenBrainz = false }
                } else {
                    SecureField("User token", text: $lbToken)
                    HStack {
                        Button("Connect") { connectListenBrainz() }.disabled(lbToken.isEmpty || lbBusy)
                        if lbBusy { ProgressView().controlSize(.small) }
                        if !lbStatus.isEmpty { Text(lbStatus).font(.caption).foregroundStyle(.secondary) }
                    }
                    Text("Copy your token from listenbrainz.org/settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    func connectLastfm() {
        lfBusy = true; lfStatus = "Approve LyricsBar in your browser…"
        let k = lfKey.trimmingCharacters(in: .whitespaces), s = lfSecret.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            do { lfUser = try await LastFM.connect(apiKey: k, secret: s); lfStatus = ""; lfSecret = ""; store.c.scrobbleLastfm = true }
            catch { lfStatus = error.localizedDescription }
            lfBusy = false
        }
    }
    func connectListenBrainz() {
        lbBusy = true; lbStatus = ""
        let t = lbToken.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            do { lbUser = try await ListenBrainz.connect(token: t); lbToken = ""; store.c.scrobbleListenBrainz = true }
            catch { lbStatus = error.localizedDescription }
            lbBusy = false
        }
    }
}


// MARK: - Discord Rich Presence

struct DiscordPane: View {
    @ObservedObject var store = ConfigStore.shared
    @ObservedObject var presence = DiscordPresence.shared
    @State private var snap: DiscordPresence.Snapshot?
    let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Show what I'm listening to on Discord", isOn: $store.c.discordEnabled)
                LabeledContent("Status", value: presence.status)
                TextField("Application ID", text: $store.c.discordAppId, prompt: Text("e.g. 1234567890123456789"))
                Text("""
                    Discord needs an application to show presence under. Create one at discord.com/developers/applications \
                    (name it what you want people to see, like "LyricsBar"), then copy its Application ID here. \
                    Works with the Discord app and with Vesktop (turn on Rich Presence / arRPC in Vesktop's settings).
                    """).font(.caption).foregroundStyle(.secondary)
            }
            Section("What it says") {
                Picker("Activity", selection: $store.c.discordType) {
                    Text("Listening to …").tag("listening"); Text("Playing …").tag("playing")
                }
                TextField(store.c.discordType == "playing" ? "Top line: Playing …" : "Top line: Listening to …",
                          text: $store.c.discordName, prompt: Text("empty = your Discord app's name"))
                TextField("First line", text: $store.c.discordLine1)
                TextField("Second line", text: $store.c.discordLine2)
                TextField("Picture hover text", text: $store.c.discordHover)
                Picker("Member list shows", selection: $store.c.discordStatusDisplay) {
                    Text("Top line").tag("app"); Text("First line").tag("details"); Text("Second line").tag("state")
                }
                Text("The top line works in Vesktop; the official Discord app always shows your application's name there. Use \(DiscordPresence.placeholders.joined(separator: " ")) anywhere. {lyric} is the current line (it changes every few seconds; Discord only updates about every 4 s). Empty fields are dropped, so \"by {artist}\" disappears when there's no artist.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Details") {
                Toggle("Show the progress bar", isOn: $store.c.discordTimestamps)
                Picker("When paused", selection: $store.c.discordWhenPaused) {
                    Text("Hide it").tag("hide"); Text("Show \"Paused\"").tag("show")
                }
                Picker("Players", selection: $store.c.discordPlayers) {
                    Text("All except Spotify").tag("noSpotify"); Text("All players").tag("all")
                    Text("Only LyricsBar's player").tag("own")
                }
                Text("Spotify already shows its own Discord presence, so it's skipped by default to avoid showing the song twice.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show album art (looked up on Apple's public iTunes Search)", isOn: $store.c.discordAlbumArt)
                TextField("Fallback picture", text: $store.c.discordImage, prompt: Text("asset name or https:// link (optional)"))
                Text("Your Subsonic covers can't be shown: their links contain your login. The album-art lookup sends only the artist and album name to Apple.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Preview") {
                if let a = presence.activity(for: snap, store.c) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text((store.c.discordType == "playing" ? "Playing " : "Listening to ") + ((a["name"] as? String) ?? "<your Discord app's name>"))
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        if let d = a["details"] as? String { Text(d).font(.body.weight(.semibold)) }
                        if let s = a["state"] as? String { Text(s).foregroundStyle(.secondary) }
                        if a["timestamps"] != nil { ProgressView(value: 0.35).frame(maxWidth: 220) }
                    }
                } else {
                    Text(snap == nil ? "Nothing is playing." : "Hidden right now (paused, or this player is excluded).")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Discord")
        .onAppear { snap = DiscordPresence.shared.snapshot() }
        .onReceive(refresh) { _ in snap = DiscordPresence.shared.snapshot() }
    }
}
