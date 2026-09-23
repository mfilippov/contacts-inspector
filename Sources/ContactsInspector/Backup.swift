import Contacts
import Foundation

/// Полный бэкап:
///   contacts.vcf        — все контакты одним файлом, с фото и заметками (для импорта куда угодно)
///   vcards/<id>.vcf     — то же, по файлу на контакт (удобно восстанавливать выборочно)
///   contacts.json       — все поля в структурированном виде (для анализа и diff'ов)
///   photos/<id>.<ext>   — оригинальные фото, photos/thumb/<id>.<ext> — миниатюры
///   accounts.json       — аккаунты (контейнеры) и группы
func runBackup(result r: FetchResult, notes: [String: String], to dir: URL) throws -> String {
    let fm = FileManager.default
    let photos = dir.appendingPathComponent("photos")
    let thumbs = photos.appendingPathComponent("thumb")
    let vcards = dir.appendingPathComponent("vcards")
    for d in [dir, photos, thumbs, vcards] {
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
    }

    var records: [ContactRecord] = []
    var allVCards = ""
    var photoCount = 0

    for c in r.contacts {
        let base = safeFileName(c.identifier)

        var imageFile: String?, thumbFile: String?
        if let data = c.imageData {
            imageFile = "photos/\(base).\(imageExtension(data))"
            try data.write(to: dir.appendingPathComponent(imageFile!))
            photoCount += 1
        }
        if let data = c.thumbnailImageData {
            thumbFile = "photos/thumb/\(base).\(imageExtension(data))"
            try data.write(to: dir.appendingPathComponent(thumbFile!))
        }

        let note: String? = r.notesViaAPI ? (c.note.isEmpty ? nil : c.note) : notes[c.identifier]

        let vcard = try vcardString(for: c, note: note)
        try vcard.write(to: vcards.appendingPathComponent("\(base).vcf"), atomically: true, encoding: .utf8)
        allVCards += vcard.hasSuffix("\n") ? vcard : vcard + "\r\n"

        records.append(ContactRecord(c, containerId: r.containerOf[c.identifier],
                                     groupIds: r.groupsOf[c.identifier] ?? [], note: note,
                                     imageFile: imageFile, thumbnailFile: thumbFile))
    }

    try allVCards.write(to: dir.appendingPathComponent("contacts.vcf"), atomically: true, encoding: .utf8)

    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try enc.encode(records).write(to: dir.appendingPathComponent("contacts.json"))

    struct Accounts: Codable {
        struct Container: Codable { var id, name, type: String; var contactCount: Int }
        struct Group: Codable { var id, name: String; var memberCount: Int }
        var containers: [Container]; var groups: [Group]
    }
    let typeName: [CNContainerType: String] = [.local: "local", .exchange: "exchange", .cardDAV: "cardDAV (iCloud/Google/…)", .unassigned: "unassigned"]
    let accounts = Accounts(
        containers: r.containers.map { c in
            .init(id: c.identifier, name: c.name, type: typeName[c.type] ?? "?",
                  contactCount: r.containerOf.values.filter { $0 == c.identifier }.count)
        },
        groups: r.groups.map { g in
            .init(id: g.identifier, name: g.name,
                  memberCount: r.groupsOf.values.filter { $0.contains(g.identifier) }.count)
        })
    try enc.encode(accounts).write(to: dir.appendingPathComponent("accounts.json"))

    return "Контактов: \(r.contacts.count), с фото: \(photoCount)"
}

// MARK: - vCard helpers

/// vCard одного контакта. Системный сериализатор может не включать фото и заметку — дописываем сами.
func vcardString(for c: CNContact, note: String?) throws -> String {
    var vcard = String(decoding: try CNContactVCardSerialization.data(with: [c]), as: UTF8.self)
    if let data = c.imageData, !vcard.contains("\nPHOTO") {
        vcard = insertIntoVCard(vcard, lines: photoLines(data))
    }
    if let note, !note.isEmpty, !vcard.contains("\nNOTE") {
        vcard = insertIntoVCard(vcard, lines: [foldLine("NOTE:" + escapeVCard(note))])
    }
    return vcard
}

private func insertIntoVCard(_ vcard: String, lines: [String]) -> String {
    guard let r = vcard.range(of: "END:VCARD", options: .backwards) else { return vcard }
    return vcard.replacingCharacters(in: r, with: lines.joined(separator: "\r\n") + "\r\nEND:VCARD")
}

private func photoLines(_ data: Data) -> [String] {
    let type = imageExtension(data) == "png" ? "PNG" : "JPEG"
    return [foldLine("PHOTO;ENCODING=b;TYPE=\(type):" + data.base64EncodedString())]
}

private func escapeVCard(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\r\n", with: "\\n")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: ",", with: "\\,")
        .replacingOccurrences(of: ";", with: "\\;")
}

/// Фолдинг длинных строк по RFC 6350 (≤75 октетов, продолжение начинается с пробела).
private func foldLine(_ line: String) -> String {
    var out: [String] = [], cur = "", curBytes = 0
    for ch in line {
        let n = String(ch).utf8.count
        let limit = out.isEmpty ? 75 : 74
        if curBytes + n > limit { out.append(cur); cur = ""; curBytes = 0 }
        cur.append(ch); curBytes += n
    }
    out.append(cur)
    return out.joined(separator: "\r\n ")
}
