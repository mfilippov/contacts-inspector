#!/bin/zsh
# Собирает "build/Contacts Inspector.app" (ad-hoc подпись).
# По умолчанию release — без отладочных инструментов и журнала.
# CONFIG=debug ./build-app.sh — отладочная сборка: журнал ~/Library/Logs/ContactsInspector.log и DebugTools.
set -euo pipefail
cd "$(dirname "$0")"
# Иконка пересобирается отдельно: scripts/make-icon.sh
CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
APP="build/Contacts Inspector.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c "$CONFIG" --show-bin-path)/ContactsInspector" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# Версия: из тега v* (VERSION=1.2.3 или тег GitHub Actions), иначе остаётся из Info.plist.
VERSION="${VERSION:-}"
if [[ -z "$VERSION" && "${GITHUB_REF_TYPE:-}" == tag ]]; then VERSION="${GITHUB_REF_NAME#v}"; fi
if [[ -n "$VERSION" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
        -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$APP/Contents/Info.plist"
fi
# Ключи Telegram API: из окружения (TELEGRAM_API_ID/TELEGRAM_API_HASH, так делает CI)
# или из локального telegram-api.env (не в git; см. telegram-api.env.example).
if [[ -z "${TELEGRAM_API_ID:-}" && -f telegram-api.env ]]; then
    source telegram-api.env
fi
if [[ -n "${TELEGRAM_API_ID:-}" && -n "${TELEGRAM_API_HASH:-}" ]]; then
    if [[ "$TELEGRAM_API_ID" == 123456 || "$TELEGRAM_API_HASH" == 0123456789abcdef0123456789abcdef ]]; then
        echo "В telegram-api.env остались значения из примера — впишите свои ключи с https://my.telegram.org/apps" >&2
        exit 1
    fi
    /usr/libexec/PlistBuddy -c "Add :TelegramApiId integer $TELEGRAM_API_ID" \
        -c "Add :TelegramApiHash string $TELEGRAM_API_HASH" "$APP/Contents/Info.plist"
    echo "Ключи Telegram API встроены"
elif [[ -n "${TELEGRAM_API_ID:-}${TELEGRAM_API_HASH:-}" ]]; then
    echo "Задан только один из TELEGRAM_API_ID / TELEGRAM_API_HASH" >&2
    exit 1
else
    echo "Ключи Telegram API не заданы — в приложении будет ручной ввод"
fi
codesign --force --sign - "$APP"
echo "Готово ($CONFIG): $APP"
