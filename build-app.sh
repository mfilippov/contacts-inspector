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
# Ключи Telegram API: из окружения (TELEGRAM_API_ID/TELEGRAM_API_HASH, так делает CI)
# или из локального telegram-api.env (не в git; см. telegram-api.env.example).
if [[ -z "${TELEGRAM_API_ID:-}" && -f telegram-api.env ]]; then
    source telegram-api.env
fi
if [[ -n "${TELEGRAM_API_ID:-}" && -n "${TELEGRAM_API_HASH:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :TelegramApiId integer $TELEGRAM_API_ID" \
        -c "Add :TelegramApiHash string $TELEGRAM_API_HASH" "$APP/Contents/Info.plist"
    echo "Ключи Telegram API встроены"
else
    echo "Ключи Telegram API не заданы — в приложении будет ручной ввод"
fi
codesign --force --sign - "$APP"
echo "Готово: $APP"
