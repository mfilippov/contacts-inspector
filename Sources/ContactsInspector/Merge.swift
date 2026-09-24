import Contacts
import Foundation

/// Одиночные текстовые поля, значение которых при объединении выбирается из вариантов.
enum MergeScalar: String, CaseIterable, Identifiable {
    case namePrefix, givenName, middleName, familyName, nameSuffix, nickname
    case phoneticGivenName, phoneticFamilyName
    case organizationName, departmentName, jobTitle
    var id: String { rawValue }

    var title: String {
        switch self {
        case .namePrefix: "Префикс"
        case .givenName: "Имя"
        case .middleName: "Отчество"
        case .familyName: "Фамилия"
        case .nameSuffix: "Суффикс"
        case .nickname: "Псевдоним"
        case .phoneticGivenName: "Фонет. имя"
        case .phoneticFamilyName: "Фонет. фамилия"
        case .organizationName: "Организация"
        case .departmentName: "Отдел"
        case .jobTitle: "Должность"
        }
    }

    func get(_ c: CNContact) -> String {
        switch self {
        case .namePrefix: c.namePrefix
        case .givenName: c.givenName
        case .middleName: c.middleName
        case .familyName: c.familyName
        case .nameSuffix: c.nameSuffix
        case .nickname: c.nickname
        case .phoneticGivenName: c.phoneticGivenName
        case .phoneticFamilyName: c.phoneticFamilyName
        case .organizationName: c.organizationName
        case .departmentName: c.departmentName
        case .jobTitle: c.jobTitle
        }
    }

    func set(_ m: CNMutableContact, _ v: String) {
        switch self {
        case .namePrefix: m.namePrefix = v
        case .givenName: m.givenName = v
        case .middleName: m.middleName = v
        case .familyName: m.familyName = v
        case .nameSuffix: m.nameSuffix = v
        case .nickname: m.nickname = v
        case .phoneticGivenName: m.phoneticGivenName = v
        case .phoneticFamilyName: m.phoneticFamilyName = v
        case .organizationName: m.organizationName = v
        case .departmentName: m.departmentName = v
        case .jobTitle: m.jobTitle = v
        }
    }
}

/// Вид многозначного поля.
enum MergeKind: String, CaseIterable {
    case phone, email, url, address, social, im, relation, date

    var title: String {
        switch self {
        case .phone: "Телефоны"
        case .email: "Email"
        case .url: "Сайты"
        case .address: "Адреса"
        case .social: "Соцпрофили"
        case .im: "Мессенджеры"
        case .relation: "Связи"
        case .date: "Даты"
        }
    }
}

/// Значение многозначного поля в объединении. id — ключ дедупликации (вид + нормализованное значение).
struct MergeItem: Identifiable, Hashable {
    let id: String
    let kind: MergeKind
    let label: String
    let text: String
}

enum ContactMerge {
    /// Различные непустые варианты поля; первым идёт значение основного контакта.
    static func variants(_ f: MergeScalar, primary: CNContact, others: [CNContact]) -> [String] {
        var out: [String] = []
        for c in [primary] + others {
            let v = f.get(c)
            if !v.isEmpty, !out.contains(v) { out.append(v) }
        }
        return out
    }

    /// Выбор по умолчанию: значение основного контакта, иначе первое непустое.
    static func defaultChoice(_ f: MergeScalar, primary: CNContact, others: [CNContact]) -> String {
        variants(f, primary: primary, others: others).first ?? ""
    }

    static func birthdayVariants(primary: CNContact, others: [CNContact]) -> [DateComponents] {
        var out: [DateComponents] = []
        for c in [primary] + others {
            guard let b = c.birthday else { continue }
            if !out.contains(where: { $0.day == b.day && $0.month == b.month && $0.year == b.year }) { out.append(b) }
        }
        return out
    }

    /// Все значения многозначных полей без повторов (основной контакт первым).
    static func items(primary: CNContact, others: [CNContact]) -> [MergeItem] {
        var seen = Set<String>()
        var out: [MergeItem] = []
        for c in [primary] + others {
            for (item, _) in labeled(c) where seen.insert(item.id).inserted { out.append(item) }
        }
        return out
    }

    /// Собирает объединённый контакт на основе копии основного.
    /// keep — id элементов многозначных полей, которые нужно сохранить.
    static func build(primary: CNContact, others: [CNContact], scalars: [MergeScalar: String],
                      birthday: DateComponents?, imageData: Data?, keep: Set<String>) -> CNMutableContact {
        let m = primary.mutableCopy() as! CNMutableContact
        for f in MergeScalar.allCases { f.set(m, scalars[f] ?? f.get(primary)) }
        m.birthday = birthday
        m.imageData = imageData

        var phones: [CNLabeledValue<CNPhoneNumber>] = []
        var emails: [CNLabeledValue<NSString>] = []
        var urls: [CNLabeledValue<NSString>] = []
        var addresses: [CNLabeledValue<CNPostalAddress>] = []
        var socials: [CNLabeledValue<CNSocialProfile>] = []
        var ims: [CNLabeledValue<CNInstantMessageAddress>] = []
        var relations: [CNLabeledValue<CNContactRelation>] = []
        var dates: [CNLabeledValue<NSDateComponents>] = []
        var seen = Set<String>()
        for c in [primary] + others {
            let own = c === primary
            for (item, lv) in labeled(c) where keep.contains(item.id) && seen.insert(item.id).inserted {
                // Вид берём из item.kind: приведение `as? CNLabeledValue<T>` не работает — параметр
                // обобщённого класса Objective-C стирается, и «телефоном» оказалось бы любое значение.
                // Значения основного контакта сохраняем как есть (с identifier), чужие — копиями.
                func copy<T>(_ v: CNLabeledValue<T>) -> CNLabeledValue<T> { own ? v : CNLabeledValue(label: v.label, value: v.value) }
                switch item.kind {
                case .phone: phones.append(copy(lv as! CNLabeledValue<CNPhoneNumber>))
                case .email: emails.append(copy(lv as! CNLabeledValue<NSString>))
                case .url: urls.append(copy(lv as! CNLabeledValue<NSString>))
                case .address: addresses.append(copy(lv as! CNLabeledValue<CNPostalAddress>))
                case .social: socials.append(copy(lv as! CNLabeledValue<CNSocialProfile>))
                case .im: ims.append(copy(lv as! CNLabeledValue<CNInstantMessageAddress>))
                case .relation: relations.append(copy(lv as! CNLabeledValue<CNContactRelation>))
                case .date: dates.append(copy(lv as! CNLabeledValue<NSDateComponents>))
                }
            }
        }
        m.phoneNumbers = phones
        m.emailAddresses = emails
        m.urlAddresses = urls
        m.postalAddresses = addresses
        m.socialProfiles = socials
        m.instantMessageAddresses = ims
        m.contactRelations = relations
        m.dates = dates
        return m
    }

    /// Объединённая заметка: различные непустые заметки через пустую строку.
    static func mergedNote(_ notes: [String?]) -> String {
        var out: [String] = []
        for n in notes.compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) where !n.isEmpty && !out.contains(n) {
            out.append(n)
        }
        return out.joined(separator: "\n\n")
    }

    // MARK: - Нормализация

    /// Значения многозначных полей контакта с их ключами (для объединения и удаления отдельных значений).
    static func labeled(_ c: CNContact) -> [(MergeItem, AnyObject)] {
        func lbl(_ l: String?) -> String { l.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "" }
        func item(_ kind: MergeKind, _ key: String, _ label: String?, _ text: String) -> MergeItem {
            MergeItem(id: kind.rawValue + ":" + key, kind: kind, label: lbl(label), text: text)
        }
        var out: [(MergeItem, AnyObject)] = []
        for lv in c.phoneNumbers {
            let s = lv.value.stringValue
            out.append((item(.phone, TelegramLink.phoneKey(s) ?? s.filter(\.isNumber), lv.label, s), lv))
        }
        for lv in c.emailAddresses {
            let s = lv.value as String
            out.append((item(.email, s.lowercased().trimmingCharacters(in: .whitespaces), lv.label, s), lv))
        }
        for lv in c.urlAddresses {
            let s = lv.value as String
            out.append((item(.url, s.trimmingCharacters(in: .whitespaces), lv.label, s), lv))
        }
        for lv in c.postalAddresses {
            let s = CNPostalAddressFormatter.string(from: lv.value, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", ")
            out.append((item(.address, s.lowercased(), lv.label, s), lv))
        }
        for lv in c.socialProfiles {
            let p = lv.value
            let s = [p.service, p.username, p.urlString].filter { !$0.isEmpty }.joined(separator: " · ")
            out.append((item(.social, [p.service, p.username, p.userIdentifier, p.urlString].joined(separator: "|").lowercased(), lv.label, s), lv))
        }
        for lv in c.instantMessageAddresses {
            let s = "\(lv.value.service) · \(lv.value.username)"
            out.append((item(.im, s.lowercased(), lv.label, s), lv))
        }
        for lv in c.contactRelations {
            out.append((item(.relation, "\(lv.label ?? "")|\(lv.value.name)".lowercased(), lv.label, lv.value.name), lv))
        }
        for lv in c.dates {
            let d = lv.value as DateComponents
            let s = [d.day, d.month, d.year].compactMap { $0 }.map { String(format: "%02d", $0) }.joined(separator: ".")
            out.append((item(.date, "\(lv.label ?? "")|\(s)", lv.label, s), lv))
        }
        return out
    }
}

/// Группы возможных дублей: общий телефон, общий email или одинаковое имя.
enum DuplicateFinder {
    static func duplicateIds(_ records: [ContactRecord]) -> Set<String> {
        var groups: [String: Set<String>] = [:]
        for r in records {
            var keys: [String] = []
            keys += r.phoneNumbers.compactMap { TelegramLink.phoneKey($0.value) }.map { "p:" + $0 }
            keys += r.emailAddresses.map { "e:" + $0.value.lowercased() }
            let name = [r.givenName, r.middleName, r.familyName].joined(separator: " ")
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
            if name.contains(" ") { keys.append("n:" + name) }   // только имя+фамилия, одно слово — слишком часто совпадает
            for k in Set(keys) { groups[k, default: []].insert(r.identifier) }
        }
        return groups.values.filter { $0.count > 1 }.reduce(into: Set<String>()) { $0.formUnion($1) }
    }
}
