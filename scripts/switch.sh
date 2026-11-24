#!/bin/zsh
# Switch the Touch Bar between LyricsBar (stable) and LyricsBar Beta:  switch.sh stable|beta
# ~/.touchbar-lyrics/active.app links to whichever one is active (the LaunchAgent runs that path).
case "$1" in
  stable) T="LyricsBar.app" ;;
  beta)   T="LyricsBar Beta.app" ;;
  *) echo "usage: switch.sh stable|beta"; exit 1 ;;
esac
APP="$HOME/Applications/$T"
if [[ ! -d "$APP" || -L "$APP" ]]; then
  echo "$T isn't installed. Build it with: ./build.sh \"\$HOME/Applications/$T\""; exit 1
fi
ln -sfn "$APP" "$HOME/.touchbar-lyrics/active.app"
launchctl kickstart -k gui/$(id -u)/com.crispy.lyricsbar
echo "now running: $T"
