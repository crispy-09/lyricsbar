# AGENTS.md

Notes for coding agents (and humans) working on LyricsBar.

## Layout

- `Sources/main.swift`: the app entry point.
  - **Touch Bar layer:** private DFR calls, `App` (the app delegate) and `BarView` (the whole Touch Bar UI).
  - **`StreamPlayer`:** the built-in Subsonic player, with two AVPlayers for crossfade, a uid-based queue and `queue.json` persistence.
  - **Helpers:** transport routing (`transport()` / `ownPlayerInCharge()`), `LikedCache`, `ScrubBar` and the picker (`TBPicker`).
- `Sources/TouchQueue.swift`: the layer-based Up Next strip (fling, hold-drag reorder, trash), plus `LyricTouchArea` and `SlideOverlay`.
- `Sources/Library.swift`: the main window, with SwiftUI `NavigationSplitView`.
  - The sidebar mixes library sections and Settings sections (`SidebarItem`).
  - `LibraryWindow.toggle(settings:)` backs the 📚 button and the hold on the album art.
- `Sources/Settings.swift`: the Settings panes (General, Appearance, Providers, Discord), plus `PlaylistEditor` (a sheet opened from Library → Playlists). `SettingsWindow` is now just a shim onto `LibraryWindow`.
- `Sources/Config.swift`: `Config` (Codable) is stored in `~/.touchbar-lyrics/config.json`. `lyricsd.py` reads it too.
  - New fields need a default value; `Config.load()` merges the file over the defaults.
- `Sources/Subsonic.swift`: the Subsonic API client.
  - Use `txt()` for every user-visible string; it decodes HTML entities that some servers leave in.
- `Sources/Keychain.swift`: `Creds`, one login-Keychain item (service `com.crispy.lyricsbar`, account `credentials`) holding JSON with the `subsonic`, `spotify`, `lastfm` and `listenbrainz` entries.
- `Sources/Scrobble.swift`: Last.fm and ListenBrainz clients, plus the `ScrobbleQueue` actor (persisted retry queue).
- `Sources/DiscordIPC.swift`: a standalone Discord RPC client. It speaks the Unix-socket protocol: handshake, `SET_ACTIVITY`, ping/pong. It works with Discord and with Vesktop's arRPC.
- `Sources/Discord.swift`: `DiscordPresence`.
  - It builds the activity from the same sources the bar uses (`state.json`, or `StreamPlayer` when that's in charge).
  - It's driven from `App.tick()`, evaluates once per second and sends at most once every 4 s (Discord's rate limit).
  - Never put Subsonic cover URLs in presence: they carry the token.
- `Sources/SpotifyQueue.swift`: Spotify's Up Next, editable in both UIs. Edits go through `library.py spotify-jump` and `spotify-replace`, which replays the current song plus the edited list.
  - IDs stay stable across refreshes, keyed by uri plus occurrence.
  - Edits run one at a time; later edits are merged into the next replay.
  - While Spotify plays, edits only change `items` and set `pending`; a 0.25 s timer sends them (`spotify-replace --start`, which plays the list instead of replaying the current song) when ≤ 1.5 s remain, when the song changes, or at once (keep-current mode) when paused. Refreshes don't overwrite `items` while pending. Play Now while pending starts the shown list from that song. A song change only applies held edits if the new song is Spotify's own next (`expectedNext`) or the old song was within 4 s of its end; anything else (other music, another player for 5 s, picking a playlist) cancels them (`cancelPending`).
  - Before acting on a trigger, `checkPending` confirms it with the Spotify app (`appState`, AppleScript): Now Playing has fired false "song ending/changed" alarms mid-song. Decisions go to `~/.touchbar-lyrics/spotify-queue.log` (song names only, last 200 lines). Held edits are saved to `spotify-pending.json` and restored at launch if the same song is still playing.
  - `library.py` uses AppleScript (volume, `next track`) only when the active device is this Mac's Spotify app (`_spotify_local`), never launching it; otherwise the Web API. `spotify_replace` re-pauses a paused song in `finally`, and never mutes without a known volume to restore.
  - A replay alone doesn't work: songs added with "Add to queue" live in a separate queue that survives `PUT /me/player/play`. So `spotify_replace` mutes Spotify, skips (AppleScript `next track`) through everything queued, plays the current song + the new list, pauses again if it was paused, seeks back, then unmutes. It checks the result and drains again (up to 3 rounds), since the queue listing shows only ~20 songs.
  - While the bar's Up Next shows Spotify, `followSpotifyQueue()` reloads it on song change and every 6 s.
  - `QueueStrip.onClear`: swiping right at the start of the list reveals a red Clear pill.
- `Sources/Visualizer.swift`: `AudioTap` (FFT into band levels) and `VisualizerView`. The audio source is:
  - LyricsBar's own player: `MTAudioProcessingTap` on each `AVPlayerItem`
  - other apps: a Core Audio process tap on that app's processes
  - fallback: a whole-system tap
- `scripts/lyricsd.py`: the lyrics daemon.
  - It runs `media-control stream`, then writes `state.json`, `artwork.jpg` and `current.txt` (the current lyric line).
  - The Now Playing feed often doesn't announce seeks, so the app writes `seek.json` (`noteSeek`) on every seek and lyricsd resets its clock from it.
  - It caches LRC in `cache/<md5(artist|title)>.json`.
- `Resources/`: `Info.plist` (bump `CFBundleShortVersionString` for releases; `install.sh` prints old → new) and `AppIcon.icns`.
  - The icon is drawn in code by `Resources/icon/make_icon.swift`. Regenerate the `.icns` with `Resources/icon/make_icns.sh`.
- `build.sh` builds into `<name>.building.app` and swaps it in only on success. `install.sh` is also the updater: it never touches `~/.touchbar-lyrics` data or the Keychain, and it remembers the signing identity in `~/.touchbar-lyrics/sign-id`.
- `scripts/library.py`: the playlist CLI the app calls.
  - It gets credentials as JSON on **stdin** and returns refreshed tokens as `{"__result": …, "__creds": …}`.
  - It must never write credentials to disk.

## Build and run

```sh
./build.sh "$HOME/Applications/LyricsBar Beta.app"   # build into the Beta slot
~/.touchbar-lyrics/switch.sh beta                     # run it (the LaunchAgent runs ~/.touchbar-lyrics/active.app, a link)
launchctl kickstart -k gui/$(id -u)/com.crispy.lyricsbar   # restart
```

- When calling `swiftc` by hand, list the files explicitly or use a glob. zsh does not word-split `$VARS`.
- Pass `LYRICSBAR_SIGN_ID` to sign with a stable identity. Every new build changes the code hash, so the Keychain asks once per build. **The app blocks at launch until that dialog is answered.** Check with `pgrep -l SecurityAgent`.
- Batch changes before rebuilding; every build means another Keychain prompt for the user.

## Testing without a finger

The app has debug hooks: write a command to `~/.touchbar-lyrics/debug.cmd`, then send `pkill -HUP -x LyricsBar`. Most commands write their output to `~/.touchbar-lyrics/debug.out`.

| Command | Effect |
| --- | --- |
| `menu`, `pick N` | Open the picker, choose item N |
| `media` | Show the media controls |
| `apps` | Press the 📚 button |
| `arthold` | Hold the album art |
| `library <Section>` | Open a Library section (`Up Next`, `Lyrics`, `Search`, `Liked Songs`, `Albums`, `Artists`, `Playlists`, `Spotify`) |
| `settings <Section>` | Open a Settings section (`General`, `Appearance`, `Providers`, `Discord`). Playlists, including pins and editing, live in `library Playlists` |
| `qstate` | Write the queue state |
| `viz` | Write the visualizer frames and levels |
| `toast <text>`, `text <s>`, `qpreview` | UI checks |
| `discordtest <socket>` / `discordtest off` | Turn presence on against a fake Discord socket (test app ID), then back off. This changes the config, so always run `off` afterwards |
| `discordpreview` | Write the activity that would be sent, plus the status |
| `spq`, `spq skip N`, `spq remove N`, `spq move A B`, `spq clear` | Read or edit Spotify's Up Next through `SpotifyQueue`, then write the queue to `debug.out`. **Edits change real playback.** Spotify must be playing, because its API returns an empty queue for an idle device |
| `spqpl`, `spqpl N` | List Spotify playlists, or queue playlist N (the picker's hold action). **This changes the real queue**, so use a small playlist |
| `regular on` / `regular off` | Hand the Touch Bar to macOS (as the strip's "regular Touch Bar" button does) / take it back |
| `playingshows lyrics\|controls\|title`, `buttons on\|off`, `kbd`, `more` (toggle the ‹ extras), `outro` (show Up Next now with a sample next song), `swipe DX [back]` (simulated drag on the lyric; `back` returns to the middle), `lyricstate` (lyric label state to debug.out) | Set what the bar shows while playing; show/hide all optional strip buttons (keyboard light, Siri, Screenshot, regular bar); read the keyboard backlight. These change the config |
| `mutedtest` | Muted playback self-test (play, next, seek, crossfade, previous, pause, restore). No sound, no scrobbles; the log goes to `debug.out` |

Other signals: `SIGUSR1` toggles the media controls and `SIGUSR2` opens the volume slider.

Screenshots:
- Touch Bar: `screencapture -b out.png`
- Windows: `screencapture -o -l <windowID>`

**Gotchas:**

- **Never loop `pkill -HUP`** while the app may be (re)starting. A SIGHUP that arrives before the handler is installed kills it (exit 129), and launchd crash-loops.
- **Don't drive playback through `transport()` in tests.** It controls whichever app is Now Playing, which could be the user's Spotify or Music. Call `StreamPlayer` directly with `testMuted = true` (as `mutedtest` does).
- **Don't start audible playback** or send real scrobbles without asking the user.
- **Don't test Spotify queue edits (`spotify-jump` / `spotify-replace`) on the user's account.** They change real playback.
- **Apps can't keep the Touch Bar awake.** TouchBarServer (root) turns it off ~75 s after the last *hardware* input. Tried and failed: `IOPMAssertionDeclareUserActivity` (keeps the screen on only), `DFRSetStatus(1)` (ignored), synthetic `CGEvent`s (reset `HIDIdleTime` but not the bar's timer), and CoreBrightness `suspendIdleDimming` (keyboard backlight only). The old "Touch Bar sleep" setting was removed for this reason.
- **No top-level `let`/`var` after the run loop starts in `main.swift`.** Code below `app.run()` never runs, so such a global stays uninitialised and crashes when read. Put constants in a type's `static let`.

## Touch Bar quirks

- `NSButton.contentTintColor` is ignored on the Touch Bar. Use `coloredSymbol(name, size, color)`, which bakes the colour in with `isTemplate = false`.
- Touches only carry horizontal movement. There's no vertical swipe information.
- The system-modal window is 1004pt wide but `BarView` is 1000pt. `BarView.layout()` compensates so centred lyrics stay centred.
- macOS only lists an app as Now Playing after it has produced sound. Until then, `App.useOwnPlayerFallback()` drives the bar from `StreamPlayer` directly. The Library footer does the same thing.
- An accessory app needs an Edit menu in `NSApp.mainMenu` for ⌘V to work in text fields (`installMainMenu()`).

## Security rules

- Credentials go **only** through `Creds` (Keychain). Never write them to files, logs, `NSLog`, process arguments or environment variables.
- Subsonic URLs contain the auth token (`t`/`s` query parameters).
  - Keep `URLCache` memory-only.
  - Don't log those URLs.
  - Don't persist them; `queue.json` stores cover IDs, not URLs.
- Files in `~/.touchbar-lyrics` must not contain secrets. The directory is mode 700.
- Build AppleScript and Spotify URIs only from sanitised IDs (`spotifySafe()`), never from raw names.
- Never commit anything from `~/.touchbar-lyrics`: config, queue, state, cache, logs, or signing keys.
