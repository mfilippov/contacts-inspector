import Contacts
import Foundation

/// Поля, которые можно перенести из Telegram в контакт Apple.
enum TGImportField: String, CaseIterable, Identifiable {
    case givenName, familyName, phone, photo, birthday, bio
    var id: String { rawValue }

    var title: String {
        switch self {
        case .givenName: "Имя"
        case .familyName: "Фамилия"
        case .phone: "Телефон"
        case .photo: "Фото"
        case .birthday: "День рождения"
        case .bio: "О себе → в заметку"
        }
    }
}

/// Данные из Telegram, собранные для переноса.
struct TGImportSource {
    var user: TGUser
    var full: TGFullInfo?
    var photo: Data?

    func value(_ f: TGImportField) -> String {
        switch f {
        case .givenName: user.firstName
        case .familyName: user.lastName
        case .phone: user.phoneDisplay
        case .photo: photo == nil ? "" : "есть"
        case .birthday: full?.birthdate ?? ""
        case .bio: full?.bio ?? ""
        }
    }
}

enum TelegramImport {
    /// Текущее значение поля в контакте Apple (для сравнения в окне переноса).
    static func appleValue(_ f: TGImportField, _ r: ContactRecord, source: TGImportSource) -> String {
        switch f {
        case .givenName: return r.givenName
        case .familyName: return r.familyName
        case .phone:
            if let same = r.phoneNumbers.first(where: { TelegramLink.samePhone($0.value, source.user.phone) }) {
                return same.value + " (уже есть)"
            }
            return r.phoneNumbers.map(\.value).joined(separator: ", ")
        case .photo: return r.hasImage ? "есть" : ""
        case .birthday:
            guard let b = r.birthday else { return "" }
            return [b.day, b.month, b.year].compactMap { $0 }.map { String(format: "%02d", $0) }.joined(separator: ".")
        case .bio: return r.note ?? ""
        }
    }

    /// Поля, отмеченные по умолчанию: значение в Telegram есть, а в Apple пусто.
    /// Телефон — если такого номера в Apple ещё нет; заметку без явного выбора не трогаем.
    static func defaultFields(_ r: ContactRecord, source: TGImportSource) -> Set<TGImportField> {
        Set(TGImportField.allCases.filter { f in
            guard !source.value(f).isEmpty else { return false }
            let apple = appleValue(f, r, source: source)
            switch f {
            case .phone: return !apple.hasSuffix("(уже есть)")
            case .bio: return false
            default: return apple.isEmpty
            }
        })
    }

    /// Применяет выбранные поля к копии контакта и прописывает связь с Telegram.
    /// Заметку (bio) здесь не трогаем — её пишет вызывающий код (через AppleScript).
    static func apply(_ fields: Set<TGImportField>, from s: TGImportSource, to c: CNContact) -> CNMutableContact {
        let m = c.mutableCopy() as! CNMutableContact
        fill(m, fields: fields, from: s, existingPhones: c.phoneNumbers.map { $0.value.stringValue })
        let linked = m.copy() as! CNContact   // с уже перенесёнными полями
        TelegramLink.setLink(m, from: linked, user: s.user)
        return m
    }

    /// Новый контакт Apple из пользователя Telegram (все доступные поля + связь).
    static func makeContact(from s: TGImportSource) -> CNMutableContact {
        let m = CNMutableContact()
        fill(m, fields: Set(TGImportField.allCases).subtracting([.bio]), from: s, existingPhones: [])
        if m.givenName.isEmpty && m.familyName.isEmpty, let un = s.user.username { m.nickname = un }
        TelegramLink.setLink(m, from: m.copy() as! CNContact, user: s.user)
        return m
    }

    private static func fill(_ m: CNMutableContact, fields: Set<TGImportField>, from s: TGImportSource,
                             existingPhones: [String]) {
        let u = s.user
        if fields.contains(.givenName), !u.firstName.isEmpty { m.givenName = u.firstName }
        if fields.contains(.familyName) { m.familyName = u.lastName }
        if fields.contains(.phone), !u.phone.isEmpty {
            if !existingPhones.contains(where: { TelegramLink.samePhone($0, u.phone) }) {
                m.phoneNumbers = m.phoneNumbers + [CNLabeledValue(label: CNLabelPhoneNumberMobile,
                                                                  value: CNPhoneNumber(stringValue: u.phoneDisplay))]
            }
        }
        if fields.contains(.photo), let photo = s.photo { m.imageData = photo }
        if fields.contains(.birthday), let b = s.full?.birthday { m.birthday = b }
    }

    /// Новая заметка: к существующей дописываем bio, если его там ещё нет.
    static func mergedNote(existing: String?, bio: String) -> String {
        let old = existing ?? ""
        if bio.isEmpty || old.contains(bio) { return old }
        return old.isEmpty ? bio : old + "\n\n" + bio
    }
}
