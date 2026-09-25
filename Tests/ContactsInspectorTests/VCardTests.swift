import AppKit
import Contacts
import XCTest
@testable import ContactsInspector

final class VCardTests: XCTestCase {
    func testPhotoAndNoteSurviveRoundTrip() throws {
        let m = CNMutableContact()
        m.givenName = "Иван"
        m.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: "+7 900 123-45-67"))]
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let photo = rep.representation(using: .jpeg, properties: [:])!
        let note = "строка 1, с запятой; и точкой с запятой\nстрока 2 \\ слэш"
        // фото передано отдельно — как в истории, когда Contacts.framework его не отдаёт
        let vcard = try vcardString(for: m.copy() as! CNContact, note: note, photo: photo)
        XCTAssertTrue(vcard.contains("\r\nPHOTO;ENCODING=b;TYPE=JPEG:"))
        XCTAssertTrue(vcard.split(separator: "\r\n").allSatisfy { $0.utf8.count <= 75 }, "строки свёрнуты по RFC")

        let back = try CNContactVCardSerialization.contacts(with: Data(vcard.utf8))
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].givenName, "Иван")
        XCTAssertEqual(back[0].imageData, photo)
        XCTAssertEqual(back[0].note, note)
    }

    func testNoPhotoNoNote() throws {
        let m = CNMutableContact(); m.givenName = "A"
        let vcard = try vcardString(for: m.copy() as! CNContact, note: "")
        XCTAssertFalse(vcard.contains("PHOTO"))
        XCTAssertFalse(vcard.contains("NOTE"))
    }
}
