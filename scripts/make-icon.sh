#!/bin/zsh
# Пересобирает Resources/AppIcon.icns из scripts/make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
swift scripts/make-icon.swift "$TMP/icon.png"
mkdir "$TMP/AppIcon.iconset"
for sz in 16 32 128 256 512; do
    sips -z $sz $sz "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${sz}x${sz}.png" >/dev/null
    sips -z $((sz*2)) $((sz*2)) "$TMP/icon.png" --out "$TMP/AppIcon.iconset/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$TMP/AppIcon.iconset" -o Resources/AppIcon.icns
rm -rf "$TMP"
echo "Готово: Resources/AppIcon.icns"
