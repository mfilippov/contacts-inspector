import Foundation
import Security
import TDLibKit

/// api_id/api_hash (my.telegram.org) и ключ шифрования локальной базы TDLib.
/// Хранятся одной записью в связке ключей (Keychain).
struct TelegramConfig: Codable {
    var apiId: Int
    var apiHash: String
    var databaseKey: Data

    /// Папка базы TDLib (сама база зашифрована databaseKey).
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ContactsInspector/telegram")
    }

    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "me.filippov.ContactsInspector.telegram",
        kSecAttrAccount as String: "config",
    ]

    static func load() -> TelegramConfig? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound { debugLog("keychain load: \(status)") }
            return nil
        }
        return try? JSONDecoder().decode(TelegramConfig.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(Self.query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = Self.query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Contacts Inspector — Telegram API"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw ToolError("Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")")
        }
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }

    /// Ключи, встроенные в сборку (build-app.sh берёт их из telegram-api.env).
    static func bundledCredentials() -> (apiId: Int, apiHash: String)? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let id = info["TelegramApiId"] as? Int, let hash = info["TelegramApiHash"] as? String,
              id > 0, !hash.isEmpty else { return nil }
        return (id, hash)
    }

    static func randomKey() -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }
}

enum TGAuth: Equatable {
    case notConfigured      // нет api_id/api_hash
    case signedOut          // клиент не запущен
    case starting
    case waitPhone
    case waitQR(String)     // ссылка tg://login?token=… для QR-кода
    case waitCode(String)   // описание, куда отправлен код
    case waitPassword(String)  // подсказка к паролю
    case unsupported(String)   // шаги входа, которые приложение не поддерживает
    case ready
    case loggingOut
}

@MainActor
final class TelegramService: ObservableObject {
    @Published private(set) var auth: TGAuth
    @Published private(set) var users: [TGUser] = []
    @Published private(set) var loadingContacts = false
    /// Выделение в таблице Telegram и её текущий порядок (для выбора следующей строки после удаления).
    @Published var selection = Set<Int64>()
    var tableOrder: [Int64] = []
    /// Личные чаты: id пользователя → информация о чате.
    @Published private(set) var chats: [Int64: TGChatInfo] = [:]
    @Published private(set) var loadingChats = false
    private var chatUser: [Int64: Int64] = [:]   // chatId → userId (только личные чаты)
    @Published var lastError: String?

    /// Один менеджер на процесс: он держит поток td_receive.
    private lazy var manager = TDLibClientManager()
    private var client: TDLibClient?
    private var config: TelegramConfig?

    init() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugNoTelegram") {   // отладка: не трогаем Keychain
            config = nil
            auth = .notConfigured
            return
        }
        #endif
        var c = TelegramConfig.load()
        if let b = TelegramConfig.bundledCredentials(), c?.apiId != b.apiId || c?.apiHash != b.apiHash {
            // Ключи встроены в приложение — пользователю вводить их не нужно.
            c = TelegramConfig(apiId: b.apiId, apiHash: b.apiHash, databaseKey: c?.databaseKey ?? TelegramConfig.randomKey())
            do { try c?.save() } catch { debugLog("telegram config save: \(error)") }
        }
        config = c
        auth = config == nil ? .notConfigured : .signedOut
    }

    /// Если уже входили раньше — база TDLib на месте, запускаемся автоматически.
    var hasSession: Bool {
        config != nil && FileManager.default.fileExists(atPath: TelegramConfig.dir.appendingPathComponent("db/td.binlog").path)
    }

    func configure(apiId: Int, apiHash: String) {
        let c = TelegramConfig(apiId: apiId, apiHash: apiHash.trimmingCharacters(in: .whitespaces),
                               databaseKey: config?.databaseKey ?? TelegramConfig.randomKey())
        do {
            try c.save()
            config = c
            auth = .signedOut
            start()
        } catch {
            lastError = "Не удалось сохранить настройки: \(error)"
        }
    }

    /// TDLib запускалась в этом процессе (нужно штатно закрыть её перед выходом).
    private(set) var tdlibStarted = false

    func start() {
        guard config != nil, client == nil else { return }
        tdlibStarted = true
        auth = .starting
        client = manager.createClient { [weak self] data, client in
            guard let update = try? client.decoder.decode(Update.self, from: data) else { return }
            Task { @MainActor in self?.handle(update) }
        }
    }

    /// Штатно закрывает TDLib: `close` и ожидание authorizationStateClosed (не дольше 5 с).
    func shutdown() async {
        guard let client else { return }
        _ = try? await client.close()
        for _ in 0..<50 where self.client != nil {
            try? await Task.sleep(for: .milliseconds(100))
        }
        debugLog("telegram shutdown: \(self.client == nil ? "closed" : "timeout")")
    }

    // MARK: - Вход

    /// Вход по QR-коду: сканируется в Telegram на телефоне (Настройки → Устройства → Подключить устройство).
    func requestQR() {
        guard auth == .waitPhone else { return }   // не запрашиваем повторно
        run { try await $0.requestQrCodeAuthentication(otherUserIds: nil) }
    }
    func submitPhone(_ phone: String) { run { try await $0.setAuthenticationPhoneNumber(phoneNumber: phone, settings: nil) } }
    func submitCode(_ code: String) { run { try await $0.checkAuthenticationCode(code: code) } }
    func submitPassword(_ pwd: String) { run { try await $0.checkAuthenticationPassword(password: pwd) } }
    func logOut() { run { try await $0.logOut() } }

    private func run(_ op: @escaping (TDLibClient) async throws -> Ok) {
        guard let client else { return }
        Task {
            do { _ = try await op(client) } catch { lastError = Self.describe(error) }
        }
    }

    private func handle(_ update: Update) {
        switch update {
        case .updateAuthorizationState(let u):
            handleAuth(u.authorizationState)
        case .updateUser(let u):
            if let i = users.firstIndex(where: { $0.id == u.user.id }) {
                var nu = TGUser(u.user)
                if nu.photoFileId == users[i].photoFileId { nu.photoPath = nu.photoPath ?? users[i].photoPath }
                users[i] = nu
            }
        case .updateNewChat(let u):
            guard case .chatTypePrivate(let p) = u.chat.type else { return }
            chatUser[u.chat.id] = p.userId
            var info = chats[p.userId] ?? TGChatInfo(chatId: u.chat.id)
            info.autoDelete = u.chat.messageAutoDeleteTime
            info.lastMessageDate = u.chat.lastMessage.map { Date(timeIntervalSince1970: TimeInterval($0.date)) }
            for pos in u.chat.positions { Self.apply(pos, to: &info) }
            chats[p.userId] = info
        case .updateChatPosition(let u):
            guard let uid = chatUser[u.chatId], var info = chats[uid] else { return }
            Self.apply(u.position, to: &info)
            chats[uid] = info
        case .updateChatLastMessage(let u):
            guard let uid = chatUser[u.chatId] else { return }
            chats[uid]?.lastMessageDate = u.lastMessage.map { Date(timeIntervalSince1970: TimeInterval($0.date)) }
            for pos in u.positions { if var info = chats[uid] { Self.apply(pos, to: &info); chats[uid] = info } }
        case .updateChatMessageAutoDeleteTime(let u):
            guard let uid = chatUser[u.chatId] else { return }
            chats[uid]?.autoDelete = u.messageAutoDeleteTime
        case .updateFile(let u):
            guard u.file.local.isDownloadingCompleted else { return }
            for i in users.indices where users[i].photoFileId == u.file.id {
                users[i].photoPath = u.file.local.path
            }
        default:
            break
        }
    }

    private func handleAuth(_ state: AuthorizationState) {
        // Только имя состояния: в параметрах бывают токен QR-входа и данные номера.
        debugLog("telegram auth: \(String(describing: state).prefix { $0 != "(" })")
        switch state {
        case .authorizationStateWaitTdlibParameters:
            Task { await sendParameters() }
        case .authorizationStateWaitPhoneNumber:
            auth = .waitPhone
        case .authorizationStateWaitCode(let s):
            auth = .waitCode(Self.describe(s.codeInfo.type))
        case .authorizationStateWaitPassword(let s):
            auth = .waitPassword(s.passwordHint)
        case .authorizationStateReady:
            auth = .ready
            Task { await loadContacts() }
        case .authorizationStateLoggingOut, .authorizationStateClosing:
            auth = .loggingOut
        case .authorizationStateClosed:
            client = nil
            users = []
            chats = [:]
            chatUser = [:]
            auth = config == nil ? .notConfigured : .signedOut
        case .authorizationStateWaitEmailAddress, .authorizationStateWaitEmailCode:
            auth = .unsupported("Telegram просит подтвердить email — сделайте это в официальном клиенте и попробуйте снова.")
        case .authorizationStateWaitRegistration:
            auth = .unsupported("Для этого номера нет аккаунта Telegram.")
        case .authorizationStateWaitOtherDeviceConfirmation(let s):
            auth = .waitQR(s.link)
        case .authorizationStateWaitPremiumPurchase:
            auth = .unsupported("Telegram требует Premium для входа с этого номера. Попробуйте вход по QR-коду.")
        }
    }

    private func sendParameters() async {
        guard let client, let config else { return }
        let dir = TelegramConfig.dir
        do {
            _ = try? await client.setLogVerbosityLevel(newVerbosityLevel: 1)
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1"
            try await client.setTdlibParameters(
                apiHash: config.apiHash, apiId: config.apiId, applicationVersion: version,
                databaseDirectory: dir.appendingPathComponent("db").path,
                databaseEncryptionKey: config.databaseKey,
                deviceModel: "Mac (Contacts Inspector)",
                filesDirectory: dir.appendingPathComponent("files").path,
                systemLanguageCode: Locale.current.language.languageCode?.identifier ?? "en",
                systemVersion: nil,
                useChatInfoDatabase: true, useFileDatabase: true, useMessageDatabase: false,
                useSecretChats: false, useTestDc: false)
        } catch {
            lastError = Self.describe(error)
        }
    }

    // MARK: - Контакты

    func loadContacts() async {
        guard let client, auth == .ready else { return }
        loadingContacts = true
        defer { loadingContacts = false }
        do {
            let ids = try await client.getContacts().userIds
            var result: [TGUser] = []
            for id in ids { result.append(TGUser(try await client.getUser(userId: id))) }
            users = result.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
            debugLog("telegram contacts: \(users.count)")
            Task { await loadChats() }
            for u in users where u.photoFileId != nil && u.photoPath == nil {
                _ = try? await client.downloadFile(fileId: u.photoFileId, limit: 0, offset: 0, priority: 1, synchronous: false)
            }
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// Загружает списки «Основные» и «Архив» целиком; данные чатов приходят обновлениями updateNewChat.
    func loadChats() async {
        guard let client, auth == .ready, !loadingChats else { return }
        loadingChats = true
        defer { loadingChats = false }
        for list in [ChatList.chatListMain, .chatListArchive] {
            while true {
                do {
                    _ = try await client.loadChats(chatList: list, limit: 200)
                } catch let e as TDLibKit.Error where e.code == 404 {
                    break   // список загружен полностью
                } catch {
                    lastError = Self.describe(error)
                    break
                }
            }
        }
        debugLog("telegram private chats: \(chats.values.filter(\.hasDialog).count)")
    }

    private static func apply(_ pos: ChatPosition, to info: inout TGChatInfo) {
        let key: String
        switch pos.list {
        case .chatListMain: key = "main"
        case .chatListArchive: key = "archive"
        default: return   // папки не учитываем
        }
        if pos.order.rawValue == 0 { info.lists.remove(key) } else { info.lists.insert(key) }
    }

    // MARK: - Изменения в Telegram

    /// Запросы на подтверждение (диалоги показывает TelegramView).
    struct PendingAutoDelete: Identifiable { let id = UUID(); let userIds: [Int64]; let seconds: Int }
    @Published var pendingAutoDelete: PendingAutoDelete?
    @Published var pendingRemove: [TGUser]?
    @Published var resultMessage: String?

    /// Прогресс массовой операции («Автоудаление: 3 из 20»), nil — ничего не выполняется.
    @Published private(set) var bulkProgress: String?

    /// Ставит таймер автоудаления (0 — выключить) в личных чатах с пользователями.
    /// Возвращает число изменённых чатов и ошибки.
    func setAutoDelete(userIds: [Int64], seconds: Int) async -> (changed: Int, errors: [String]) {
        guard let client, auth == .ready else { return (0, ["Нет подключения к Telegram"]) }
        let targets = userIds.compactMap { id in chats[id].map { (id, $0) } }
            .filter { $0.1.autoDelete != seconds }
        var changed = 0
        var errors: [String] = []
        for (i, (uid, chat)) in targets.enumerated() {
            bulkProgress = "Автоудаление: \(i + 1) из \(targets.count)"
            do {
                try await withFloodRetry {
                    _ = try await client.setChatMessageAutoDeleteTime(chatId: chat.chatId, messageAutoDeleteTime: seconds)
                }
                chats[uid]?.autoDelete = seconds
                changed += 1
            } catch {
                errors.append("\(users.first { $0.id == uid }?.name ?? String(uid)): \(Self.describe(error))")
            }
            if targets.count > 1 { try? await Task.sleep(for: .milliseconds(400)) }
        }
        bulkProgress = nil
        debugLog("telegram auto-delete \(seconds)s: changed \(changed), errors \(errors.count)")
        return (changed, errors)
    }

    /// Меняет имя/фамилию контакта Telegram (видно только вам) и, если передана, вашу заметку о нём.
    func editContact(_ u: TGUser, firstName: String, lastName: String, note: String?) async throws {
        guard let client, auth == .ready else { throw ToolError("Нет подключения к Telegram") }
        try await withFloodRetry {
            _ = try await client.addContact(
                contact: ImportedContact(firstName: firstName, lastName: lastName, note: nil, phoneNumber: ""),
                sharePhoneNumber: false, userId: u.id)
        }
        if let note {
            try await withFloodRetry {
                _ = try await client.setUserNote(note: FormattedText(entities: [], text: note), userId: u.id)
            }
            fullInfoCache[u.id]?.note = note
        }
        if let i = users.firstIndex(where: { $0.id == u.id }) {
            users[i].firstName = firstName
            users[i].lastName = lastName
        }
        debugLog("telegram contact edited \(u.id)")
    }

    /// Удаляет пользователей из контактов Telegram (чаты не трогает).
    func removeContacts(_ ids: [Int64]) async throws {
        guard let client, auth == .ready else { throw ToolError("Нет подключения к Telegram") }
        bulkProgress = "Удаляю контакты: \(ids.count)"
        defer { bulkProgress = nil }
        // одним запросом, но пачками по 100, чтобы не упереться в лимиты
        for start in stride(from: 0, to: ids.count, by: 100) {
            let chunk = Array(ids[start..<min(start + 100, ids.count)])
            try await withFloodRetry { _ = try await client.removeContacts(userIds: chunk) }
            users.removeAll { chunk.contains($0.id) }
            if start + 100 < ids.count { try? await Task.sleep(for: .seconds(1)) }
        }
        debugLog("telegram removed contacts: \(ids.count)")
    }

    /// Повторяет запрос после FLOOD_WAIT (ошибка 429 «retry after N»), один раз, если ждать не больше 60 с.
    private func withFloodRetry(_ op: () async throws -> Void) async throws {
        do {
            try await op()
        } catch let e as TDLibKit.Error where e.code == 429 {
            let wait = Int(e.message.split(separator: " ").last ?? "") ?? 5
            guard wait <= 60 else { throw e }
            debugLog("telegram flood wait \(wait)s")
            bulkProgress = (bulkProgress ?? "") + " — пауза \(wait) с (лимит Telegram)"
            try await Task.sleep(for: .seconds(wait + 1))
            try await op()
        }
    }

    // MARK: - Карточка

    private var fullInfoCache: [Int64: TGFullInfo] = [:]

    func fullInfo(_ userId: Int64) async -> TGFullInfo? {
        if let cached = fullInfoCache[userId] { return cached }
        guard let client, auth == .ready else { return nil }
        do {
            let f = try await client.getUserFullInfo(userId: userId)
            var birth = ""
            var comps: DateComponents?
            if let b = f.birthdate {
                birth = String(format: "%02d.%02d", b.day, b.month) + (b.year > 0 ? ".\(b.year)" : "")
                var d = DateComponents(); d.day = b.day; d.month = b.month
                if b.year > 0 { d.year = b.year }
                comps = d
            }
            let info = TGFullInfo(bio: f.bio?.text ?? "", birthdate: birth, birthday: comps, note: f.note?.text ?? "",
                                  groupsInCommon: f.groupInCommonCount)
            fullInfoCache[userId] = info
            return info
        } catch {
            debugLog("telegram full info failed: \(Self.describe(error))")
            return nil
        }
    }

    /// Всё, что нужно для переноса в Apple: полная информация и крупное фото.
    func importSource(for u: TGUser) async -> TGImportSource {
        TGImportSource(user: u, full: await fullInfo(u.id), photo: await bigPhotoData(u))
    }

    @Published var pendingCreate: [TGUser]?

    /// Данные крупного фото (для переноса в контакт Apple).
    func bigPhotoData(_ u: TGUser) async -> Data? {
        if let path = await bigPhoto(u), let data = try? Data(contentsOf: URL(fileURLWithPath: path)) { return data }
        return u.photoPath.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
    }

    /// Крупное фото для карточки: путь к файлу после загрузки.
    func bigPhoto(_ u: TGUser) async -> String? {
        guard let client, let fid = u.bigPhotoFileId else { return nil }
        let f = try? await client.downloadFile(fileId: fid, limit: 0, offset: 0, priority: 32, synchronous: true)
        return (f?.local.isDownloadingCompleted ?? false) ? f?.local.path : nil
    }

    /// Докачивает маленькие аватарки всех контактов (перед бэкапом). Параллельно, пачками.
    func ensurePhotos() async {
        guard let client, auth == .ready else { return }
        let missing = users.filter { $0.photoFileId != nil && $0.photoPath == nil }
        guard !missing.isEmpty else { return }
        for batch in stride(from: 0, to: missing.count, by: 20).map({ Array(missing[$0..<min($0 + 20, missing.count)]) }) {
            let files = await withTaskGroup(of: (Int64, String?).self) { group in
                for u in batch {
                    group.addTask {
                        let f = try? await client.downloadFile(fileId: u.photoFileId, limit: 0, offset: 0,
                                                               priority: 16, synchronous: true)
                        return (u.id, (f?.local.isDownloadingCompleted ?? false) ? f?.local.path : nil)
                    }
                }
                var out: [(Int64, String?)] = []
                for await r in group { out.append(r) }
                return out
            }
            for (id, path) in files {
                if let path, let i = users.firstIndex(where: { $0.id == id }) { users[i].photoPath = path }
            }
        }
    }

    // MARK: - Описания

    static func describe(_ error: Swift.Error) -> String {
        if let e = error as? TDLibKit.Error { return "\(e.message) (\(e.code))" }
        return "\(error)"
    }

    private static func describe(_ type: AuthenticationCodeType) -> String {
        switch type {
        case .authenticationCodeTypeTelegramMessage: "Код отправлен в Telegram на другом вашем устройстве."
        case .authenticationCodeTypeSms, .authenticationCodeTypeSmsWord, .authenticationCodeTypeSmsPhrase: "Код отправлен по SMS."
        case .authenticationCodeTypeCall, .authenticationCodeTypeFlashCall, .authenticationCodeTypeMissedCall: "Код придёт звонком."
        default: "Код отправлен."
        }
    }
}

extension TGUser {
    init(_ u: User) {
        let small = u.profilePhoto?.small
        self.init(id: u.id, firstName: u.firstName, lastName: u.lastName, phone: u.phoneNumber,
                  usernames: u.usernames?.activeUsernames ?? [], isMutual: u.isMutualContact,
                  photoFileId: small?.id,
                  photoPath: (small?.local.isDownloadingCompleted ?? false) ? small?.local.path : nil,
                  bigPhotoFileId: u.profilePhoto?.big.id,
                  status: Self.describe(u.status))
    }

    private static func describe(_ s: UserStatus) -> String {
        switch s {
        case .userStatusOnline: return "в сети"
        case .userStatusOffline(let o):
            return "был(а) " + Date(timeIntervalSince1970: TimeInterval(o.wasOnline))
                .formatted(.relative(presentation: .named))
        case .userStatusRecently: return "был(а) недавно"
        case .userStatusLastWeek: return "был(а) на этой неделе"
        case .userStatusLastMonth: return "был(а) в этом месяце"
        case .userStatusEmpty: return "был(а) давно"
        }
    }
}
