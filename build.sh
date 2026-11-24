#!/bin/zsh
# Build LyricsBar into an .app bundle.
#   ./build.sh                 → build/LyricsBar.app
#   ./build.sh "<out.app>"     → any bundle path (e.g. "$HOME/Applications/LyricsBar Beta.app"; a name
#                                 containing "Beta" makes the app call itself "LyricsBar Beta")
# The new bundle is built next to the target and swapped in only if the build succeeds,
# so a failed build never leaves a broken app behind.
# Signing: set LYRICSBAR_SIGN_ID to a code-signing identity (SHA-1 or name) to sign with it;
# otherwise the app is ad-hoc signed. A stable identity means the Keychain "Always Allow"
# survives app restarts (macOS still asks once per new build unless the certificate is Apple-issued).
set -euo pipefail
cd "${0:A:h}"
APP="${1:-build/LyricsBar.app}"
mkdir -p "${APP:h}"
NEW="${APP%.app}.building.app"
rm -rf "$NEW"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"
cp Resources/Info.plist "$NEW/Contents/Info.plist"
if [[ "${APP:t}" == *Beta* ]]; then                # the Beta shows up as "LyricsBar Beta"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName LyricsBar Beta" -c "Add :CFBundleDisplayName string LyricsBar Beta" "$NEW/Contents/Info.plist"
fi
cp Resources/AppIcon.icns "$NEW/Contents/Resources/AppIcon.icns"
if ! swiftc -O Sources/*.swift -o "$NEW/Contents/MacOS/LyricsBar"; then
  rm -rf "$NEW"; echo "build failed; $APP was left unchanged" >&2; exit 1
fi
codesign --force --identifier com.crispy.lyricsbar -s "${LYRICSBAR_SIGN_ID:--}" "$NEW"
rm -rf "$APP"
mv "$NEW" "$APP"
touch "$APP"          # so Finder / the Dock pick up a changed icon
echo "built: $APP"
