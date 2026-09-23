import Contacts
import Foundation

/// Пользователь Telegram из списка контактов.
struct TGUser: Identifiable, Hashable {
    let id: Int64
    var firstName: String
    var lastName: String
    var phone: String          // без «+», как отдаёт Telegram: 79001234567
    var usernames: [String]
    var isMutual: Bool
    var photoFileId: Int?
    var photoPath: String?
    var bigPhotoFileId: Int? = nil
    var status: String = ""     // «в сети», «был(а) недавно», дата последнего визита

    var name: String { [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ") }
    var username: String? { usernames.first }
    var phoneDisplay: String { phone.isEmpty ? "" : "+" + phone }
    var link: String { username.map { "https://t.me/\($0)" } ?? "tg://user?id=\(id)" }
}

/// Полная информация о пользователе (загружается по требованию для карточки).
struct TGFullInfo: Equatable {
    var bio: String
    var birthdate: String
    var note: String            // ваша заметка о контакте
    var groupsInCommon: Int
}

/// Личный чат с пользователем Telegram.
struct TGChatInfo: Equatable {
    var chatId: Int64
    var lists: Set<String> = []      // "main" / "archive" — где чат есть в списке чатов
    var autoDelete: Int = 0          // таймер автоудаления, секунд (0 — выключен)
    var lastMessageDate: Date?

    var hasDialog: Bool { !lists.isEmpty }
    var isArchived: Bool { lists == ["archive"] }

    static func describeAutoDelete(_ seconds: Int) -> String {
        switch seconds {
        case 0: return ""
        case 86_400: return "1 день"
        case 604_800: return "1 неделя"
        case 2_678_400: return "1 месяц"
        case 31_536_000: return "1 год"
        default:
            let f = DateComponentsFormatter()
            f.unitsStyle = .short
            f.allowedUnits = [.year, .month, .weekOfMonth, .day, .hour, .minute]
            f.maximumUnitCount = 2
            return f.string(from: TimeInterval(seconds)) ?? "\(seconds) с"
        }
    }
}

/// Связь контакта Apple с Telegram хранится как соцпрофиль service = "Telegram":
/// userIdentifier — числовой id, username — ник, urlString — ссылка.
enum TelegramLink {
    static let service = "Telegram"

    static func isTelegram(_ service: String) -> Bool {
        service.caseInsensitiveCompare(Self.service) == .orderedSame
    }

    static func linkedId(_ r: ContactRecord) -> Int64? {
        r.socialProfiles.lazy.filter { isTelegram($0.service) }.compactMap { Int64($0.userIdentifier) }.first
    }

    static func linkedUsername(_ r: ContactRecord) -> String? {
        r.socialProfiles.first { isTelegram($0.service) && !$0.username.isEmpty }?.username
    }

    static func hasTelegramProfile(_ r: ContactRecord) -> Bool {
        r.socialProfiles.contains { isTelegram($0.service) }
    }

    static func profile(for u: TGUser) -> CNLabeledValue<CNSocialProfile> {
        CNLabeledValue(label: nil, value: CNSocialProfile(urlString: u.link, username: u.username ?? "",
                                                          userIdentifier: String(u.id), service: service))
    }

    /// Ключ для сравнения телефонов: последние 10 цифр; российская «8» в начале → «7».
    static func phoneKey(_ s: String) -> String? {
        var digits = s.filter(\.isASCII).filter(\.isNumber)
        if digits.count == 11, digits.hasPrefix("8") { digits = "7" + digits.dropFirst() }
        guard digits.count >= 10 else { return nil }
        return String(digits.suffix(10))
    }
}

/// Состояние связи контакта Apple с Telegram.
enum TGStatus: Equatable {
    /// Связан. user — если такой есть среди контактов Telegram; outdated — ник в Apple устарел.
    case linked(id: Int64, username: String?, user: TGUser?, outdated: Bool)
    /// Не связан, но по телефону найден ровно один пользователь Telegram.
    case suggested(TGUser)
    case none

    var isLinked: Bool { if case .linked = self { true } else { false } }
    var isSuggested: Bool { if case .suggested = self { true } else { false } }
}

/// Индекс для сопоставления контактов Apple и Telegram.
struct TelegramMatcher {
    let usersById: [Int64: TGUser]
    let usersByPhone: [String: [TGUser]]
    /// id Telegram → контакты Apple, где этот id уже прописан
    let appleByTelegramId: [Int64: [String]]

    init(users: [TGUser], records: [ContactRecord]) {
        usersById = Dictionary(users.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var byPhone: [String: [TGUser]] = [:]
        for u in users { if let k = TelegramLink.phoneKey(u.phone) { byPhone[k, default: []].append(u) } }
        usersByPhone = byPhone
        var byTg: [Int64: [String]] = [:]
        for r in records { if let id = TelegramLink.linkedId(r) { byTg[id, default: []].append(r.identifier) } }
        appleByTelegramId = byTg
    }

    func status(_ r: ContactRecord) -> TGStatus {
        if let id = TelegramLink.linkedId(r) {
            let user = usersById[id]
            let outdated = user.map { ($0.username ?? "") != (TelegramLink.linkedUsername(r) ?? "") } ?? false
            return .linked(id: id, username: TelegramLink.linkedUsername(r), user: user, outdated: outdated)
        }
        let candidates = Set(r.phoneNumbers.compactMap { TelegramLink.phoneKey($0.value) }
            .flatMap { usersByPhone[$0] ?? [] })
        // предлагаем, только если кандидат однозначный и ещё ни с кем не связан
        if candidates.count == 1, let u = candidates.first, appleByTelegramId[u.id] == nil {
            return .suggested(u)
        }
        return .none
    }

    /// Контакты Apple, связанные с пользователем Telegram.
    func appleContacts(for u: TGUser) -> [String] { appleByTelegramId[u.id] ?? [] }
}
