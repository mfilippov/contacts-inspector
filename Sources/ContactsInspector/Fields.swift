import Foundation

/// Поля контакта, по которым считаем заполненность и фильтруем.
enum Field: String, CaseIterable, Identifiable, Hashable {
    case name, nickname, phonetic, organization, jobTitle
    case phone, email, address, url
    case birthday, dates, relation, social, im
    case note, photo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Имя"
        case .nickname: "Псевдоним"
        case .phonetic: "Фонетическое имя"
        case .organization: "Организация"
        case .jobTitle: "Должность / отдел"
        case .phone: "Телефоны"
        case .email: "Email"
        case .address: "Адреса"
        case .url: "Сайты"
        case .birthday: "День рождения"
        case .dates: "Другие даты"
        case .relation: "Связи"
        case .social: "Соцпрофили"
        case .im: "Мессенджеры"
        case .note: "Заметка"
        case .photo: "Фото"
        }
    }

    var symbol: String {
        switch self {
        case .name: "person"
        case .nickname: "quote.bubble"
        case .phonetic: "character.phonetic"
        case .organization: "building.2"
        case .jobTitle: "briefcase"
        case .phone: "phone"
        case .email: "envelope"
        case .address: "house"
        case .url: "link"
        case .birthday: "gift"
        case .dates: "calendar"
        case .relation: "person.2"
        case .social: "at"
        case .im: "message"
        case .note: "note.text"
        case .photo: "photo"
        }
    }

    /// Сколько значений этого поля у контакта (0 — не заполнено).
    func count(_ r: ContactRecord) -> Int {
        func n(_ s: String...) -> Int { s.contains { !$0.isEmpty } ? 1 : 0 }
        switch self {
        case .name: return n(r.namePrefix, r.givenName, r.middleName, r.familyName, r.nameSuffix, r.previousFamilyName)
        case .nickname: return n(r.nickname)
        case .phonetic: return n(r.phoneticGivenName, r.phoneticMiddleName, r.phoneticFamilyName, r.phoneticOrganizationName)
        case .organization: return n(r.organizationName)
        case .jobTitle: return n(r.jobTitle, r.departmentName)
        case .phone: return r.phoneNumbers.count
        case .email: return r.emailAddresses.count
        case .address: return r.postalAddresses.count
        case .url: return r.urlAddresses.count
        case .birthday: return (r.birthday != nil ? 1 : 0) + (r.nonGregorianBirthday != nil ? 1 : 0)
        case .dates: return r.dates.count
        case .relation: return r.relations.count
        case .social: return r.socialProfiles.count
        case .im: return r.instantMessageAddresses.count
        case .note: return (r.note?.isEmpty == false) ? 1 : 0
        case .photo: return r.hasImage ? 1 : 0
        }
    }
}
