#!/bin/zsh
# Regenerates Resources/AppIcon.icns from make_icon.swift (rendered fresh at every size for crisp small icons).
set -euo pipefail
cd "${0:A:h}"
T=$(mktemp -d); SET="$T/AppIcon.iconset"; mkdir "$SET"
for s in 16 32 128 256 512; do
  swift make_icon.swift "$SET/icon_${s}x${s}.png" $s >/dev/null
  swift make_icon.swift "$SET/icon_${s}x${s}@2x.png" $((s*2)) >/dev/null
done
swift make_icon.swift icon_1024.png 1024 >/dev/null
iconutil -c icns "$SET" -o ../AppIcon.icns
rm -rf "$T"
echo "wrote Resources/AppIcon.icns"
