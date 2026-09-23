import Contacts
import XCTest
@testable import ContactsInspector

final class EditingTests: XCTestCase {
    private func sample() -> CNContact {
        let m = CNMutableContact()
        m.givenName = "Иван"
        m.familyName = "Петров"
        m.phoneNumbers = [
            CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+7 900 000-00-00")),
            CNLabeledValue(label: CNLabelWork, value: CNPhoneNumber(stringValue: "123")),
        ]
        m.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: "a@b.c" as NSString)]
        m.socialProfiles = [CNLabeledValue(label: nil, value: CNSocialProfile(urlString: nil, username: "ivan",
                                                                              userIdentifier: nil, service: CNSocialProfileServiceTwitter))]
        var b = DateComponents(); b.day = 5; b.month = 3
        m.birthday = b
        return m.copy() as! CNContact
    }

    func testNoEditsKeepsEverything() throws {
        let c = sample()
        let m = try EditableContact(c, note: nil).apply(to: c)
        XCTAssertEqual(m.givenName, "Иван")
        XCTAssertEqual(m.phoneNumbers.map(\.identifier), c.phoneNumbers.map(\.identifier))
        XCTAssertEqual(m.socialProfiles.count, 1)
        XCTAssertEqual(m.birthday?.day, 5)
        XCTAssertNil(m.birthday?.year)
    }

    func testEditRemoveAndAdd() throws {
        let c = sample()
        var e = EditableContact(c, note: nil)
        e.givenName = "  Иван Иванович "
        e.phones[0].value = "+79001112233"
        e.phones.remove(at: 1)
        e.emails.append(EditLabeled(originalId: nil, label: CNLabelWork, value: "w@b.c"))
        e.emails.append(EditLabeled(originalId: nil, label: CNLabelWork, value: "   "))  // пустое — игнор
        e.socials.removeAll()
        e.birthday = "01.02.1990"
        let m = try e.apply(to: c)
        XCTAssertEqual(m.givenName, "Иван Иванович")
        XCTAssertEqual(m.phoneNumbers.count, 1)
        XCTAssertEqual(m.phoneNumbers[0].identifier, c.phoneNumbers[0].identifier, "id сохраняется при правке")
        XCTAssertEqual(m.phoneNumbers[0].value.stringValue, "+79001112233")
        XCTAssertEqual(m.emailAddresses.map { $0.value as String }, ["a@b.c", "w@b.c"])
        XCTAssertTrue(m.socialProfiles.isEmpty)
        XCTAssertEqual(m.birthday?.year, 1990)
        XCTAssertEqual(m.birthday?.month, 2)
    }

    func testClearBirthdayAndBadFormat() throws {
        let c = sample()
        var e = EditableContact(c, note: nil)
        e.birthday = ""
        XCTAssertNil(try e.apply(to: c).birthday)
        e.birthday = "31.13"
        XCTAssertThrowsError(try e.apply(to: c))
    }
}

final class NextSelectionTests: XCTestCase {
    func testNext() {
        let order = ["a", "b", "c", "d"]
        XCTAssertEqual(nextSelection(removing: ["b"], order: order), "c")
        XCTAssertEqual(nextSelection(removing: ["b", "c"], order: order), "d")
        XCTAssertEqual(nextSelection(removing: ["d"], order: order), "c", "удалили последнюю — берём предыдущую")
        XCTAssertEqual(nextSelection(removing: ["a", "c"], order: order), "d")
        XCTAssertNil(nextSelection(removing: ["a", "b", "c", "d"], order: order))
        XCTAssertNil(nextSelection(removing: ["x"], order: order))
    }
}
