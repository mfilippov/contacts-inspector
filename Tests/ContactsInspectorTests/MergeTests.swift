import Contacts
import XCTest
@testable import ContactsInspector

final class MergeTests: XCTestCase {
    private func contact(_ given: String, _ family: String = "", phones: [String] = [], emails: [String] = [],
                         org: String = "", photo: Data? = nil) -> CNContact {
        let m = CNMutableContact()
        m.givenName = given
        m.familyName = family
        m.organizationName = org
        m.phoneNumbers = phones.map { CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: $0)) }
        m.emailAddresses = emails.map { CNLabeledValue(label: CNLabelHome, value: $0 as NSString) }
        m.imageData = photo
        return m.copy() as! CNContact
    }

    func testItemsDeduplicated() {
        let a = contact("Иван", phones: ["+7 900 123-45-67"], emails: ["A@x.ru"])
        let b = contact("Ваня", phones: ["8 (900) 1234567", "+7 999 000 00 00"], emails: ["a@x.ru", "b@x.ru"])
        let items = ContactMerge.items(primary: a, others: [b])
        XCTAssertEqual(items.filter { $0.kind == .phone }.count, 2)
        XCTAssertEqual(items.filter { $0.kind == .email }.count, 2)
    }

    func testBuild() {
        let a = contact("Иван", "", phones: ["+7 900 123-45-67"], org: "")
        let b = contact("Ваня", "Петров", phones: ["8 900 123 45 67", "+7 999 000 00 00"], org: "Рога", photo: Data([1]))
        let items = ContactMerge.items(primary: a, others: [b])
        var scalars: [MergeScalar: String] = [:]
        for f in MergeScalar.allCases { scalars[f] = ContactMerge.defaultChoice(f, primary: a, others: [b]) }
        XCTAssertEqual(scalars[.givenName], "Иван", "основной контакт приоритетнее")
        XCTAssertEqual(scalars[.familyName], "Петров", "пустое поле берём у другого")
        let keep = Set(items.map(\.id)).subtracting(items.filter { $0.text.contains("999") }.map(\.id))
        let m = ContactMerge.build(primary: a, others: [b], scalars: scalars, birthday: nil, imageData: b.imageData, keep: keep)
        XCTAssertEqual(m.givenName, "Иван")
        XCTAssertEqual(m.familyName, "Петров")
        XCTAssertEqual(m.organizationName, "Рога")
        XCTAssertEqual(m.phoneNumbers.map { $0.value.stringValue }, ["+7 900 123-45-67"], "дубль и исключённый номер убраны")
        XCTAssertEqual(m.phoneNumbers.first?.identifier, a.phoneNumbers.first?.identifier, "значения основного — с identifier")
        XCTAssertEqual(m.imageData, Data([1]))
    }

    func testBuildKeepsEachKindInItsField() {
        let a = CNMutableContact()
        a.givenName = "A"
        a.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+7 900 000 00 01"))]
        a.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "a@x.ru" as NSString)]
        let b = CNMutableContact()
        b.givenName = "B"
        b.urlAddresses = [CNLabeledValue(label: CNLabelURLAddressHomePage, value: "https://x.ru" as NSString)]
        let addr = CNMutablePostalAddress(); addr.city = "Москва"
        b.postalAddresses = [CNLabeledValue(label: CNLabelHome, value: addr.copy() as! CNPostalAddress)]
        b.socialProfiles = [CNLabeledValue(label: nil, value: CNSocialProfile(urlString: "https://t.me/b", username: "b",
                                                                             userIdentifier: "1", service: "Telegram"))]
        var d = DateComponents(); d.day = 1; d.month = 2
        b.dates = [CNLabeledValue(label: CNLabelDateAnniversary, value: d as NSDateComponents)]
        let pa = a.copy() as! CNContact, pb = b.copy() as! CNContact
        let items = ContactMerge.items(primary: pa, others: [pb])
        let m = ContactMerge.build(primary: pa, others: [pb], scalars: [:], birthday: nil, imageData: nil,
                                   keep: Set(items.map(\.id)))
        XCTAssertEqual(m.phoneNumbers.count, 1)
        XCTAssertEqual(m.emailAddresses.map { $0.value as String }, ["a@x.ru"])
        XCTAssertEqual(m.urlAddresses.map { $0.value as String }, ["https://x.ru"])
        XCTAssertEqual(m.postalAddresses.first?.value.city, "Москва")
        XCTAssertEqual(m.socialProfiles.first?.value.username, "b")
        XCTAssertEqual(m.dates.count, 1)
        XCTAssertTrue(m.phoneNumbers.allSatisfy { ($0.value as AnyObject) is CNPhoneNumber })
    }

    func testMergedNote() {
        XCTAssertEqual(ContactMerge.mergedNote(["a", nil, " a ", "b"]), "a\n\nb")
    }
}
