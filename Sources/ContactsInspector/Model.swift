import Contacts
import Foundation

/// Плоское JSON-представление контакта со всеми полями.
struct ContactRecord: Codable {
    struct Labeled: Codable {
        var label: String?        // сырая метка (_$!<Mobile>!$_ или своя)
        var labelLocalized: String?
        var value: String
    }
    struct Address: Codable {
        var label: String?
        var labelLocalized: String?
        var street, subLocality, city, subAdministrativeArea, state, postalCode, country, isoCountryCode: String
    }
    struct Social: Codable {
        var label: String?
        var service, username, userIdentifier, urlString: String
    }
    struct IM: Codable {
        var label: String?
        var service, username: String
    }
    struct DateValue: Codable {
        var label: String?
        var labelLocalized: String?
        var year, month, day: Int?
        var calendar: String?
    }

    var identifier: String
    var containerId: String?
    var groupIds: [String]
    var contactType: String

    var namePrefix, givenName, middleName, familyName, previousFamilyName, nameSuffix, nickname: String
    var phoneticGivenName, phoneticMiddleName, phoneticFamilyName, phoneticOrganizationName: String
    var organizationName, departmentName, jobTitle: String

    var birthday: DateValue?
    var nonGregorianBirthday: DateValue?
    var dates: [DateValue]
    var phoneNumbers: [Labeled]
    var emailAddresses: [Labeled]
    var urlAddresses: [Labeled]
    var relations: [Labeled]
    var postalAddresses: [Address]
    var socialProfiles: [Social]
    var instantMessageAddresses: [IM]
    var note: String?
    var hasImage: Bool
    var imageFile: String?
    var thumbnailFile: String?
}

private func loc(_ label: String?) -> String? {
    label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) }
}

private func dateValue(_ c: DateComponents?, label: String? = nil) -> ContactRecord.DateValue? {
    guard let c else { return nil }
    return .init(label: label, labelLocalized: loc(label),
                 year: c.year == NSDateComponentUndefined ? nil : c.year,
                 month: c.month, day: c.day,
                 calendar: c.calendar.map { "\($0.identifier)" })
}

extension ContactRecord {
    init(_ c: CNContact, containerId: String?, groupIds: [String], note: String?,
         imageFile: String?, thumbnailFile: String?) {
        identifier = c.identifier
        self.containerId = containerId
        self.groupIds = groupIds
        contactType = c.contactType == .organization ? "organization" : "person"
        namePrefix = c.namePrefix; givenName = c.givenName; middleName = c.middleName
        familyName = c.familyName; previousFamilyName = c.previousFamilyName
        nameSuffix = c.nameSuffix; nickname = c.nickname
        phoneticGivenName = c.phoneticGivenName; phoneticMiddleName = c.phoneticMiddleName
        phoneticFamilyName = c.phoneticFamilyName; phoneticOrganizationName = c.phoneticOrganizationName
        organizationName = c.organizationName; departmentName = c.departmentName; jobTitle = c.jobTitle
        birthday = dateValue(c.birthday)
        nonGregorianBirthday = dateValue(c.nonGregorianBirthday)
        dates = c.dates.compactMap { dateValue($0.value as DateComponents, label: $0.label) }
        phoneNumbers = c.phoneNumbers.map { .init(label: $0.label, labelLocalized: loc($0.label), value: $0.value.stringValue) }
        emailAddresses = c.emailAddresses.map { .init(label: $0.label, labelLocalized: loc($0.label), value: $0.value as String) }
        urlAddresses = c.urlAddresses.map { .init(label: $0.label, labelLocalized: loc($0.label), value: $0.value as String) }
        relations = c.contactRelations.map { .init(label: $0.label, labelLocalized: loc($0.label), value: $0.value.name) }
        postalAddresses = c.postalAddresses.map {
            let a = $0.value
            return .init(label: $0.label, labelLocalized: loc($0.label), street: a.street, subLocality: a.subLocality,
                         city: a.city, subAdministrativeArea: a.subAdministrativeArea, state: a.state,
                         postalCode: a.postalCode, country: a.country, isoCountryCode: a.isoCountryCode)
        }
        socialProfiles = c.socialProfiles.map {
            let s = $0.value
            return .init(label: $0.label, service: s.service, username: s.username,
                         userIdentifier: s.userIdentifier, urlString: s.urlString)
        }
        instantMessageAddresses = c.instantMessageAddresses.map {
            .init(label: $0.label, service: $0.value.service, username: $0.value.username)
        }
        self.note = note
        hasImage = c.imageDataAvailable
        self.imageFile = imageFile
        self.thumbnailFile = thumbnailFile
    }

    var displayName: String {
        let n = [namePrefix, givenName, middleName, familyName, nameSuffix].filter { !$0.isEmpty }.joined(separator: " ")
        if !n.isEmpty { return n }
        if !organizationName.isEmpty { return organizationName }
        return phoneNumbers.first?.value ?? emailAddresses.first?.value ?? "(без имени)"
    }
}

func imageExtension(_ data: Data) -> String {
    let b = [UInt8](data.prefix(12))
    if b.starts(with: [0xFF, 0xD8]) { return "jpg" }
    if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
    if b.count >= 12, b[4...7] == [0x66, 0x74, 0x79, 0x70] { return "heic" }
    if b.starts(with: [0x47, 0x49, 0x46]) { return "gif" }
    return "bin"
}

func safeFileName(_ id: String) -> String {
    id.replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "/", with: "_")
}
