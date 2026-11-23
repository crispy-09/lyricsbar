#!/bin/zsh
# Switch the Touch Bar between LyricsBar Stable and Beta:  switch.sh stable|beta
# ~/Applications/LyricsBar.app is a symlink to whichever one is active (the LaunchAgent runs that path).
case "$1" in
  stable) T="LyricsBar Stable.app" ;;
  beta)   T="LyricsBar Beta.app" ;;
  *) echo "usage: switch.sh stable|beta"; exit 1 ;;
esac
cd "$HOME/Applications" && ln -sfn "$T" LyricsBar.app
launchctl kickstart -k gui/$(id -u)/com.crispy.lyricsbar
echo "now running: $T"
