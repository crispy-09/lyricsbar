#!/bin/zsh
# Build and install LyricsBar for the current user:
#  • app            → ~/Applications/LyricsBar Stable.app (+ ~/Applications/LyricsBar.app symlink)
#  • helper scripts → ~/.touchbar-lyrics/ (lyricsd.py, library.py, switch.sh)
#  • LaunchAgents   → ~/Library/LaunchAgents (start at login, restart if they quit)
set -euo pipefail
cd "${0:A:h}"
DATA="$HOME/.touchbar-lyrics"
mkdir -p "$DATA" "$HOME/Applications" "$HOME/Library/LaunchAgents"
chmod 700 "$DATA"
./build.sh "$HOME/Applications/LyricsBar Stable.app"
[[ -e "$HOME/Applications/LyricsBar.app" ]] || ln -s "LyricsBar Stable.app" "$HOME/Applications/LyricsBar.app"
install -m 755 scripts/lyricsd.py scripts/library.py scripts/switch.sh "$DATA/"
for t in lyricsbar lyricsd; do
  label=$( [[ $t == lyricsbar ]] && echo com.crispy.lyricsbar || echo com.crispy.touchbar-lyrics )
  dst="$HOME/Library/LaunchAgents/$label.plist"
  sed "s|__HOME__|$HOME|g" "launchd/$t.plist.in" > "$dst"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$dst"
done
echo "LyricsBar installed. Open Settings by holding the album art on the Touch Bar."
