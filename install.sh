#!/bin/zsh
# Install LyricsBar, or update an existing install. Safe to run again after `git pull`:
# your settings, saved queue, lyrics cache and logins are kept (they live in ~/.touchbar-lyrics
# and the Keychain, which this script never overwrites).
#
#  • app            → ~/Applications/LyricsBar Stable.app (+ ~/Applications/LyricsBar.app symlink)
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
STABLE="$APPS/LyricsBar Stable.app"
UID_=$(id -u)

ver() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$1/Contents/Info.plist" 2>/dev/null || echo "?"; }
OLD=""
[[ -d "$STABLE" ]] && OLD=$(ver "$STABLE")

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
./build.sh "$STABLE"
[[ -e "$APPS/LyricsBar.app" || -L "$APPS/LyricsBar.app" ]] || ln -s "LyricsBar Stable.app" "$APPS/LyricsBar.app"

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
if [[ "$(readlink "$APPS/LyricsBar.app")" == *Beta* ]]; then
  echo "note: you're running the Beta build; switch with: ~/.touchbar-lyrics/switch.sh stable"
fi
echo "If macOS asks for your Keychain password, choose \"Always Allow\" (LyricsBar waits for that before loading your logins)."
