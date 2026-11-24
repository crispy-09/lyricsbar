<p align="center"><img src="Resources/icon/icon_1024.png" width="160" alt="LyricsBar icon"></p>

# LyricsBar

Synced lyrics, album art and media controls on the MacBook Pro Touch Bar, plus a built-in Subsonic / Navidrome player with a library window.

LyricsBar takes over the Touch Bar's control strip area with:

- **Live, line-synced lyrics** for whatever is playing (Spotify, Apple Music, browsers, LyricsBar's own player, any app that reports Now Playing to macOS). Lyrics come from [LRCLIB](https://lrclib.net).
- **Album art** and a background that takes its colour from the cover, with an optional audio visualizer.
- **Media controls**: a scrubber, skip, like, shuffle/repeat, and a swipeable, reorderable Up Next queue.
- **A playlist picker** for Subsonic, Spotify and Apple Music, with pinned playlists.
- **A built-in Subsonic/Navidrome player** with crossfade, an editable queue that survives restarts, Liked Songs (stars), and scrobbling.
- **Discord Rich Presence** with customizable text ("Listening to …", your own templates, an optional lyric line). It works with the Discord app and Vesktop.
- **A Library window** for Up Next, full lyrics, search, Liked Songs, albums, artists and playlists, with Settings in the same window.

## Requirements

- A Mac with a Touch Bar, running macOS 14.2 or later
- Xcode Command Line Tools (`xcode-select --install`), for `swiftc` and `/usr/bin/python3`
- [`media-control`](https://github.com/ungive/media-control) (`brew install media-control`), which reads the system Now Playing feed

## Install

```sh
git clone https://github.com/crispy-09/lyricsbar.git
cd lyricsbar
./install.sh
```

`install.sh` does three things:

- builds the app into `~/Applications/LyricsBar Stable.app` and creates a `~/Applications/LyricsBar.app` symlink to it
- copies the helper scripts to `~/.touchbar-lyrics/`
- installs two LaunchAgents: one for the app and one for the lyrics daemon (`lyricsd.py`). Both start at login and restart if they quit.

### Updating

```sh
git pull
./install.sh
```

Running `install.sh` again updates in place:
- It builds the new version first and only swaps it in if the build succeeds.
- It replaces the helper scripts and restarts both services.
- It keeps everything in `~/.touchbar-lyrics` (settings, saved queue, lyrics cache, scrobble queue) and your logins in the Keychain.
- If you signed with `LYRICSBAR_SIGN_ID`, it reuses the same certificate.
- It prints the old and new version.

macOS will ask for **System Audio Recording** permission the first time the visualizer runs on another app's audio. It also asks for **Automation** permission the first time LyricsBar controls Spotify or Music.

### Signing (optional)

`build.sh` ad-hoc signs by default. Credentials are kept in the Keychain, and an ad-hoc signature changes with every build. So macOS asks again after each rebuild, and can ask after restarts too. To make "Always Allow" stick across restarts, sign with a stable identity:

```sh
LYRICSBAR_SIGN_ID="<identity SHA-1 or name>" ./install.sh
```

A self-signed code-signing certificate is enough for restarts. Only an Apple-issued certificate (a free Apple ID "Personal Team" in Xcode works) also avoids the prompt after rebuilds.

## Using it

| On the Touch Bar | Does |
| --- | --- |
| Tap the lyrics | Play / pause (configurable) |
| Hold the lyrics | Show the media controls (configurable) |
| Swipe the lyrics left / right | Next / previous song |
| Tap the album art | Show / hide the media controls, or the playlist picker when nothing is playing |
| Hold the album art | Open / close Settings |
| Tap 📚 | Open / close the Library window |
| Hold a playlist in the picker | Queue it next instead of playing it |
| In Up Next, hold and drag a song | Reorder it, or drop it on the trash to remove it |

Everything else is in **Settings** (Library window sidebar, or ⌘,):

- **General**: what ▶ starts when nothing is loaded, shuffle, resume, crossfade, lyric gestures, auto-hide timers
- **Appearance**: background, lyrics, visualizer, buttons
- **Providers**: the providers shown in the picker, scrobbling, accounts
- **Pinned Playlists** and **Edit Playlists** (Subsonic)

### Providers

- **Subsonic / Navidrome**: sign in with your server URL, username and password. Only a salted token is stored, never the password.
- **Spotify**: create an app at developer.spotify.com with the redirect URI `http://127.0.0.1:8898/callback`, then paste its Client ID under Providers → Spotify. Playback happens in the Spotify app.
- **Apple Music**: uses the Music app through AppleScript.

### Scrobbling

You can scrobble in either of two ways. Pick one per service; using both counts every song twice.

- Let **Navidrome** forward your plays: link Last.fm or ListenBrainz in Navidrome under your profile → Personal settings, and leave "Report plays to your Subsonic server" on.
- Or have **LyricsBar** send them directly. Connect Last.fm (with your own API key and secret) or ListenBrainz (with a user token) under Providers.

A play counts after half the song or 4 minutes, whichever comes first. Plays that can't be sent (offline, server down) are queued and retried every 5 minutes.

### Discord Rich Presence

Settings → **Discord**:

1. Create an application at [discord.com/developers/applications](https://discord.com/developers/applications). Its name is what people see, for example "Listening to **LyricsBar**".
2. Paste its **Application ID** and switch presence on.
3. Vesktop users: turn on Rich Presence (arRPC) in Vesktop's settings.

You can customize:
- the activity type ("Listening to" or "Playing")
- the two text lines and the picture's hover text, using templates with `{title}` `{artist}` `{album}` `{lyric}` `{player}`
- what the member list shows
- the progress bar
- whether it hides or shows "Paused" when paused
- which players count. Spotify is skipped by default because it already has its own presence.

Album art is optional. Subsonic cover links contain your login and are never sent, so the cover is looked up on Apple's public iTunes Search instead, which sends only the artist and album name.

## Privacy and security

- All credentials (the Subsonic token, Spotify tokens, Last.fm session and ListenBrainz token) are kept in a single item in your **login Keychain**. The Python helper receives them on stdin when it runs and never writes them to disk.
- Subsonic request URLs include an auth token, so LyricsBar's HTTP cache is **memory-only**.
- `~/.touchbar-lyrics/` holds settings, the saved queue, cached lyrics and the scrobble queue (song names only), and is readable only by you.
- The visualizer reads LyricsBar's own player directly. For other apps it taps only that app's audio, and only while music plays and the visualizer is on. Audio is analysed for levels and never stored.
- Network requests go only to your Subsonic server and `lrclib.net`, plus Spotify / Last.fm / ListenBrainz if you connect them and Apple's iTunes Search if you turn on Discord album art.
- Discord presence goes over the local Discord socket only, and only while it's switched on.

## Stable and Beta

`~/Applications/LyricsBar.app` is a symlink to either `LyricsBar Stable.app` or `LyricsBar Beta.app`, so you can try a build without losing a known-good one:

```sh
./build.sh "$HOME/Applications/LyricsBar Beta.app"
~/.touchbar-lyrics/switch.sh beta     # or: stable
```

The menu bar icon also has a "Switch to Beta/Stable Version" item.

## Files

| Path | What |
| --- | --- |
| `Sources/` | The Swift app (AppKit Touch Bar UI, SwiftUI Library and Settings) |
| `scripts/lyricsd.py` | Lyrics daemon: follows Now Playing, fetches and caches LRC, writes `state.json` and `artwork.jpg` |
| `scripts/library.py` | Playlist helper for Subsonic, Spotify (including OAuth sign-in) and Apple Music |
| `launchd/` | LaunchAgent templates used by `install.sh` |

## Uninstall

```sh
launchctl bootout gui/$(id -u)/com.crispy.lyricsbar
launchctl bootout gui/$(id -u)/com.crispy.touchbar-lyrics
rm ~/Library/LaunchAgents/com.crispy.lyricsbar.plist ~/Library/LaunchAgents/com.crispy.touchbar-lyrics.plist
rm -rf ~/Applications/LyricsBar*.app ~/.touchbar-lyrics
security delete-generic-password -s com.crispy.lyricsbar -a credentials
```

## License

MIT. See [LICENSE](LICENSE).
