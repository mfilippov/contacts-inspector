import Contacts
import Foundation

/// Редактируемое значение с меткой. originalId — identifier исходного CNLabeledValue
/// (сохраняем его при правке, чтобы синхронизация видела изменение, а не удаление+добавление).
struct EditLabeled: Identifiable, Equatable {
    let id = UUID()
    var originalId: String?
    var label: String
    var value: String
}

struct EditAddress: Identifiable, Equatable {
    let id = UUID()
    var originalId: String?
    var label: String
    var street = "", city = "", state = "", postalCode = "", country = ""
}

/// Значение, которое можно только удалить (соцпрофили, мессенджеры, прочие даты).
struct EditRemovable: Identifiable, Equatable {
    let id = UUID()
    var originalId: String
    var text: String
}

struct EditableContact: Equatable {
    var namePrefix = "", givenName = "", middleName = "", familyName = ""
    var previousFamilyName = "", nameSuffix = "", nickname = ""
    var phoneticGivenName = "", phoneticMiddleName = "", phoneticFamilyName = ""
    var organizationName = "", departmentName = "", jobTitle = ""
    var birthday = ""   // "дд.мм.гггг" или "дд.мм"
    var phones: [EditLabeled] = []
    var emails: [EditLabeled] = []
    var urls: [EditLabeled] = []
    var relations: [EditLabeled] = []
    var addresses: [EditAddress] = []
    var socials: [EditRemovable] = []
    var ims: [EditRemovable] = []
    var dates: [EditRemovable] = []
    var note = ""
    var hasPhoto = false
    var removePhoto = false

    init(_ c: CNContact, note: String?) {
        namePrefix = c.namePrefix; givenName = c.givenName; middleName = c.middleName
        familyName = c.familyName; previousFamilyName = c.previousFamilyName
        nameSuffix = c.nameSuffix; nickname = c.nickname
        phoneticGivenName = c.phoneticGivenName; phoneticMiddleName = c.phoneticMiddleName
        phoneticFamilyName = c.phoneticFamilyName
        organizationName = c.organizationName; departmentName = c.departmentName; jobTitle = c.jobTitle
        birthday = Self.format(c.birthday)
        phones = c.phoneNumbers.map { .init(originalId: $0.identifier, label: $0.label ?? "", value: $0.value.stringValue) }
        emails = c.emailAddresses.map { .init(originalId: $0.identifier, label: $0.label ?? "", value: $0.value as String) }
        urls = c.urlAddresses.map { .init(originalId: $0.identifier, label: $0.label ?? "", value: $0.value as String) }
        relations = c.contactRelations.map { .init(originalId: $0.identifier, label: $0.label ?? "", value: $0.value.name) }
        addresses = c.postalAddresses.map {
            let a = $0.value
            return .init(originalId: $0.identifier, label: $0.label ?? "", street: a.street, city: a.city,
                         state: a.state, postalCode: a.postalCode, country: a.country)
        }
        socials = c.socialProfiles.map {
            let s = $0.value
            let text = [s.service, s.username, s.urlString].filter { !$0.isEmpty }.joined(separator: " · ")
            return .init(originalId: $0.identifier, text: text)
        }
        ims = c.instantMessageAddresses.map { .init(originalId: $0.identifier, text: "\($0.value.service) · \($0.value.username)") }
        dates = c.dates.map { lv in
            let d = lv.value as DateComponents
            let label = lv.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? ""
            return .init(originalId: lv.identifier, text: "\(label): \(Self.format(d))")
        }
        self.note = note ?? ""
        hasPhoto = c.imageDataAvailable
    }

    /// Применяет правки к копии исходного контакта.
    func apply(to c: CNContact) throws -> CNMutableContact {
        let m = c.mutableCopy() as! CNMutableContact
        m.namePrefix = namePrefix.trimmed; m.givenName = givenName.trimmed; m.middleName = middleName.trimmed
        m.familyName = familyName.trimmed; m.previousFamilyName = previousFamilyName.trimmed
        m.nameSuffix = nameSuffix.trimmed; m.nickname = nickname.trimmed
        m.phoneticGivenName = phoneticGivenName.trimmed; m.phoneticMiddleName = phoneticMiddleName.trimmed
        m.phoneticFamilyName = phoneticFamilyName.trimmed
        m.organizationName = organizationName.trimmed; m.departmentName = departmentName.trimmed
        m.jobTitle = jobTitle.trimmed

        let newBirthday = try Self.parseDate(birthday)
        if newBirthday != Self.normalized(c.birthday) { m.birthday = newBirthday }

        m.phoneNumbers = Self.merge(c.phoneNumbers, phones) { CNPhoneNumber(stringValue: $0) }
        m.emailAddresses = Self.merge(c.emailAddresses, emails) { $0 as NSString }
        m.urlAddresses = Self.merge(c.urlAddresses, urls) { $0 as NSString }
        m.contactRelations = Self.merge(c.contactRelations, relations) { CNContactRelation(name: $0) }

        m.postalAddresses = addresses.compactMap { e in
            let orig = c.postalAddresses.first { $0.identifier == e.originalId }
            let a = (orig?.value.mutableCopy() as? CNMutablePostalAddress) ?? CNMutablePostalAddress()
            a.street = e.street.trimmed; a.city = e.city.trimmed; a.state = e.state.trimmed
            a.postalCode = e.postalCode.trimmed; a.country = e.country.trimmed
            if [a.street, a.city, a.state, a.postalCode, a.country].allSatisfy(\.isEmpty) { return nil }
            let label = e.label.isEmpty ? nil : e.label
            if let orig { return orig.settingLabel(label, value: a.copy() as! CNPostalAddress) }
            return CNLabeledValue(label: label, value: a.copy() as! CNPostalAddress)
        }

        let keepSocial = Set(socials.map(\.originalId))
        m.socialProfiles = c.socialProfiles.filter { keepSocial.contains($0.identifier) }
        let keepIM = Set(ims.map(\.originalId))
        m.instantMessageAddresses = c.instantMessageAddresses.filter { keepIM.contains($0.identifier) }
        let keepDates = Set(dates.map(\.originalId))
        m.dates = c.dates.filter { keepDates.contains($0.identifier) }

        if removePhoto { m.imageData = nil }
        return m
    }

    private static func merge<T>(_ orig: [CNLabeledValue<T>], _ edits: [EditLabeled],
                                 make: (String) -> T) -> [CNLabeledValue<T>] {
        edits.filter { !$0.value.trimmed.isEmpty }.map { e in
            let label = e.label.isEmpty ? nil : e.label
            if let o = orig.first(where: { $0.identifier == e.originalId }) {
                return o.settingLabel(label, value: make(e.value.trimmed))
            }
            return CNLabeledValue(label: label, value: make(e.value.trimmed))
        }
    }

    static func format(_ d: DateComponents?) -> String {
        guard let d, let day = d.day, let month = d.month else { return "" }
        var s = String(format: "%02d.%02d", day, month)
        if let y = d.year, y != NSDateComponentUndefined { s += ".\(y)" }
        return s
    }

    private static func normalized(_ d: DateComponents?) -> DateComponents? {
        guard let d, let day = d.day, let month = d.month else { return nil }
        var r = DateComponents(); r.day = day; r.month = month
        if let y = d.year, y != NSDateComponentUndefined { r.year = y }
        return r
    }

    static func parseDate(_ s: String) throws -> DateComponents? {
        let t = s.trimmed
        if t.isEmpty { return nil }
        let parts = t.split(whereSeparator: { ".-/ ".contains($0) }).map { Int($0) }
        guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }),
              let day = parts[0], let month = parts[1], (1...31).contains(day), (1...12).contains(month)
        else { throw ToolError("День рождения: ожидается формат дд.мм.гггг или дд.мм, получено «\(t)»") }
        var d = DateComponents(); d.day = day; d.month = month
        if parts.count == 3, let y = parts[2] { d.year = y }
        return d
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Стандартные метки для выпадающих списков.
enum LabelKind {
    case phone, email, url, address, relation

    var options: [String] {
        switch self {
        case .phone: [CNLabelPhoneNumberMobile, CNLabelPhoneNumberiPhone, CNLabelHome, CNLabelWork,
                      CNLabelPhoneNumberMain, CNLabelPhoneNumberHomeFax, CNLabelPhoneNumberWorkFax, CNLabelOther]
        case .email: [CNLabelHome, CNLabelWork, CNLabelEmailiCloud, CNLabelOther]
        case .url: [CNLabelURLAddressHomePage, CNLabelHome, CNLabelWork, CNLabelOther]
        case .address: [CNLabelHome, CNLabelWork, CNLabelOther]
        case .relation: [CNLabelContactRelationSpouse, CNLabelContactRelationPartner, CNLabelContactRelationMother,
                         CNLabelContactRelationFather, CNLabelContactRelationParent, CNLabelContactRelationChild,
                         CNLabelContactRelationSon, CNLabelContactRelationDaughter, CNLabelContactRelationBrother,
                         CNLabelContactRelationSister, CNLabelContactRelationFriend, CNLabelContactRelationAssistant,
                         CNLabelContactRelationManager, CNLabelOther]
        }
    }

    static func title(_ label: String) -> String {
        label.isEmpty ? "без метки" : CNLabeledValue<NSString>.localizedString(forLabel: label)
    }
}
