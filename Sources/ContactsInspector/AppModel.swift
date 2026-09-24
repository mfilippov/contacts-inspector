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
    case tgNeedsFix         // связь с Telegram нужно исправить
    case tgNameDiffers      // связан, но имя отличается от Telegram
    case duplicates         // возможные дубли (общий телефон, email или имя)
    case cyrillicNames      // имя, отчество или фамилия кириллицей
    case compare            // сравнение двух аккаунтов
    case brokenPhoto        // «фото», которое не является изображением
}

enum LoadState: Equatable {
    case idle, loading, loaded
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var state: LoadState = .idle
    @Published var contacts: [AppContact] = []
    /// Фото, прочитанные через Contacts.app, — для контактов, у которых Contacts.framework фото не видит.
    @Published private(set) var externalPhotos: [String: Data] = [:]
    @Published private(set) var loadingPhotos = false
    private var fetchingPhotos = false
    /// Контакты, у которых в поле фото лежит не изображение.
    @Published private(set) var brokenPhotoIds = Set<String>()
    @Published var containers: [CNContainer] = []
    @Published var groups: [CNGroup] = []
    @Published var notesSource = ""
    @Published var filter: SidebarFilter? = .summary
    @Published var search = ""
    @Published var tableSelection = Set<String>()
    @Published var showInspector = true
    /// Текущий порядок строк таблицы контактов (с учётом сортировки и фильтра) — задаёт ContactTable.
    var tableOrder: [String] = []
    @Published var backupInProgress = false
    @Published var backupMessage: String?
    @Published var lastBackup: Date? = UserDefaults.standard.object(forKey: "lastBackup") as? Date

    @Published var editingId: String?
    @Published var pendingDelete: Set<String>?
    @Published var errorMessage: String?
    /// Итог длинной операции (показывается окном).
    @Published var resultMessage: String?
    /// Контакт с заметкой, который нельзя изменить через Contacts.framework (см. hasNote).
    @Published var noteBlockedContact: String?
    /// Контакты, выбранные для объединения (открывает окно объединения).
    @Published var mergeIds: [String]?
    /// Контакты, выбранные для транслитерации (открывает подтверждение).
    @Published var pendingTranslit: [String]?

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
            photoHashCache = [:]
            tableSelection = tableSelection.filter { cnById[$0] != nil }
            if let e = editingId, cnById[e] == nil { editingId = nil }
            self.notes = notes
            containers = result.containers
            groups = result.groups
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
            applyExternalPhotos()
            loadingPhotos = true   // сразу, чтобы сравнение не показывало ложные расхождения фото
            Task { await loadExternalPhotos() }
            debugLog("loaded \(result.contacts.count) contacts; accounts: " + result.containers.map { c in
                "\(displayName(c)) [type \(c.type.rawValue)] \(result.containerOf.values.filter { $0 == c.identifier }.count)"
            }.joined(separator: ", "))
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
    /// original — состояние формы при открытии (для определения, что именно изменилось).
    func save(_ edit: EditableContact, original: EditableContact, id: String) async -> Bool {
        guard let c = cnById[id] else { errorMessage = "Контакт не найден — обновите список"; return false }
        let oldNote = contact(id)?.record.note ?? ""
        let noteChanged = edit.note != oldNote
        let viaAPI = fetchResult?.notesViaAPI == true
        // изменилось ли что-то кроме заметки
        var withoutNote = edit
        withoutNote.note = oldNote
        var originalWithoutNote = original
        originalWithoutNote.note = oldNote
        let fieldsChanged = withoutNote != originalWithoutNote
        // Контакт с заметкой Contacts.framework не сохраняет (134092); заметку пишем через Contacts.app,
        // а поля — только если заметку при этом очищают.
        if !viaAPI, !oldNote.isEmpty, fieldsChanged, !edit.note.isEmpty {
            noteBlockedContact = id
            return false
        }
        do {
            try archive([c], action: "edit")
            if noteChanged, !viaAPI {
                try setNoteViaAppleScript(contactId: id, note: edit.note)
            }
            if fieldsChanged || (noteChanged && viaAPI) {
                let m = try edit.apply(to: c)
                if noteChanged, viaAPI { m.note = edit.note }
                let req = CNSaveRequest()
                req.update(m)
                try store.execute(req)
            }
            debugLog("saved \(id) (fields: \(fieldsChanged), note: \(noteChanged))")
            editingId = nil
            await load(silent: true)
            return true
        } catch let e as NSError where e.code == 134092 {
            debugLog("save blocked by note: \(id)")
            await load(silent: true)
            noteBlockedContact = id
            return false
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
            let (withNote, plain) = split(contacts)
            let next = nextSelection(removing: ids, order: tableOrder)
            if !plain.isEmpty {
                let req = CNSaveRequest()
                for c in plain { req.delete(c.mutableCopy() as! CNMutableContact) }
                try store.execute(req)
            }
            for c in withNote { try deleteContactViaAppleScript(contactId: c.identifier) }
            debugLog("deleted \(contacts.count)")
            await load(silent: true)
            tableSelection = next.map { [$0] } ?? []
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
            try writeLinks(pairs)
            debugLog("telegram links: \(pairs.count)")
            await load(silent: true)
        } catch {
            debugLog("telegram links failed: \(error)")
            errorMessage = "Не удалось записать связи с Telegram: \(error)"
        }
    }

    /// Contacts.framework без entitlement на заметки не сохраняет изменённый контакт с непустой заметкой
    /// (NSCocoaErrorDomain 134092 при «faulting» заметки). Такие контакты меняем через Contacts.app.
    func hasNote(_ id: String) -> Bool { contact(id)?.record.note?.isEmpty == false }

    private func split(_ contacts: [CNContact]) -> (withNote: [CNContact], plain: [CNContact]) {
        (contacts.filter { hasNote($0.identifier) }, contacts.filter { !hasNote($0.identifier) })
    }

    /// Записывает связи: обычные контакты — одним CNSaveRequest, контакты с заметкой — через Contacts.app.
    private func writeLinks(_ pairs: [(CNContact, TGUser?)]) throws {
        let plain = pairs.filter { !hasNote($0.0.identifier) }
        if !plain.isEmpty {
            let req = CNSaveRequest()
            for (c, user) in plain {
                let m = c.mutableCopy() as! CNMutableContact
                TelegramLink.setLink(m, from: c, user: user)
                req.update(m)
            }
            try store.execute(req)
        }
        for (c, user) in pairs where hasNote(c.identifier) {
            try setTelegramLinkViaAppleScript(contactId: c.identifier,
                                              officialURL: user.map { TelegramLink.officialURL($0.id) } ?? "",
                                              username: user?.username ?? "",
                                              userId: user.map { String($0.id) } ?? "")
        }
    }

    /// Открывает контакт в приложении «Контакты».
    func openInContacts(_ id: String) {
        if let url = URL(string: "addressbook://\(id)") { NSWorkspace.shared.open(url) }
    }

    /// Контакты, у которых связь с Telegram нужно исправить (битые ссылки, старый формат).
    var linksNeedingFix: [AppContact] { contacts.filter { TelegramLink.fixReason($0.record) != nil } }

    /// Исправляет связи: пишет официальный формат (https://t.me/@id…, с username — если пользователь
    /// есть в контактах Telegram), убирает битые ссылки и старые профили. Копии — в историю.
    func fixTelegramLinks(_ ids: [String]) async {
        let targets = ids.compactMap { id -> (CNContact, Int64)? in
            guard let c = cnById[id], let r = contact(id)?.record, TelegramLink.fixReason(r) != nil,
                  let tgId = TelegramLink.fixTargetId(r) else { return nil }
            return (c, tgId)
        }
        guard !targets.isEmpty else { return }
        let known = Dictionary((telegram?.users ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        do {
            try archive(targets.map(\.0), action: "telegram-fix")
            try writeLinks(targets.map { c, tgId in
                (c, Optional(known[tgId] ?? TGUser(id: tgId, firstName: "", lastName: "", phone: "", usernames: [],
                                                   isMutual: false)))
            })
            debugLog("fixed telegram links: \(targets.count)")
            await load(silent: true)
        } catch {
            errorMessage = "Не удалось исправить связи: \(error)"
        }
    }

    /// Переносит выбранные поля из Telegram в контакт Apple (и прописывает связь).
    func importFromTelegram(contactId: String, fields: Set<TGImportField>, source: TGImportSource) async {
        guard let c = cnById[contactId] else { errorMessage = "Контакт не найден — обновите список"; return }
        if hasNote(contactId) { noteBlockedContact = contactId; return }
        do {
            try archive([c], action: "telegram-import")
            let req = CNSaveRequest()
            req.update(TelegramImport.apply(fields, from: source, to: c))
            try store.execute(req)
            if fields.contains(.bio), let bio = source.full?.bio, !bio.isEmpty {
                let note = TelegramImport.mergedNote(existing: contact(contactId)?.record.note, bio: bio)
                try setNoteViaAppleScript(contactId: contactId, note: note)
            }
            debugLog("telegram import into \(contactId): \(fields.map(\.rawValue).sorted())")
            await load(silent: true)
        } catch {
            errorMessage = "Не удалось перенести данные: \(error)"
        }
    }

    /// Создаёт контакты Apple (в аккаунте по умолчанию) из пользователей Telegram. Возвращает их id.
    @discardableResult
    func createFromTelegram(_ sources: [TGImportSource]) async -> [String] {
        guard !sources.isEmpty else { return [] }
        do {
            let req = CNSaveRequest()
            let created = sources.map { TelegramImport.makeContact(from: $0) }
            for m in created { req.add(m, toContainerWithIdentifier: nil) }
            try store.execute(req)
            let ids = created.map(\.identifier)
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HHmmss"
            let stamp = fmt.string(from: Date())
            appendHistory(zip(sources, ids).map { "\(stamp)\tcreate-from-telegram\t\($0.user.name)\t\($1)" })
            debugLog("created from telegram: \(ids.count)")
            await load(silent: true)
            return ids
        } catch {
            errorMessage = "Не удалось создать контакты: \(error)"
            return []
        }
    }

    /// Удаляет контакты из Telegram; перед этим сохраняет их в историю (JSON, vCard, фото).
    /// Редактирует контакт Telegram; перед этим сохраняет его данные в историю.
    func editTelegramContact(_ u: TGUser, firstName: String, lastName: String, note: String?) async -> Bool {
        guard let telegram else { return false }
        do {
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HHmmss"
            let stamp = fmt.string(from: Date())
            let dir = historyDir.appendingPathComponent("\(stamp)_telegram-edit")
            _ = try writeTelegramBackup([telegram.users.first { $0.id == u.id } ?? u], to: dir)
            appendHistory(["\(stamp)\ttelegram-edit\t\(u.name) → \(firstName) \(lastName)\t\(dir.lastPathComponent)"])
            try await telegram.editContact(u, firstName: firstName, lastName: lastName, note: note)
            return true
        } catch {
            errorMessage = "Не удалось изменить контакт Telegram: \(TelegramService.describe(error))"
            return false
        }
    }

    /// Связан с пользователем из контактов Telegram, и имена различаются.
    func nameDiffersFromTelegram(_ r: ContactRecord, matcher m: TelegramMatcher) -> Bool {
        if case .linked(_, _, let u?, _) = m.status(r) { return TelegramLink.namesDiffer(apple: r, telegram: u) }
        return false
    }

    // MARK: - Сравнение аккаунтов

    /// Фото контакта: то, что отдаёт Contacts.framework, иначе прочитанное через Contacts.app.
    func photo(_ id: String) -> Data? { cnById[id]?.imageData ?? externalPhotos[id] }

    /// Фоном читает фото через Contacts.app (~10 с) и дополняет ими контакты.
    func loadExternalPhotos() async {
        guard !fetchingPhotos else { return }
        fetchingPhotos = true
        loadingPhotos = true
        defer { fetchingPhotos = false; loadingPhotos = false }
        do {
            let all = try await Task.detached { try fetchPhotosViaAppleScript() }.value
            externalPhotos = all.filter { cnById[$0.key] != nil && cnById[$0.key]?.imageData == nil }
            debugLog("photos via Contacts.app: \(externalPhotos.count)")
            applyExternalPhotos()
        } catch {
            debugLog("photos via Contacts.app failed: \(error)")
        }
    }

    /// Проставляет фото из externalPhotos в список контактов (аватары, сводка, фильтры) и пересчитывает битые.
    private func applyExternalPhotos() {
        photoHashCache = [:]
        contacts = contacts.map { c in
            guard c.image == nil, let data = externalPhotos[c.id] else { return c }
            var r = c.record
            r.hasImage = true
            return AppContact(record: r, thumbnail: c.thumbnail ?? data, image: data)
        }
        brokenPhotoIds = Set(contacts.map(\.id).filter { id in photo(id) != nil && !AccountCompare.isValidImage(photo(id)) })
    }

    private var photoHashCache: [String: UInt64?] = [:]

    /// Отпечаток фото контакта (кэшируется до следующей загрузки).
    func photoHash(_ id: String) -> UInt64? {
        if let cached = photoHashCache[id] { return cached }
        let h = AccountCompare.photoHash(photo(id))
        photoHashCache[id] = h
        return h
    }

    func records(in container: String) -> [ContactRecord] {
        contacts.map(\.record).filter { $0.containerId == container }
    }

    /// Создаёт копии контактов в другом аккаунте (со всеми полями, фото и заметкой).
    /// Каждый контакт — отдельным запросом: ошибка одного не останавливает остальные.
    func copyContacts(_ ids: [String], to container: String) async -> (done: Int, failed: [String]) {
        var done = 0
        var failed: [String] = []
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = fmt.string(from: Date())
        for s in ids.compactMap({ cnById[$0] }) {
            let name = contact(s.identifier)?.record.displayName ?? s.identifier
            do {
                let m = CNMutableContact()
                AccountCompare.fill(m, from: s, photo: photo(s.identifier))
                let req = CNSaveRequest()
                req.add(m, toContainerWithIdentifier: container)
                try store.execute(req)
                if let note = contact(s.identifier)?.record.note, !note.isEmpty {
                    try setNoteViaAppleScript(contactId: m.identifier, note: note)
                }
                appendHistory(["\(stamp)\tcopy\t\(name)\t\(s.identifier) → \(m.identifier)"])
                done += 1
            } catch {
                debugLog("copy \(name) (\(s.identifier)) to \(container) failed: \(error)")
                failed.append("\(name): \(Self.shortError(error))")
            }
        }
        debugLog("copied \(done), failed \(failed.count)")
        await load(silent: true)
        return (done, failed)
    }

    /// Перезаписывает контакты target содержимым source (пары из разных аккаунтов) — точная копия,
    /// включая удаление заметки и фото, которых нет в источнике. Копии target — в историю.
    func overwrite(_ pairs: [(target: String, source: String)]) async -> (done: Int, failed: [String]) {
        let items = pairs.compactMap { p in cnById[p.target].flatMap { t in cnById[p.source].map { (t, $0) } } }
        guard !items.isEmpty else { return (0, []) }
        var done = 0
        var failed: [String] = []
        do { try archive(items.map(\.0), action: "overwrite") } catch {
            errorMessage = "Не удалось сохранить копии в историю, ничего не изменено: \(error)"
            return (0, [])
        }
        for (t, s) in items {
            let name = contact(t.identifier)?.record.displayName ?? t.identifier
            let targetNote = contact(t.identifier)?.record.note ?? ""
            let sourceNote = contact(s.identifier)?.record.note ?? ""
            do {
                // у контакта с заметкой Contacts.framework не заменяет многозначные поля (134092):
                // заметку убираем целиком, перечитываем контакт, сохраняем, затем пишем заметку источника
                var fresh = t
                if !targetNote.isEmpty {
                    try setNoteViaAppleScript(contactId: t.identifier, note: "")
                    fresh = try refetch(t.identifier)
                }
                let m = fresh.mutableCopy() as! CNMutableContact
                AccountCompare.fill(m, from: s, photo: photo(s.identifier))
                let req = CNSaveRequest()
                req.update(m)
                do { try store.execute(req) } catch {
                    if !targetNote.isEmpty { try? setNoteViaAppleScript(contactId: t.identifier, note: targetNote) }
                    throw error
                }
                if !sourceNote.isEmpty { try setNoteViaAppleScript(contactId: t.identifier, note: sourceNote) }
                done += 1
            } catch {
                debugLog("overwrite \(name) (\(t.identifier)) failed: \(error)")
                failed.append("\(name): \(Self.shortError(error))")
            }
        }
        debugLog("overwrote \(done), failed \(failed.count)")
        await load(silent: true)
        return (done, failed)
    }

    /// Заново загружает фото источника в контакт-получатель (как стандартный JPEG с JFIF).
    func pushPhotos(_ pairs: [(target: String, source: String)]) async -> (done: Int, failed: [String]) {
        var done = 0
        var failed: [String] = []
        for p in pairs {
            let name = contact(p.target)?.record.displayName ?? p.target
            let data = photo(p.source)
            guard AccountCompare.isValidImage(data), let jpeg = AccountCompare.standardJPEG(data) else { continue }
            do {
                let m = try refetch(p.target).mutableCopy() as! CNMutableContact
                m.imageData = jpeg
                let req = CNSaveRequest()
                req.update(m)
                try store.execute(req)
                done += 1
            } catch {
                debugLog("push photo \(name) failed: \(error)")
                failed.append("\(name): \(Self.shortError(error))")
            }
        }
        debugLog("pushed photos \(done), failed \(failed.count)")
        await load(silent: true)
        return (done, failed)
    }

    /// Удаляет одно значение многозначного поля (телефон, email, сайт, соцпрофиль…) у контакта.
    /// Остальное не меняется; копия контакта — в историю.
    func removeValue(contactId: String, itemId: String) async {
        guard let c = cnById[contactId] else { return }
        let note = contact(contactId)?.record.note ?? ""
        do {
            try archive([c], action: "remove-value")
            var base = c
            // у контакта с заметкой многозначные поля не меняются (134092): заметку временно убираем целиком
            if !note.isEmpty {
                try setNoteViaAppleScript(contactId: contactId, note: "")
                base = try refetch(contactId)
            }
            let keep = Set(ContactMerge.labeled(base).map(\.0.id)).subtracting([itemId])
            let m = ContactMerge.build(primary: base, others: [], scalars: [:], birthday: base.birthday,
                                       imageData: base.imageData, keep: keep)
            let req = CNSaveRequest()
            req.update(m)
            do { try store.execute(req) } catch {
                if !note.isEmpty { try? setNoteViaAppleScript(contactId: contactId, note: note) }
                throw error
            }
            if !note.isEmpty { try setNoteViaAppleScript(contactId: contactId, note: note) }
            debugLog("removed value \(itemId) from \(contactId)")
        } catch {
            errorMessage = "Не удалось удалить значение: \(error)"
        }
        await load(silent: true)
    }

    /// Заново читает контакт из базы (например, после удаления заметки через Contacts.app):
    /// у объекта, прочитанного раньше, заметка ещё есть, и сохранить его Contacts.framework не даст (134092).
    func refetch(_ id: String) throws -> CNContact {
        let req = CNContactFetchRequest(keysToFetch: baseKeys)
        req.predicate = CNContact.predicateForContacts(withIdentifiers: [id])
        req.unifyResults = false
        var found: CNContact?
        try store.enumerateContacts(with: req) { c, stop in found = c; stop.pointee = true }
        guard let found else { throw ToolError("Контакт \(id) не найден") }
        return found
    }

    /// Коротко об ошибке для сводки: код и суть без длинного UserInfo.
    static func shortError(_ error: Error) -> String {
        let e = error as NSError
        if e.code == 134092 { return "заметка (134092)" }
        return "\(e.domain) \(e.code)"
    }

    // MARK: - Транслитерация

    func hasCyrillicName(_ r: ContactRecord) -> Bool {
        Translit.hasCyrillic(r.givenName) || Translit.hasCyrillic(r.middleName) || Translit.hasCyrillic(r.familyName)
    }

    /// Было → станет, для подтверждения.
    func translitPreview(_ id: String) -> (from: String, to: String)? {
        guard let r = contact(id)?.record, hasCyrillicName(r) else { return nil }
        let from = [r.givenName, r.middleName, r.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        return (from, Translit.latin(from))
    }

    /// Переводит имя, отчество и фамилию в латиницу (кириллица заменяется). Копии — в историю.
    func transliterate(_ ids: [String]) async {
        let targets = ids.compactMap { id in cnById[id].flatMap { c in contact(id).map { (c, $0.record) } } }
            .filter { hasCyrillicName($0.1) }
        guard !targets.isEmpty else { return }
        do {
            try archive(targets.map(\.0), action: "translit")
            let plain = targets.filter { !hasNote($0.0.identifier) }
            if !plain.isEmpty {
                let req = CNSaveRequest()
                for (c, r) in plain {
                    let m = c.mutableCopy() as! CNMutableContact
                    m.givenName = Translit.latin(r.givenName)
                    m.middleName = Translit.latin(r.middleName)
                    m.familyName = Translit.latin(r.familyName)
                    req.update(m)
                }
                try store.execute(req)
            }
            for (c, r) in targets where hasNote(c.identifier) {
                try setNamesViaAppleScript(contactId: c.identifier, first: Translit.latin(r.givenName),
                                           middle: Translit.latin(r.middleName), last: Translit.latin(r.familyName))
            }
            debugLog("transliterated \(targets.count)")
            await load(silent: true)
        } catch {
            errorMessage = "Не удалось перевести имена в латиницу: \(error)"
            await load(silent: true)
        }
    }

    // MARK: - Объединение

    func cnContact(_ id: String) -> CNContact? { cnById[id] }

    var duplicateIds: Set<String> { DuplicateFinder.duplicateIds(contacts.map(\.record)) }

    /// Объединяет контакты: основной обновляется, остальные удаляются. Копии всех — в историю.
    func merge(primaryId: String, otherIds: [String], scalars: [MergeScalar: String], birthday: DateComponents?,
               imageFrom: String?, keep: Set<String>, note: String) async -> Bool {
        guard let primary = cnById[primaryId] else { return false }
        let others = otherIds.compactMap { cnById[$0] }
        let oldNote = contact(primaryId)?.record.note ?? ""
        do {
            try archive([primary] + others, action: "merge")
            // Contacts.framework не сохраняет контакт с заметкой (134092): сначала убираем заметку
            // и строим объединённый контакт на свежем объекте из базы
            var base = primary
            if !oldNote.isEmpty {
                try setNoteViaAppleScript(contactId: primaryId, note: "")
                base = try refetch(primaryId)
            }
            let m = ContactMerge.build(primary: base, others: others, scalars: scalars, birthday: birthday,
                                       imageData: imageFrom.flatMap { photo($0) }, keep: keep)
            do {
                let req = CNSaveRequest()
                req.update(m)
                try store.execute(req)
            } catch {
                if !oldNote.isEmpty { try? setNoteViaAppleScript(contactId: primaryId, note: oldNote) }
                throw error
            }
            if note != "" || !oldNote.isEmpty { try setNoteViaAppleScript(contactId: primaryId, note: note) }
            // только после успешного обновления основного — удаляем остальные
            let (withNote, plain) = split(others)
            if !plain.isEmpty {
                let req = CNSaveRequest()
                for c in plain { req.delete(c.mutableCopy() as! CNMutableContact) }
                try store.execute(req)
            }
            for c in withNote { try deleteContactViaAppleScript(contactId: c.identifier) }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HHmmss"
            appendHistory(["\(fmt.string(from: Date()))\tmerge\t\(m.givenName) \(m.familyName)\t\(primaryId) ← \(otherIds.joined(separator: ", "))"])
            debugLog("merged \(otherIds.count) into \(primaryId)")
            await load(silent: true)
            tableSelection = [primaryId]
            return true
        } catch let e as NSError where e.code == 134092 {
            errorMessage = "Не удалось сохранить основной контакт: у него заметка, и macOS не даёт его изменить. Выберите основным контакт без заметки. Ничего не удалено."
            return false
        } catch {
            errorMessage = "Не удалось объединить: \(error)"
            await load(silent: true)
            return false
        }
    }

    /// Пользователи Telegram (из ваших контактов Telegram), связанные с этими контактами Apple.
    func linkedTelegramUsers(_ appleIds: Set<String>) -> [TGUser] {
        let m = matcher
        var seen = Set<Int64>()
        return appleIds.compactMap { id -> TGUser? in
            guard let r = contact(id)?.record, case .linked(_, _, let u?, _) = m.status(r), seen.insert(u.id).inserted
            else { return nil }
            return u
        }
    }

    /// Контакты Apple, связанные с этими пользователями Telegram.
    func linkedAppleIds(_ users: [TGUser]) -> Set<String> {
        let m = matcher
        return Set(users.flatMap { m.appleContacts(for: $0) })
    }

    /// Удаляет контакты Apple и связанных с ними пользователей из контактов Telegram.
    func deleteEverywhere(appleIds: Set<String>) async {
        let tgUsers = linkedTelegramUsers(appleIds)
        await delete(appleIds)
        if !tgUsers.isEmpty { await deleteTelegramContacts(tgUsers) }
    }

    /// Удаляет пользователей из контактов Telegram и связанные с ними контакты Apple.
    func deleteEverywhere(telegramUsers users: [TGUser]) async {
        let appleIds = linkedAppleIds(users)
        await deleteTelegramContacts(users)
        if !appleIds.isEmpty { await delete(appleIds) }
    }

    func deleteTelegramContacts(_ users: [TGUser]) async {
        guard let telegram, !users.isEmpty else { return }
        do {
            await telegram.ensurePhotos()
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd_HHmmss"
            let stamp = fmt.string(from: Date())
            let dir = historyDir.appendingPathComponent("\(stamp)_telegram-delete")
            let fresh = users.map { u in telegram.users.first { $0.id == u.id } ?? u }
            _ = try writeTelegramBackup(fresh, to: dir)
            appendHistory(users.map { "\(stamp)\ttelegram-delete\t\($0.name)\t\(dir.lastPathComponent)" })
            let next = nextSelection(removing: Set(users.map(\.id)), order: telegram.tableOrder)
            try await telegram.removeContacts(users.map(\.id))
            telegram.selection = next.map { [$0] } ?? []
        } catch {
            errorMessage = "Не удалось удалить контакты Telegram: \(error)"
        }
    }

    private func appendHistory(_ lines: [String]) {
        let logURL = historyDir.appendingPathComponent("history.log")
        let text = lines.map { $0 + "\n" }.joined()
        try? FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(text.utf8)); try? h.close()
        } else {
            try? text.write(to: logURL, atomically: true, encoding: .utf8)
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
                let photos = externalPhotos
                let summary = try await Task.detached {
                    try runBackup(result: result, notes: notes, extraPhotos: photos, telegram: users, to: dir)
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
        case .summary, .backups, .all, .telegram, .compare: break
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
        case .tgNeedsFix: list = list.filter { TelegramLink.fixReason($0.record) != nil }
        case .cyrillicNames: list = list.filter { hasCyrillicName($0.record) }
        case .brokenPhoto: list = list.filter { brokenPhotoIds.contains($0.id) }
        case .duplicates:
            let ids = DuplicateFinder.duplicateIds(contacts.map(\.record))
            list = list.filter { ids.contains($0.id) }
        case .tgNameDiffers:
            let m = matcher
            list = list.filter { nameDiffersFromTelegram($0.record, matcher: m) }
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

/// Строка, которую выделить после удаления: следующая за последней удалённой, иначе предыдущая.
func nextSelection<T: Hashable>(removing: Set<T>, order: [T]) -> T? {
    let idx = order.indices.filter { removing.contains(order[$0]) }
    guard let first = idx.first, let last = idx.last else { return nil }
    return order[(last + 1)...].first { !removing.contains($0) } ?? order[..<first].last { !removing.contains($0) }
}
