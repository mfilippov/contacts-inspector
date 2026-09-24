import Contacts
import XCTest
@testable import ContactsInspector

final class AccountCompareTests: XCTestCase {
    private func record(_ id: String, _ given: String, _ family: String = "", phones: [String] = [],
                        emails: [String] = [], note: String? = nil) -> ContactRecord {
        var json: [String: Any] = [
            "identifier": id, "groupIds": [], "contactType": "person", "namePrefix": "", "givenName": given,
            "middleName": "", "familyName": family, "previousFamilyName": "", "nameSuffix": "", "nickname": "",
            "phoneticGivenName": "", "phoneticMiddleName": "", "phoneticFamilyName": "", "phoneticOrganizationName": "",
            "organizationName": "", "departmentName": "", "jobTitle": "", "dates": [],
            "phoneNumbers": phones.map { ["value": $0] }, "emailAddresses": emails.map { ["value": $0] },
            "urlAddresses": [], "relations": [], "postalAddresses": [], "instantMessageAddresses": [],
            "socialProfiles": [], "hasImage": false,
        ]
        if let note { json["note"] = note }
        return try! JSONDecoder().decode(ContactRecord.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testMatchLevels() {
        let a = [record("a1", "Иван", "Петров", phones: ["+7 900 123-45-67"]),
                 record("a2", "Anna", emails: ["ANNA@x.ru"]),
                 record("a3", "Олег", "Сидоров"),
                 record("a4", "Только", "В A")]
        let b = [record("b1", "Ваня", phones: ["8 900 1234567"]),
                 record("b2", "Anna K", emails: ["anna@x.ru"]),
                 record("b3", "олег", "сидоров"),
                 record("b4", "Только", "В B")]
        let m = AccountCompare.match(a, b)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: m.pairs.map { ($0.a, $0.b) }),
                       ["a1": "b1", "a2": "b2", "a3": "b3"])
        XCTAssertEqual(m.onlyA, ["a4"])
        XCTAssertEqual(m.onlyB, ["b4"])
    }

    func testDifferences() {
        let a = record("a", "Иван", "Петров", phones: ["+7 900 123-45-67"], emails: ["i@x.ru"], note: "n")
        let same = record("b", "Иван", "Петров", phones: ["8 (900) 123 45 67"], emails: ["I@X.ru"], note: "n")
        XCTAssertEqual(AccountCompare.differences(a, same), [])
        let other = record("c", "Иван", "", phones: ["+7 900 123-45-67", "+7 999 000 00 00"], emails: ["i@x.ru"])
        XCTAssertEqual(AccountCompare.differences(a, other), ["Фамилия", "Телефоны", "Заметка"])
    }

    func testFillCopiesWithoutIdentifiers() {
        let s = CNMutableContact()
        s.givenName = "Иван"
        s.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+79001234567"))]
        let src = s.copy() as! CNContact
        let m = CNMutableContact()
        AccountCompare.fill(m, from: src)
        XCTAssertEqual(m.givenName, "Иван")
        XCTAssertEqual(m.phoneNumbers.first?.value.stringValue, "+79001234567")
        XCTAssertNotEqual(m.phoneNumbers.first?.identifier, src.phoneNumbers.first?.identifier)
    }
}
