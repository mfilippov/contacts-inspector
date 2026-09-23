#!/bin/zsh
# Собирает "build/Contacts Inspector.app" (release, ad-hoc подпись).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="build/Contacts Inspector.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/ContactsInspector" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Готово: $APP"
