import Contacts
import Foundation
import ImageIO

/// Сравнение контактов двух аккаунтов (например, iCloud и Google) и перенос в выбранную сторону.
enum AccountCompare {
    /// Сравниваемое поле: название и значение в «каноническом» виде (для сравнения) и для показа.
    struct Field {
        let title: String
        let key: String       // нормализованное значение — по нему сравниваем
        let display: String   // как показать
    }

    static func fields(_ r: ContactRecord) -> [Field] {
        func list(_ title: String, _ values: [(key: String, display: String)]) -> Field {
            let sorted = values.sorted { $0.key < $1.key }
            return Field(title: title, key: sorted.map(\.key).joined(separator: "\n"),
                         display: sorted.map(\.display).joined(separator: "\n"))
        }
        func one(_ title: String, _ v: String) -> Field { Field(title: title, key: v, display: v) }
        let first = r.middleName.isEmpty ? r.givenName : r.givenName + " " + r.middleName
        var birthday = ""
        if let b = r.birthday {
            birthday = [b.day, b.month, b.year].compactMap { $0 }.map { String(format: "%02d", $0) }.joined(separator: ".")
        }
        return [
            one("Имя", first),
            one("Фамилия", r.familyName),
            one("Псевдоним", r.nickname),
            one("Организация", r.organizationName),
            one("Отдел", r.departmentName),
            one("Должность", r.jobTitle),
            list("Телефоны", r.phoneNumbers.map { (TelegramLink.phoneKey($0.value) ?? $0.value.filter(\.isNumber), $0.value) }),
            list("Email", r.emailAddresses.map { ($0.value.lowercased(), $0.value) }),
            list("Сайты", r.urlAddresses.map { ($0.value, $0.value) }),
            list("Адреса", r.postalAddresses.map { a in
                let s = [a.street, a.city, a.state, a.postalCode, a.country].filter { !$0.isEmpty }.joined(separator: ", ")
                return (s.lowercased(), s)
            }),
            one("День рождения", birthday),
            list("Соцпрофили", r.socialProfiles.map { s in
                let d = [s.service, s.username].filter { !$0.isEmpty }.joined(separator: " · ")
                return (d.lowercased(), d)
            }),
            one("Заметка", r.note ?? ""),
            Field(title: "Фото", key: r.hasImage ? "есть" : "", display: r.hasImage ? "есть" : ""),
        ]
    }

    /// Названия полей, которые различаются.
    static func differences(_ a: ContactRecord, _ b: ContactRecord) -> [String] {
        zip(fields(a), fields(b)).filter { $0.key != $1.key }.map(\.0.title)
    }

    struct Match {
        var pairs: [(a: String, b: String)] = []
        var onlyA: [String] = []
        var onlyB: [String] = []
    }

    /// Сопоставляет контакты A и B: сначала по телефону, затем по email, затем по полному имени.
    /// Каждый контакт участвует не более чем в одной паре.
    static func match(_ a: [ContactRecord], _ b: [ContactRecord]) -> Match {
        func keys(_ r: ContactRecord) -> [[String]] {
            let name = [r.givenName, r.middleName, r.familyName, r.organizationName]
                .filter { !$0.isEmpty }.joined(separator: " ").lowercased()
            return [
                r.phoneNumbers.compactMap { TelegramLink.phoneKey($0.value) }.map { "p:" + $0 },
                r.emailAddresses.map { "e:" + $0.value.lowercased() },
                name.isEmpty ? [] : ["n:" + name],
            ]
        }
        var result = Match()
        var usedB = Set<String>()
        var pairedA = Set<String>()
        // по уровням: все совпадения по телефону, потом по email, потом по имени
        for level in 0..<3 {
            var index: [String: [String]] = [:]
            for r in b where !usedB.contains(r.identifier) {
                for k in keys(r)[level] { index[k, default: []].append(r.identifier) }
            }
            for r in a where !pairedA.contains(r.identifier) {
                if let hit = keys(r)[level].lazy.compactMap({ index[$0]?.first { !usedB.contains($0) } }).first {
                    result.pairs.append((r.identifier, hit))
                    usedB.insert(hit)
                    pairedA.insert(r.identifier)
                }
            }
        }
        result.onlyA = a.map(\.identifier).filter { !pairedA.contains($0) }
        result.onlyB = b.map(\.identifier).filter { !usedB.contains($0) }
        return result
    }

    // MARK: - Перенос

    /// Копирует содержимое контакта (без identifier'ов) в изменяемый контакт — новый или существующий.
    static func fill(_ m: CNMutableContact, from s: CNContact) {
        m.contactType = s.contactType
        m.namePrefix = s.namePrefix; m.givenName = s.givenName; m.middleName = s.middleName
        m.familyName = s.familyName; m.previousFamilyName = s.previousFamilyName; m.nameSuffix = s.nameSuffix
        m.nickname = s.nickname
        m.phoneticGivenName = s.phoneticGivenName; m.phoneticMiddleName = s.phoneticMiddleName
        m.phoneticFamilyName = s.phoneticFamilyName; m.phoneticOrganizationName = s.phoneticOrganizationName
        m.organizationName = s.organizationName; m.departmentName = s.departmentName; m.jobTitle = s.jobTitle
        m.birthday = s.birthday
        m.nonGregorianBirthday = s.nonGregorianBirthday
        func fresh<T>(_ v: [CNLabeledValue<T>]) -> [CNLabeledValue<T>] { v.map { CNLabeledValue(label: $0.label, value: $0.value) } }
        m.phoneNumbers = fresh(s.phoneNumbers)
        m.emailAddresses = fresh(s.emailAddresses)
        m.urlAddresses = fresh(s.urlAddresses)
        m.postalAddresses = fresh(s.postalAddresses)
        m.socialProfiles = fresh(s.socialProfiles)
        m.instantMessageAddresses = fresh(s.instantMessageAddresses)
        m.contactRelations = fresh(s.contactRelations)
        m.dates = fresh(s.dates)
        // Битое «фото» (не изображение — например, текст «Unable to read recordID») не переносим:
        // iCloud отказывается его сохранять (134040). Фото получателя тогда остаётся как есть.
        if s.imageData == nil || isValidImage(s.imageData) { m.imageData = s.imageData }
    }

    /// Можно ли декодировать данные как изображение.
    static func isValidImage(_ data: Data?) -> Bool {
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        return CGImageSourceGetCount(src) > 0 && CGImageSourceGetType(src) != nil
    }
}
