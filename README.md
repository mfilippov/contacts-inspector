# Contacts Inspector

A macOS app for reviewing and cleaning up iCloud/Apple contacts and managing Telegram contacts.
It was built for moving from iPhone to Android: tidy up the address book before exporting it to Google.

## Features

**Apple contacts**
- table of all contacts with columns, sorting, search, and filters by account, field, and problem;
- field fill summary, contact card, full-size photo on click;
- editing all fields, deleting (history of changes: a copy of the contact before each edit);
- merging duplicates: "Possible duplicates" filter (shared phone, email, or first+last name), a merge window
  with a choice of values, multi-value fields merged without repeats;
- transliterating names to Latin ("Cyrillic name" filter, button in the form, bulk action):
  Дмитрий Щукин → Dmitry Shchukin;
- full backup (vCard with photos and notes, JSON, photos) to `~/Documents/Contacts Inspector Backups`
  with a list of backups inside the app.

**Compare accounts** (e.g. iCloud and Google, both connected in macOS)
- matching by phone, email, and name; Differ / Only in A / Only in B / Match modes;
- field-by-field comparison, values of multi-value fields individually with deletion on either side;
  photos compared by image (robust to Google's recompression);
- "A → B" / "B → A": overwrite the pair or copy the missing ones (an exact copy, with history),
  "Photo A → B", "Delete in A / in B".

**Telegram** (as a separate client via [TDLib](https://github.com/tdlib/td))
- sign-in with a QR code or phone number, including the 2FA password;
- contact table: username, ID, chat, auto-delete timer; contact card;
- linking to Apple contacts by phone or ID, in the official Telegram for iPhone format
  (a URL with the `Telegram` label: `https://t.me/@id<ID>`); repairing broken links
  `t.me/@idId(rawValue: …)` left by Telegram in 2021–2022;
- importing fields (name, phone, photo, birthday, bio) into an Apple contact, creating a contact from Telegram;
- editing a Telegram contact's first name, last name, and note; "Name differs" filter (exact
  field-by-field comparison with the Apple contact);
- deleting linked contacts from both sides at once;
- changing the auto-delete timer, deleting contacts from Telegram;
- backing up Telegram contacts along with the rest of the backup.

## Requirements

- macOS 15 or newer (developed and tested on macOS 27);
- Xcode / Swift 6 toolchain.

## Build

```sh
cp telegram-api.env.example telegram-api.env   # keys from https://my.telegram.org/apps
./build-app.sh                                  # → build/Contacts Inspector.app
ditto "build/Contacts Inspector.app" "/Applications/Contacts Inspector.app"
```

Telegram API keys are embedded into `Info.plist` at build time: from the `TELEGRAM_API_ID` /
`TELEGRAM_API_HASH` environment variables or from `telegram-api.env` (not in git). Without keys,
the app asks for them on first sign-in.

Tests: `swift test`. Icon: `scripts/make-icon.sh`.

**CI:** `.github/workflows/build.yml` runs the tests and builds the `.app` (artifact; attached
to a release on a `v*` tag). Keys come from the repository secrets `TELEGRAM_API_ID` and `TELEGRAM_API_HASH`.

## Data

| What | Where |
|---|---|
| Backups | `~/Documents/Contacts Inspector Backups` (configurable) |
| History of changes | `~/Library/Application Support/ContactsInspector/history` |
| TDLib database (encrypted) | `~/Library/Application Support/ContactsInspector/telegram` |
| API keys and database key | Keychain, entry "Contacts Inspector — Telegram API" |
| Action and error log | `~/Library/Logs/ContactsInspector.log` |

## Known limitations

- **Ad-hoc signing.** Without a Developer ID certificate, macOS asks for Contacts and Keychain
  access again after every build; on other Macs Gatekeeper blocks launch.
- **Notes** are read and written through the Contacts app (AppleScript): Contacts.framework
  does not return `note` without the `com.apple.developer.contacts.notes` entitlement, and it cannot
  replace multi-value fields (phones, email, URLs, profiles) of a contact whose note
  exists, even an empty one (error 134092). A note is therefore deleted entirely (`missing value`), not
  written as an empty string; when transferring and merging, the recipient's note is temporarily removed and then restored.
- **Photos:** Contacts.framework does not return the photo for most contacts (only 18 of 586), so photos
  are read through Contacts.app (vCard) in the background after load, which takes ~10 s.
- **Google via CardDAV** stores social profiles lossily (drops the ID and URL, changes the case of the username)
  and drops profiles that have no username.
- **Google photos are not visible from the Mac:** photos are uploaded to Google (they show on contacts.google.com),
  but they do not come back to the Mac. In the table, such contacts show their pair's photo from another account,
  and comparison does not treat a photo "invisible from the Mac" as a difference.
- **macOS 27:** a `Button` inside a `ScrollView` that is the root of `.inspector` does not receive clicks,
  so the cards use `Form(.grouped)`. Minimal example: `repro/InspectorScrollButton`.
- The UI is in Russian only for now.
