#!/bin/zsh
# Собирает "build/Contacts Inspector.app" (release, ad-hoc подпись).
set -euo pipefail
cd "$(dirname "$0")"
# Иконка пересобирается отдельно: scripts/make-icon.sh
swift build -c release
APP="build/Contacts Inspector.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/ContactsInspector" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Готово: $APP"
