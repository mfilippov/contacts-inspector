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
    debugLog("authorizationStatus = \(status.rawValue)")
    if status == .authorized { return }
    debugLog("requestAccess…")
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
    debugLog("fetch with note…")
    do {
        contacts = try fetch(keys: baseKeys + [CNContactNoteKey as CNKeyDescriptor])
    } catch {
        debugLog("fetch with note failed: \(error)")
        notesViaAPI = false
        contacts = try fetch(keys: baseKeys)
    }
    debugLog("fetched \(contacts.count) contacts")
    // Без entitlement macOS может вернуть контакты без заметок, а обращение к .note бросит
    // NSException (Swift его не ловит). Проверяем явно.
    if notesViaAPI, let first = contacts.first, !first.isKeyAvailable(CNContactNoteKey) {
        debugLog("note key not available after fetch")
        notesViaAPI = false
    }
    for key in [CNContactImageDataKey, CNContactThumbnailImageDataKey, CNContactImageDataAvailableKey,
                CNContactDatesKey, CNContactNonGregorianBirthdayKey, CNContactRelationsKey] {
        if let first = contacts.first, !first.isKeyAvailable(key) { debugLog("key not available: \(key)") }
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
    debugLog("containers \(containers.count), groups \(groups.count) mapped")
    for c in containers {
        debugLog("container name='\(c.name)' type=\(c.type.rawValue) id=\(c.identifier) contacts=\(containerOf.values.filter { $0 == c.identifier }.count)")
    }
    if let def = try? store.defaultContainerIdentifier() { debugLog("default container = \(def)") }
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
    debugLog("osascript notes…")
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

/// Записывает заметку через Contacts.app (API не даёт писать note без entitlement).
func setNoteViaAppleScript(contactId: String, note: String) throws {
    let script = """
    on run argv
        tell application "Contacts"
            set p to person id (item 1 of argv)
            set note of p to (item 2 of argv)
            save
        end tell
    end run
    """
    _ = try runOSAScript(script, args: [contactId, note])
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

/// Пошаговый лог в ~/Library/Logs/ContactsInspector.log — для диагностики.
func debugLog(_ msg: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ContactsInspector.log")
    let line = "\(Date().formatted(.iso8601)) \(msg)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}
