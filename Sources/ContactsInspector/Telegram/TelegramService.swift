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
    @Published var lastError: String?

    /// Один менеджер на процесс: он держит поток td_receive.
    private lazy var manager = TDLibClientManager()
    private var client: TDLibClient?
    private var config: TelegramConfig?

    init() {
        config = TelegramConfig.load()
        auth = config == nil ? .notConfigured : .signedOut
    }

    /// Если уже входили раньше — база TDLib на месте, запускаемся автоматически.
    var hasSession: Bool {
        FileManager.default.fileExists(atPath: TelegramConfig.dir.appendingPathComponent("db/td.binlog").path)
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

    func start() {
        guard config != nil, client == nil else { return }
        auth = .starting
        client = manager.createClient { [weak self] data, client in
            guard let update = try? client.decoder.decode(Update.self, from: data) else { return }
            Task { @MainActor in self?.handle(update) }
        }
    }

    // MARK: - Вход

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
        debugLog("telegram auth: \(state)")
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
            auth = config == nil ? .notConfigured : .signedOut
        case .authorizationStateWaitEmailAddress, .authorizationStateWaitEmailCode:
            auth = .unsupported("Telegram просит подтвердить email — сделайте это в официальном клиенте и попробуйте снова.")
        case .authorizationStateWaitRegistration:
            auth = .unsupported("Для этого номера нет аккаунта Telegram.")
        case .authorizationStateWaitOtherDeviceConfirmation, .authorizationStateWaitPremiumPurchase:
            auth = .unsupported("Этот способ входа не поддерживается. Попробуйте позже.")
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
            for u in users where u.photoFileId != nil && u.photoPath == nil {
                _ = try? await client.downloadFile(fileId: u.photoFileId, limit: 0, offset: 0, priority: 1, synchronous: false)
            }
        } catch {
            lastError = Self.describe(error)
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
                  photoPath: (small?.local.isDownloadingCompleted ?? false) ? small?.local.path : nil)
    }
}
