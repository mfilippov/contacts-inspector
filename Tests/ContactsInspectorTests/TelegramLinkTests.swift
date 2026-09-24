import Contacts
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

final class TelegramBackupTests: XCTestCase {
    func testWritesJsonVcardAndPhotos() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = dir.appendingPathComponent("src.jpg")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3]).write(to: photo)
        let users = [
            TGUser(id: 42, firstName: "Иван", lastName: "Петров", phone: "79001234567", usernames: ["ivan"],
                   isMutual: true, photoFileId: 1, photoPath: photo.path),
            TGUser(id: 7, firstName: "Без", lastName: "Ника", phone: "", usernames: [], isMutual: false),
        ]
        let out = dir.appendingPathComponent("telegram")
        XCTAssertEqual(try writeTelegramBackup(users, to: out), 1)
        let records = try JSONDecoder().decode([TelegramBackupRecord].self,
                                               from: Data(contentsOf: out.appendingPathComponent("contacts.json")))
        XCTAssertEqual(records.map(\.id), [42, 7])
        XCTAssertEqual(records[0].photoFile, "photos/42.jpg")
        XCTAssertEqual(records[1].link, "tg://user?id=7")
        let vcf = try String(contentsOf: out.appendingPathComponent("contacts.vcf"), encoding: .utf8)
        XCTAssertEqual(vcf.components(separatedBy: "BEGIN:VCARD").count - 1, 2)
        XCTAssertTrue(vcf.contains("t.me/ivan"))
        XCTAssertTrue(vcf.contains("PHOTO"))
    }
}

final class BrokenLinkTests: XCTestCase {
    func testParse() {
        XCTAssertEqual(TelegramLink.brokenLinkId("https://t.me/@idId(rawValue: 123456789)"), 123456789)
        XCTAssertNil(TelegramLink.brokenLinkId("https://t.me/@id5000000001"), "официальный формат — не битый")
        XCTAssertEqual(TelegramLink.officialId("https://t.me/@id5000000001"), 5000000001)
        XCTAssertNil(TelegramLink.officialId("https://t.me/ivan"))
    }

    private func contact(urls: [String], profiles: [CNSocialProfile] = []) -> CNContact {
        let m = CNMutableContact()
        m.urlAddresses = urls.map { CNLabeledValue(label: CNLabelURLAddressHomePage, value: $0 as NSString) }
        m.socialProfiles = profiles.map { CNLabeledValue(label: nil, value: $0) }
        return m.copy() as! CNContact
    }

    func testSetLinkOfficialFormat() {
        let foreign = CNSocialProfile(urlString: nil, username: "+7 910 000", userIdentifier: nil, service: "Telegram")
        let legacy = CNSocialProfile(urlString: "tg://user?id=5", username: "", userIdentifier: "5", service: "Telegram")
        let c = contact(urls: ["https://example.com", "https://t.me/@idId(rawValue: 5)"], profiles: [foreign, legacy])
        let m = c.mutableCopy() as! CNMutableContact
        TelegramLink.setLink(m, from: c, user: TGUser(id: 5, firstName: "", lastName: "", phone: "", usernames: [],
                                                     isMutual: false))
        XCTAssertEqual(m.urlAddresses.map { $0.value as String }, ["https://example.com", "https://t.me/@id5"])
        XCTAssertEqual(m.urlAddresses.last?.label, "Telegram")
        XCTAssertEqual(m.socialProfiles.map(\.value.username), ["+7 910 000"], "чужой профиль остаётся, tg:// — убран")

        let withNick = c.mutableCopy() as! CNMutableContact
        TelegramLink.setLink(withNick, from: c, user: TGUser(id: 5, firstName: "", lastName: "", phone: "",
                                                            usernames: ["nick"], isMutual: false))
        XCTAssertEqual(withNick.socialProfiles.last?.value.urlString, "https://t.me/nick")

        let unlinked = c.mutableCopy() as! CNMutableContact
        TelegramLink.setLink(unlinked, from: c, user: nil)
        XCTAssertEqual(unlinked.urlAddresses.map { $0.value as String }, ["https://example.com"])
    }
}

final class NameDiffTests: XCTestCase {
    private func record(_ given: String, _ family: String) -> ContactRecord {
        let json: [String: Any] = [
            "identifier": "x", "groupIds": [], "contactType": "person", "namePrefix": "", "givenName": given,
            "middleName": "", "familyName": family, "previousFamilyName": "", "nameSuffix": "", "nickname": "",
            "phoneticGivenName": "", "phoneticMiddleName": "", "phoneticFamilyName": "", "phoneticOrganizationName": "",
            "organizationName": "", "departmentName": "", "jobTitle": "", "dates": [], "phoneNumbers": [],
            "emailAddresses": [], "urlAddresses": [], "relations": [], "postalAddresses": [],
            "instantMessageAddresses": [], "socialProfiles": [], "hasImage": false,
        ]
        return try! JSONDecoder().decode(ContactRecord.self, from: JSONSerialization.data(withJSONObject: json))
    }
    private func user(_ first: String, _ last: String) -> TGUser {
        TGUser(id: 1, firstName: first, lastName: last, phone: "", usernames: [], isMutual: true)
    }

    func testSameNames() {
        XCTAssertFalse(TelegramLink.namesDiffer(apple: record("Иван", "Петров"), telegram: user("Иван", "Петров")))

    }

    func testDifferentNames() {
        XCTAssertTrue(TelegramLink.namesDiffer(apple: record("Иван", "Петров"), telegram: user("Иван Петров", "")),
                      "полное имя одной строкой — расхождение")
        XCTAssertTrue(TelegramLink.namesDiffer(apple: record("Иван", "Петров"), telegram: user("Петров", "Иван")))
        XCTAssertTrue(TelegramLink.namesDiffer(apple: record("Иван", "Петров"), telegram: user("иван", "петров")))
        XCTAssertTrue(TelegramLink.namesDiffer(apple: record("Ivan", ""), telegram: user("Ivan", "Petrov")))
        XCTAssertTrue(TelegramLink.namesDiffer(apple: record("Иван ", "Петров"), telegram: user("Иван", "Петров")),
                      "лишний пробел — тоже расхождение")
    }
}
