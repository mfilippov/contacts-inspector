import Contacts
import Foundation

/// Все ключи, которые мы хотим прочитать. Заметки (note) вынесены отдельно:
/// с macOS 13 для них нужен entitlement, без него fetch падает целиком.
let baseKeys: [CNKeyDescriptor] = [
    CNContactIdentifierKey, CNContactTypeKey,
    CNContactNamePrefixKey, CNContactGivenNameKey, CNContactMiddleNameKey,
    CNContactFamilyNameKey, CNContactPreviousFamilyNameKey, CNContactNameSuffixKey,
    CNContactNicknameKey,
    CNContactPhoneticGivenNameKey, CNContactPhoneticMiddleNameKey, CNContactPhoneticFamilyNameKey,
    CNContactPhoneticOrganizationNameKey,
    CNContactOrganizationNameKey, CNContactDepartmentNameKey, CNContactJobTitleKey,
    CNContactBirthdayKey, CNContactNonGregorianBirthdayKey, CNContactDatesKey,
    CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey,
    CNContactUrlAddressesKey, CNContactRelationsKey, CNContactSocialProfilesKey,
    CNContactInstantMessageAddressesKey,
    CNContactImageDataKey, CNContactThumbnailImageDataKey, CNContactImageDataAvailableKey,
].map { $0 as CNKeyDescriptor } + [CNContactVCardSerialization.descriptorForRequiredKeys()]

struct FetchResult {
    var contacts: [CNContact]
    var notesViaAPI: Bool
    var containers: [CNContainer]
    var groups: [CNGroup]
    var containerOf: [String: String]      // contactId -> containerId
    var groupsOf: [String: [String]]       // contactId -> [groupId]
}

func requestAccess(_ store: CNContactStore) async throws {
    let status = CNContactStore.authorizationStatus(for: .contacts)
    if status == .authorized { return }
    // Если системный запрос не появился, requestAccess может ждать вечно — ограничиваем по времени.
    let granted = try await withThrowingTaskGroup(of: Bool?.self) { group in
        group.addTask { try await store.requestAccess(for: .contacts) }
        group.addTask { try await Task.sleep(for: .seconds(10)); return nil }
        let first = try await group.next()!
        group.cancelAll()
        return first
    }
    debugLog("requestAccess -> \(String(describing: granted))")
    guard let granted else {
        throw ToolError("""
        macOS не ответила на запрос доступа к контактам.
        Откройте настройки «Контакты» и включите Contacts Inspector, затем нажмите «Повторить».
        Если приложения нет в списке — закройте его и запустите двойным кликом из Finder.
        """)
    }
    guard granted else {
        throw ToolError("Нет доступа к контактам. Системные настройки → Конфиденциальность → Контакты.")
    }
}

func fetchAll(_ store: CNContactStore) throws -> FetchResult {
    func fetch(keys: [CNKeyDescriptor], predicate: NSPredicate? = nil) throws -> [CNContact] {
        let req = CNContactFetchRequest(keysToFetch: keys)
        req.predicate = predicate
        req.unifyResults = false   // «сырые» карточки из каждого аккаунта, без склейки
        req.sortOrder = .familyName
        var out: [CNContact] = []
        try store.enumerateContacts(with: req) { c, _ in out.append(c) }
        return out
    }

    var notesViaAPI = true
    var contacts: [CNContact]
    do {
        contacts = try fetch(keys: baseKeys + [CNContactNoteKey as CNKeyDescriptor])
    } catch {
        debugLog("fetch with note failed: \(error)")
        notesViaAPI = false
        contacts = try fetch(keys: baseKeys)
    }
    // Без entitlement macOS может вернуть контакты без заметок, а обращение к .note бросит
    // NSException (Swift его не ловит). Проверяем явно.
    if notesViaAPI, let first = contacts.first, !first.isKeyAvailable(CNContactNoteKey) {
        notesViaAPI = false
    }

    let containers = try store.containers(matching: nil)
    let groups = try store.groups(matching: nil)

    var containerOf: [String: String] = [:]
    for container in containers {
        let ids = try fetch(keys: [CNContactIdentifierKey as CNKeyDescriptor],
                            predicate: CNContact.predicateForContactsInContainer(withIdentifier: container.identifier))
        for c in ids { containerOf[c.identifier] = container.identifier }
    }
    var groupsOf: [String: [String]] = [:]
    for group in groups {
        let ids = try fetch(keys: [CNContactIdentifierKey as CNKeyDescriptor],
                            predicate: CNContact.predicateForContactsInGroup(withIdentifier: group.identifier))
        for c in ids { groupsOf[c.identifier, default: []].append(group.identifier) }
    }
    return FetchResult(contacts: contacts, notesViaAPI: notesViaAPI, containers: containers,
                       groups: groups, containerOf: containerOf, groupsOf: groupsOf)
}

/// Запасной путь для заметок: через AppleScript к приложению «Контакты».
/// id персоны в Contacts.app имеет вид "<UUID>:ABPerson" и совпадает с CNContact.identifier.
func fetchNotesViaAppleScript() throws -> [String: String] {
    let script = """
    set out to ""
    tell application "Contacts"
        repeat with p in (every person whose note is not missing value)
            set out to out & (id of p) & (ASCII character 30) & (note of p) & (ASCII character 31)
        end repeat
    end tell
    return out
    """
    let text = try runOSAScript(script).trimmingCharacters(in: .newlines)
    var notes: [String: String] = [:]
    for record in text.split(separator: "\u{1F}", omittingEmptySubsequences: true) {
        let parts = record.split(separator: "\u{1E}", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let note = String(parts[1])
        if !note.isEmpty { notes[String(parts[0])] = note }
    }
    return notes
}

/// Фото, которые Contacts.framework не отдаёт (у большинства контактов — фото из «Поделиться именем и фото»),
/// читаются через vCard, которую отдаёт Contacts.app. Возвращает id контакта → данные фото.
func fetchPhotosViaAppleScript() throws -> [String: Data] {
    let script = """
    set out to ""
    tell application "Contacts"
        set ids to id of every person
        repeat with pid in ids
            set v to vcard of person id pid
            if v contains "PHOTO" then set out to out & pid & (ASCII character 30) & v & (ASCII character 31)
        end repeat
    end tell
    return out
    """
    let text = try runOSAScript(script)
    var photos: [String: Data] = [:]
    for record in text.split(separator: "\u{1F}", omittingEmptySubsequences: true) {
        let parts = record.split(separator: "\u{1E}", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { continue }
        let id = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        // строки vCard свёрнуты (продолжение начинается с пробела) — разворачиваем
        let card = parts[1].replacingOccurrences(of: "\r\n ", with: "").replacingOccurrences(of: "\n ", with: "")
        guard let line = card.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("PHOTO") }),
              let colon = line.firstIndex(of: ":") else { continue }
        let b64 = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if let data = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) { photos[id] = data }
    }
    return photos
}

/// Записывает заметку через Contacts.app (API не даёт писать note без entitlement).
/// Пустая заметка удаляется целиком (missing value), а не записывается пустой строкой: Contacts.framework
/// без entitlement не может заменить многозначные поля (телефоны, email, …) у контакта, у которого
/// заметка существует, даже пустая (NSCocoaErrorDomain 134092); с удалённой заметкой — может.
func setNoteViaAppleScript(contactId: String, note: String) throws {
    let script = """
    on run argv
        tell application "Contacts"
            set p to person id (item 1 of argv)
            if (item 2 of argv) is "" then
                set note of p to missing value
            else
                set note of p to (item 2 of argv)
            end if
            save
        end tell
    end run
    """
    _ = try runOSAScript(script, args: [contactId, note])
}

/// Прописывает (url != "") или убирает связь с Telegram через Contacts.app — для контактов с заметкой:
/// Contacts.framework без entitlement на заметки не может сохранить такой контакт (ошибка 134092).
/// Удаляются: наши URL «https://t.me/@id…», битые «…@idId(rawValue…», наши соцпрофили Telegram
/// (с числовым ID, с tg://-ссылкой или пустые). Чужие профили Telegram не трогаются.
func setTelegramLinkViaAppleScript(contactId: String, officialURL: String, username: String, userId: String) throws {
    let script = """
    on run argv
        set pid to item 1 of argv
        set newURL to item 2 of argv
        set uname to item 3 of argv
        set uid to item 4 of argv
        tell application "Contacts"
            set p to person id pid
            set us to urls of p
            repeat with i from (count of us) to 1 by -1
                set v to value of item i of us as text
                if v starts with "https://t.me/@id" then delete item i of us
            end repeat
            set sps to social profiles of p
            repeat with i from (count of sps) to 1 by -1
                set sp to item i of sps
                if (service name of sp as text) is "Telegram" then
                    set ours to false
                    set ui to user identifier of sp
                    if ui is not missing value then
                        try
                            set n to (ui as number)
                            set ours to true
                        end try
                    end if
                    set ul to url of sp
                    if ul is not missing value then
                        if (ul as text) starts with "tg:" then set ours to true
                    end if
                    set un to user name of sp
                    if (un is missing value or un is "") and ul is missing value then set ours to true
                    if ours then delete sp
                end if
            end repeat
            if newURL is not "" then
                make new url at end of urls of p with properties {label:"Telegram", value:newURL}
                if uname is not "" then
                    make new social profile at end of social profiles of p with properties {service name:"Telegram", user name:uname, user identifier:uid, url:"https://t.me/" & uname}
                end if
            end if
            save
        end tell
    end run
    """
    _ = try runOSAScript(script, args: [contactId, officialURL, username, userId])
}

/// Меняет имя/отчество/фамилию через Contacts.app (для контактов с заметкой — см. выше).
func setNamesViaAppleScript(contactId: String, first: String, middle: String, last: String) throws {
    let script = """
    on run argv
        tell application "Contacts"
            set p to person id (item 1 of argv)
            set first name of p to (item 2 of argv)
            set middle name of p to (item 3 of argv)
            set last name of p to (item 4 of argv)
            save
        end tell
    end run
    """
    _ = try runOSAScript(script, args: [contactId, first, middle, last])
}

/// Удаляет контакт через Contacts.app (для контактов с заметкой, см. выше).
func deleteContactViaAppleScript(contactId: String) throws {
    let script = """
    on run argv
        tell application "Contacts"
            delete person id (item 1 of argv)
            save
        end tell
    end run
    """
    _ = try runOSAScript(script, args: [contactId])
}

func runOSAScript(_ script: String, args: [String] = []) throws -> String {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", script] + args
    let outPipe = Pipe(), errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    try proc.run()
    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else {
        throw ToolError("osascript: " + String(decoding: errData, as: UTF8.self))
    }
    return String(decoding: data, as: UTF8.self)
}

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Журнал действий и ошибок в ~/Library/Logs/ContactsInspector.log — только в отладочной сборке
/// (в журнале имена контактов и ID; в релизе ничего не пишется).
func debugLog(_ msg: @autoclosure () -> String) {
    #if DEBUG
    let msg = msg()
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ContactsInspector.log")
    let line = "\(Date().formatted(.iso8601)) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
    #endif
}
