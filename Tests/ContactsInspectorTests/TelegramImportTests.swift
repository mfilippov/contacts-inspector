import Contacts
import XCTest
@testable import ContactsInspector

final class TelegramImportTests: XCTestCase {
    private let user = TGUser(id: 42, firstName: "Иван", lastName: "Петров", phone: "79001234567",
                              usernames: ["ivan"], isMutual: true)

    private func source(photo: Data? = nil) -> TGImportSource {
        var b = DateComponents(); b.day = 5; b.month = 3
        return TGImportSource(user: user, full: TGFullInfo(bio: "Про себя", birthdate: "05.03", birthday: b,
                                                           note: "", groupsInCommon: 0), photo: photo)
    }

    func testApplyKeepsExistingPhoneAndAddsLink() {
        let c = CNMutableContact()
        c.givenName = "Ваня"
        c.phoneNumbers = [CNLabeledValue(label: CNLabelHome, value: CNPhoneNumber(stringValue: "8 900 123-45-67"))]
        let m = TelegramImport.apply([.givenName, .phone, .birthday, .photo], from: source(photo: Data([1, 2])),
                                     to: c.copy() as! CNContact)
        XCTAssertEqual(m.givenName, "Иван")
        XCTAssertEqual(m.phoneNumbers.count, 1, "номер уже есть — не дублируем")
        XCTAssertEqual(m.birthday?.day, 5)
        XCTAssertEqual(m.imageData, Data([1, 2]))
        XCTAssertEqual(m.socialProfiles.first?.value.userIdentifier, "42")
        XCTAssertEqual(m.urlAddresses.map { $0.value as String }, ["https://t.me/@id42"])
        XCTAssertEqual(m.familyName, "", "не выбранные поля не трогаем")
    }

    func testApplyAddsNewPhone() {
        let c = CNMutableContact()
        c.phoneNumbers = [CNLabeledValue(label: CNLabelHome, value: CNPhoneNumber(stringValue: "+7 999 000 00 00"))]
        let m = TelegramImport.apply([.phone], from: source(), to: c.copy() as! CNContact)
        XCTAssertEqual(m.phoneNumbers.map { $0.value.stringValue }, ["+7 999 000 00 00", "+79001234567"])
    }

    func testMakeContact() {
        let m = TelegramImport.makeContact(from: source(photo: Data([9])))
        XCTAssertEqual(m.givenName, "Иван")
        XCTAssertEqual(m.familyName, "Петров")
        XCTAssertEqual(m.phoneNumbers.first?.value.stringValue, "+79001234567")
        XCTAssertEqual(m.imageData, Data([9]))
        XCTAssertEqual(m.birthday?.month, 3)
        XCTAssertEqual(m.socialProfiles.first?.value.username, "ivan")
    }

    func testMergedNote() {
        XCTAssertEqual(TelegramImport.mergedNote(existing: nil, bio: "bio"), "bio")
        XCTAssertEqual(TelegramImport.mergedNote(existing: "old", bio: "bio"), "old\n\nbio")
        XCTAssertEqual(TelegramImport.mergedNote(existing: "old bio", bio: "bio"), "old bio")
    }
}
