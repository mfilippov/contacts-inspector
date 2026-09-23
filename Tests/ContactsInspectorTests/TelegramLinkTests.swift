import XCTest
@testable import ContactsInspector

final class TelegramLinkTests: XCTestCase {
    func testPhoneKey() {
        XCTAssertEqual(TelegramLink.phoneKey("+7 (900) 123-45-67"), "9001234567")
        XCTAssertEqual(TelegramLink.phoneKey("8 900 123 45 67"), "9001234567")
        XCTAssertEqual(TelegramLink.phoneKey("79001234567"), "9001234567")
        XCTAssertEqual(TelegramLink.phoneKey("+44 20 7946 0958"), "2079460958")
        XCTAssertNil(TelegramLink.phoneKey("112"))
    }

    private func record(id: String, phones: [String], tg: (Int64, String)? = nil) -> ContactRecord {
        let json: [String: Any] = [
            "identifier": id, "groupIds": [], "contactType": "person",
            "namePrefix": "", "givenName": id, "middleName": "", "familyName": "", "previousFamilyName": "",
            "nameSuffix": "", "nickname": "", "phoneticGivenName": "", "phoneticMiddleName": "",
            "phoneticFamilyName": "", "phoneticOrganizationName": "", "organizationName": "",
            "departmentName": "", "jobTitle": "", "dates": [],
            "phoneNumbers": phones.map { ["value": $0] }, "emailAddresses": [], "urlAddresses": [],
            "relations": [], "postalAddresses": [], "instantMessageAddresses": [], "hasImage": false,
            "socialProfiles": tg.map { [["service": "Telegram", "username": $0.1, "userIdentifier": String($0.0),
                                         "urlString": ""]] } ?? [],
        ]
        return try! JSONDecoder().decode(ContactRecord.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func user(_ id: Int64, _ phone: String, _ username: String? = nil) -> TGUser {
        TGUser(id: id, firstName: "U\(id)", lastName: "", phone: phone, usernames: username.map { [$0] } ?? [],
               isMutual: true)
    }

    func testStatuses() {
        let users = [user(1, "79001234567", "ivan"), user(2, "79005556677", "new_nick"),
                     user(3, "79990000000"), user(4, "79990000000")]
        let a = record(id: "a", phones: ["8 900 123-45-67"])                 // найден по телефону
        let b = record(id: "b", phones: ["+7 900 555 66 77"], tg: (2, "old")) // связан, ник устарел
        let c = record(id: "c", phones: ["+7 999 000 00 00"])                 // два кандидата — не предлагаем
        let d = record(id: "d", phones: ["+7 900 555 66 77"])                 // кандидат уже связан с b
        let m = TelegramMatcher(users: users, records: [a, b, c, d])
        XCTAssertEqual(m.status(a), .suggested(users[0]))
        XCTAssertEqual(m.status(b), .linked(id: 2, username: "old", user: users[1], outdated: true))
        XCTAssertEqual(m.status(c), .none)
        XCTAssertEqual(m.status(d), .none)
        XCTAssertEqual(m.appleContacts(for: users[1]), ["b"])
    }
}
