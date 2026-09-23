import AppKit
import Contacts
import Foundation

struct AppContact: Identifiable {
    var id: String { record.identifier }
    let record: ContactRecord
    let thumbnail: Data?
    let image: Data?
}

enum SidebarFilter: Hashable {
    case summary
    case backups
    case all
    case container(String)
    case group(String)
    case has(Field)
    case missing(Field)
    case noPhoneNoEmail
    case telegram           // раздел Telegram
    case tgLinked           // связаны с Telegram
    case tgSuggested        // можно связать по телефону
    case tgNone             // без Telegram
}

enum LoadState: Equatable {
    case idle, loading, loaded
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var state: LoadState = .idle
    @Published var contacts: [AppContact] = []
    @Published var containers: [CNContainer] = []
    @Published var groups: [CNGroup] = []
    @Published var notesSource = ""
    @Published var filter: SidebarFilter? = .summary { didSet { debugLog("filter -> \(String(describing: filter))") } }
    @Published var search = ""
    @Published var tableSelection = Set<String>() { didSet { debugLog("tableSelection -> \(tableSelection.count)") } }
    @Published var showInspector = true
    @Published var backupInProgress = false
    @Published var backupMessage: String?
    @Published var lastBackup: Date? = UserDefaults.standard.object(forKey: "lastBackup") as? Date

    @Published var editingId: String?
    @Published var pendingDelete: Set<String>?
    @Published var errorMessage: String?

    /// Сервис Telegram (задаётся при старте приложения); нужен для фильтров и сопоставления.
    weak var telegram: TelegramService?

    private let store = CNContactStore()
    private var fetchResult: FetchResult?
    private var cnById: [String: CNContact] = [:]
    private var notes: [String: String] = [:]

    /// silent — перечитать данные без экрана загрузки (после правок), сохранив фильтр и выделение.
    func load(silent: Bool = false) async {
        if !silent { state = .loading }
        do {
            try await requestAccess(store)
            let store = self.store
            let (result, notes, notesError) = try await Task.detached {
                let r = try fetchAll(store)
                var notes: [String: String] = [:]
                var notesError: String?
                if !r.notesViaAPI {
                    do { notes = try fetchNotesViaAppleScript() } catch { notesError = "\(error)" }
                }
                return (r, notes, notesError)
            }.value
            fetchResult = result
            cnById = Dictionary(result.contacts.map { ($0.identifier, $0) }, uniquingKeysWith: { a, _ in a })
            tableSelection = tableSelection.filter { cnById[$0] != nil }
            if let e = editingId, cnById[e] == nil { editingId = nil }
            self.notes = notes
            containers = result.containers
            groups = result.groups
            debugLog("building records (notesViaAPI=\(result.notesViaAPI), notes=\(notes.count))")
            contacts = result.contacts.map { c in
                let note = result.notesViaAPI ? (c.note.isEmpty ? nil : c.note) : notes[c.identifier]
                return AppContact(
                    record: ContactRecord(c, containerId: result.containerOf[c.identifier],
                                          groupIds: result.groupsOf[c.identifier] ?? [], note: note,
                                          imageFile: nil, thumbnailFile: nil),
                    thumbnail: c.thumbnailImageData, image: c.imageData)
            }
            if result.notesViaAPI {
                notesSource = "Заметки: Contacts API"
            } else if let notesError {
                notesSource = "Заметки не прочитаны: \(notesError)"
            } else {
                notesSource = "Заметки: через AppleScript (\(notes.count))"
            }
            debugLog("loaded")
            await refreshBackups()
            state = .loaded
        } catch {
            debugLog("load failed: \(error)")
            state = .failed("\(error)")
        }
    }

    // MARK: - Правка и удаление

    func startEditing(_ id: String) {
        tableSelection = [id]
        editingId = id
        showInspector = true
    }

    func editable(_ id: String) -> EditableContact? {
        guard let c = cnById[id] else { return nil }
        return EditableContact(c, note: contact(id)?.record.note)
    }

    /// Сохраняет правки. Перед записью исходная версия уходит в историю.
    func save(_ edit: EditableContact, id: String) async -> Bool {
        guard let c = cnById[id] else { errorMessage = "Контакт не найден — обновите список"; return false }
        do {
            let oldNote = contact(id)?.record.note ?? ""
            let m = try edit.apply(to: c)
            let noteChanged = edit.note != oldNote
            if noteChanged, fetchResult?.notesViaAPI == true { m.note = edit.note }
            try archive([c], action: "edit")
            let req = CNSaveRequest()
            req.update(m)
            try store.execute(req)
            if noteChanged, fetchResult?.notesViaAPI != true {
                try setNoteViaAppleScript(contactId: id, note: edit.note)
            }
            debugLog("saved \(id)")
            editingId = nil
            await load(silent: true)
            return true
        } catch {
            debugLog("save failed: \(error)")
            errorMessage = "Не удалось сохранить: \(error)"
            return false
        }
    }

    func confirmDelete(_ ids: Set<String>) {
        if !ids.isEmpty { pendingDelete = ids }
    }

    func delete(_ ids: Set<String>) async {
        let contacts = ids.compactMap { cnById[$0] }
        guard !contacts.isEmpty else { return }
        do {
            try archive(contacts, action: "delete")
            let req = CNSaveRequest()
            for c in contacts { req.delete(c.mutableCopy() as! CNMutableContact) }
            try store.execute(req)
            debugLog("deleted \(contacts.count)")
            tableSelection.subtract(ids)
            await load(silent: true)
        } catch {
            debugLog("delete failed: \(error)")
            errorMessage = "Не удалось удалить: \(error)"
        }
    }

    var historyDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ContactsInspector/history")
    }

    /// Сохраняет исходные версии контактов (vCard с фото и заметкой) и пишет строку в history.log.
    private func archive(_ contacts: [CNContact], action: String) throws {
        let dir = historyDir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = fmt.string(from: Date())
        var log = ""
        for c in contacts {
            let note = contact(c.identifier)?.record.note
            let vcard = try vcardString(for: c, note: note)
            let file = "\(stamp)_\(action)_\(safeFileName(c.identifier)).vcf"
            try vcard.write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
            log += "\(stamp)\t\(action)\t\(contact(c.identifier)?.record.displayName ?? "?")\t\(file)\n"
        }
        let logURL = dir.appendingPathComponent("history.log")
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(log.utf8)); try? h.close()
        } else {
            try log.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Telegram

    var matcher: TelegramMatcher {
        TelegramMatcher(users: telegram?.users ?? [], records: contacts.map(\.record))
    }

    /// Что сделает «Синхронизировать»: новые связи по телефону и обновление устаревших ников.
    func telegramSyncPlan() -> [(contactId: String, user: TGUser)] {
        let m = matcher
        return contacts.compactMap { c in
            switch m.status(c.record) {
            case .suggested(let u): return (c.id, u)
            case .linked(_, _, let u?, true): return (c.id, u)
            default: return nil
            }
        }
    }

    /// Прописывает (user != nil) или убирает (user == nil) связь с Telegram в контактах Apple.
    func setTelegramLinks(_ changes: [(contactId: String, user: TGUser?)]) async {
        let pairs = changes.compactMap { ch in cnById[ch.contactId].map { ($0, ch.user) } }
        guard !pairs.isEmpty else { return }
        do {
            try archive(pairs.map(\.0), action: "telegram")
            let req = CNSaveRequest()
            for (c, user) in pairs {
                let m = c.mutableCopy() as! CNMutableContact
                var profiles = c.socialProfiles.filter { !TelegramLink.isTelegram($0.value.service) }
                if let user { profiles.append(TelegramLink.profile(for: user)) }
                m.socialProfiles = profiles
                req.update(m)
            }
            try store.execute(req)
            debugLog("telegram links: \(pairs.count)")
            await load(silent: true)
        } catch {
            debugLog("telegram links failed: \(error)")
            errorMessage = "Не удалось записать связи с Telegram: \(error)"
        }
    }

    // MARK: - Бэкап

    /// Папка, где лежат все бэкапы (по умолчанию ~/Documents/Contacts Inspector Backups).
    @Published var backupsDir: URL = {
        if let path = UserDefaults.standard.string(forKey: "backupsDir") { return URL(fileURLWithPath: path) }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Contacts Inspector Backups")
    }()
    @Published var backups: [BackupInfo] = []

    func backupNow() {
        guard let result = fetchResult else { return }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmmss"
        let dir = backupsDir.appendingPathComponent("contacts-backup-\(fmt.string(from: Date()))")
        let notes = self.notes
        backupInProgress = true
        Task {
            defer { backupInProgress = false }
            do {
                var tgUsers: [TGUser]?
                if let telegram, telegram.auth == .ready {
                    await telegram.ensurePhotos()
                    tgUsers = telegram.users
                }
                let users = tgUsers
                let summary = try await Task.detached {
                    try runBackup(result: result, notes: notes, telegram: users, to: dir)
                }.value
                let now = Date()
                lastBackup = now
                UserDefaults.standard.set(now, forKey: "lastBackup")
                debugLog("backup -> \(dir.path)")
                backupMessage = "Бэкап сохранён:\n\(dir.lastPathComponent)\n\n\(summary)"
                await refreshBackups()
            } catch {
                backupMessage = "Ошибка бэкапа: \(error)"
            }
        }
    }

    func chooseBackupsDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Хранить бэкапы здесь"
        panel.directoryURL = backupsDir
        guard panel.runModal() == .OK, let url = panel.url else { return }
        backupsDir = url
        UserDefaults.standard.set(url.path, forKey: "backupsDir")
        Task { await refreshBackups() }
    }

    func refreshBackups() async {
        let dir = backupsDir
        backups = await Task.detached { scanBackups(in: dir) }.value
    }

    func trashBackup(_ b: BackupInfo) {
        do {
            try FileManager.default.trashItem(at: b.url, resultingItemURL: nil)
            backups.removeAll { $0.id == b.id }
        } catch {
            errorMessage = "Не удалось удалить бэкап: \(error)"
        }
    }

    // MARK: - Фильтрация

    var filtered: [AppContact] {
        var list = contacts
        switch filter ?? .all {
        case .summary, .backups, .all, .telegram: break
        case .tgLinked, .tgSuggested, .tgNone:
            let m = matcher
            list = list.filter { c in
                let st = m.status(c.record)
                switch filter {
                case .tgLinked: return st.isLinked
                case .tgSuggested: return st.isSuggested
                default: return st == .none
                }
            }
        case .container(let id): list = list.filter { $0.record.containerId == id }
        case .group(let id): list = list.filter { $0.record.groupIds.contains(id) }
        case .has(let f): list = list.filter { f.count($0.record) > 0 }
        case .missing(let f): list = list.filter { f.count($0.record) == 0 }
        case .noPhoneNoEmail: list = list.filter { $0.record.phoneNumbers.isEmpty && $0.record.emailAddresses.isEmpty }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let digits = q.filter(\.isNumber)
            list = list.filter { c in
                let r = c.record
                let text = [r.displayName, r.organizationName, r.nickname, r.note ?? ""]
                    + r.emailAddresses.map(\.value)
                if text.contains(where: { $0.localizedCaseInsensitiveContains(q) }) { return true }
                return digits.count >= 3 && r.phoneNumbers.contains { $0.value.filter(\.isNumber).contains(digits) }
            }
        }
        return list
    }

    func contact(_ id: String?) -> AppContact? {
        guard let id else { return nil }
        return contacts.first { $0.id == id }
    }

    func containerName(_ id: String?) -> String {
        guard let id, let c = containers.first(where: { $0.identifier == id }) else { return "—" }
        return displayName(c)
    }

    func displayName(_ c: CNContainer) -> String {
        if c.type == .local { return "На этом Mac (не синхр.)" }
        if !c.name.isEmpty { return c.name }
        switch c.type {
        case .local: return "На этом Mac"
        case .exchange: return "Exchange"
        case .cardDAV: return "CardDAV"
        default: return "Аккаунт"
        }
    }

    func symbol(_ c: CNContainer) -> String {
        switch c.type {
        case .local: return "desktopcomputer"
        case .exchange: return "building.columns"
        default: return c.name.localizedCaseInsensitiveContains("icloud") ? "icloud" : "person.crop.circle.badge.checkmark"
        }
    }

    func groupName(_ id: String) -> String {
        groups.first { $0.identifier == id }?.name ?? id
    }

    func count(_ f: Field) -> (contacts: Int, values: Int) {
        var c = 0, v = 0
        for x in contacts {
            let n = f.count(x.record)
            if n > 0 { c += 1; v += n }
        }
        return (c, v)
    }
}
