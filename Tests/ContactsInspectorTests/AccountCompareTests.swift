import AppKit
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

    func testMatchRespectsCountryCode() {
        let a = [record("ua", "Олена", phones: ["+380 50 123 45 67"])]
        let b = [record("ru", "Ольга", phones: ["+7 050 123 45 67"]), record("ua2", "Olena", phones: ["380501234567"])]
        let m = AccountCompare.match(a, b)
        XCTAssertEqual(m.pairs.map { $0.b }, ["ua2"])
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

final class ImageValidityTests: XCTestCase {
    func testBrokenPhoto() {
        XCTAssertFalse(AccountCompare.isValidImage(Data("Unable to read recordID".utf8)))
        XCTAssertFalse(AccountCompare.isValidImage(nil))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        XCTAssertTrue(AccountCompare.isValidImage(rep.representation(using: .png, properties: [:])))
        XCTAssertTrue(AccountCompare.isValidImage(rep.representation(using: .jpeg, properties: [:])))
    }

    func testFillSkipsBrokenPhoto() {
        let s = CNMutableContact(); s.imageData = Data("Unable to read recordID".utf8)
        let m = CNMutableContact(); m.imageData = Data([0xFF, 0xD8, 0xFF])
        AccountCompare.fill(m, from: s.copy() as! CNContact)
        XCTAssertEqual(m.imageData, Data([0xFF, 0xD8, 0xFF]), "битое фото источника не затирает фото получателя")
    }

    func testFillPhotoMissingVersusUnknown() {
        let s = CNMutableContact()   // у источника фото нет
        let m = CNMutableContact(); m.imageData = Data([0xFF, 0xD8, 0xFF])
        AccountCompare.fill(m, from: s.copy() as! CNContact, photoUnknown: true)
        XCTAssertEqual(m.imageData, Data([0xFF, 0xD8, 0xFF]), "фото источника неизвестно (Google, ещё читается) — получателя не трогаем")
        AccountCompare.fill(m, from: s.copy() as! CNContact)
        XCTAssertNil(m.imageData, "фото источника точно нет — точная копия без фото")
    }
}

final class StandardJPEGTests: XCTestCase {
    func testWritesJFIF() {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2000, pixelsHigh: 1000, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])
        let jpeg = AccountCompare.standardJPEG(png)!
        XCTAssertEqual([UInt8](jpeg.prefix(4)), [0xFF, 0xD8, 0xFF, 0xE0], "JPEG должен начинаться с APP0 (JFIF)")
        let img = NSImage(data: jpeg)!
        XCTAssertLessThanOrEqual(max(img.representations[0].pixelsWide, img.representations[0].pixelsHigh), 1024)
        XCTAssertNil(AccountCompare.standardJPEG(Data("Unable to read recordID".utf8)))
    }
}

final class PhotoHashTests: XCTestCase {
    private func image(_ draw: (CGContext) -> Void) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 200, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(NSGraphicsContext.current!.cgContext)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    func testSamePhotoRecompressedMatches() {
        let a = image { c in
            c.setFillColor(.white); c.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            c.setFillColor(.black); c.fillEllipse(in: CGRect(x: 40, y: 30, width: 120, height: 140))
        }
        let b = image { c in
            c.setFillColor(.black); c.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            c.setFillColor(.white); c.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
        }
        let recompressed = AccountCompare.standardJPEG(a, maxSide: 120)
        let ha = AccountCompare.photoHash(a), hr = AccountCompare.photoHash(recompressed), hb = AccountCompare.photoHash(b)
        XCTAssertFalse(AccountCompare.photosDiffer(ha, hr), "то же фото после пережатия")
        XCTAssertTrue(AccountCompare.photosDiffer(ha, hb), "разные фото")
        XCTAssertTrue(AccountCompare.photosDiffer(ha, nil), "фото только с одной стороны")
        XCTAssertFalse(AccountCompare.photosDiffer(nil, nil))
    }
}
