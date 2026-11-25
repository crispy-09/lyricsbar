#!/bin/zsh
# Install LyricsBar, or update an existing install. Safe to run again after `git pull`:
# your settings, saved queue, lyrics cache and logins are kept (they live in ~/.touchbar-lyrics
# and the Keychain, which this script never overwrites).
#
#  • app            → ~/Applications/LyricsBar.app (the Beta, if you build one, is LyricsBar Beta.app)
#                     ~/.touchbar-lyrics/active.app links to the one that runs (switch.sh stable|beta)
#  • helper scripts → ~/.touchbar-lyrics/ (lyricsd.py, library.py, switch.sh)
#  • LaunchAgents   → ~/Library/LaunchAgents (start at login, restart if they quit)
#
# Optional: LYRICSBAR_SIGN_ID=<code-signing identity> ./install.sh
# The identity is remembered for later updates (in ~/.touchbar-lyrics/sign-id; it's a certificate
# fingerprint, not a secret).
set -euo pipefail
cd "${0:A:h}"
DATA="$HOME/.touchbar-lyrics"
APPS="$HOME/Applications"
STABLE="$APPS/LyricsBar.app"
OLDSTABLE="$APPS/LyricsBar Stable.app"          # where older versions installed it
ACTIVE="$DATA/active.app"
UID_=$(id -u)

ver() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null || echo "?"; }
OLD=""
if [[ -d "$OLDSTABLE" ]]; then OLD=$(ver "$OLDSTABLE"); elif [[ -d "$STABLE" ]]; then OLD=$(ver "$STABLE"); fi
# older versions: ~/Applications/LyricsBar.app was a symlink to "LyricsBar Stable.app" or "LyricsBar Beta.app"
WAS_BETA=""
if [[ -L "$STABLE" ]]; then
  [[ "$(readlink "$STABLE")" == *Beta* ]] && WAS_BETA=1
fi

# what it needs, before touching anything
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "error: the Swift compiler is missing. Install the Xcode Command Line Tools first: xcode-select --install" >&2; exit 1
fi
if [[ ! -x /usr/bin/python3 ]] || ! /usr/bin/python3 -c 1 2>/dev/null; then
  echo "error: /usr/bin/python3 is missing. Install the Xcode Command Line Tools first: xcode-select --install" >&2; exit 1
fi

mkdir -p "$DATA" "$APPS" "$HOME/Library/LaunchAgents"
chmod 700 "$DATA"

# signing identity: from the environment, else the one used last time (if it still exists)
if [[ -n "${LYRICSBAR_SIGN_ID:-}" ]]; then
  print -r -- "$LYRICSBAR_SIGN_ID" > "$DATA/sign-id"; chmod 600 "$DATA/sign-id"
elif [[ -s "$DATA/sign-id" ]]; then
  id=$(<"$DATA/sign-id")
  if security find-identity -p codesigning 2>/dev/null | grep -q -- "$id"; then
    export LYRICSBAR_SIGN_ID="$id"
  else
    echo "note: saved signing identity not found; signing ad-hoc"
  fi
fi

# 1. build first (if this fails, the running install is untouched)
./build.sh "$STABLE"                              # replaces an old symlink at that path with the real app
[[ -d "$OLDSTABLE" ]] && rm -rf "$OLDSTABLE"
if [[ ! -L "$ACTIVE" ]] || [[ ! -d "$ACTIVE/" ]]; then
  if [[ -n "$WAS_BETA" && -d "$APPS/LyricsBar Beta.app" ]]; then ln -sfn "$APPS/LyricsBar Beta.app" "$ACTIVE"
  else ln -sfn "$STABLE" "$ACTIVE"; fi
fi

# 2. helper scripts (only code is replaced; config.json, queue.json, cache/ etc. are left alone)
install -m 755 scripts/lyricsd.py scripts/library.py scripts/switch.sh "$DATA/"

# 3. LaunchAgents: (re)load so the new versions start now
for t in lyricsbar lyricsd; do
  label=$( [[ $t == lyricsbar ]] && echo com.crispy.lyricsbar || echo com.crispy.touchbar-lyrics )
  dst="$HOME/Library/LaunchAgents/$label.plist"
  sed "s|__HOME__|$HOME|g" "launchd/$t.plist.in" > "$dst"
  launchctl bootout "gui/$UID_/$label" 2>/dev/null || true   # LyricsBar saves its queue on the way out
  for i in 1 2 3 4 5; do                                        # bootout finishes asynchronously
    launchctl bootstrap "gui/$UID_" "$dst" 2>/dev/null && break
    sleep 1
  done
  launchctl print "gui/$UID_/$label" >/dev/null 2>&1 || echo "warning: couldn't start $label (try: launchctl bootstrap gui/$UID_ $dst)"
done

NEWV=$(ver "$STABLE")
if [[ -n "$OLD" ]]; then echo "LyricsBar updated ($OLD → $NEWV). Your settings, queue and logins were kept."
else echo "LyricsBar $NEWV installed. Hold the album art on the Touch Bar to open Settings."; fi
if [[ "$(readlink "$ACTIVE")" == *Beta* ]]; then
  echo "note: you're running the Beta build; switch with: ~/.touchbar-lyrics/switch.sh stable"
fi
if [[ ! -x /opt/homebrew/bin/media-control && ! -x /usr/local/bin/media-control ]] && ! command -v media-control >/dev/null 2>&1; then
  echo ""
  echo "WARNING: media-control isn't installed, so LyricsBar can't see what's playing (no song info, no lyrics)."
  echo "         Install it with: brew install media-control   (LyricsBar picks it up by itself)"
  echo ""
fi
echo "If macOS asks for your Keychain password, choose \"Always Allow\" (LyricsBar waits for that before loading your logins)."
