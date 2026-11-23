#!/bin/zsh
# Build LyricsBar into an .app bundle.
#   ./build.sh                 → build/LyricsBar.app
#   ./build.sh "<out.app>"     → any bundle path (e.g. "$HOME/Applications/LyricsBar Beta.app")
# Signing: set LYRICSBAR_SIGN_ID to a code-signing identity (SHA-1 or name) to sign with it;
# otherwise the app is ad-hoc signed. A stable identity means the Keychain "Always Allow"
# survives app restarts (macOS still asks once per new build unless the certificate is Apple-issued).
set -euo pipefail
cd "${0:A:h}"
APP="${1:-build/LyricsBar.app}"
mkdir -p "$APP/Contents/MacOS"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swiftc -O Sources/*.swift -o "$APP/Contents/MacOS/LyricsBar"
codesign --force --identifier com.crispy.lyricsbar -s "${LYRICSBAR_SIGN_ID:--}" "$APP"
echo "built: $APP"
