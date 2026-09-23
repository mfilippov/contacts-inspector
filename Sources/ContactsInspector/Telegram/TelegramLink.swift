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
    var birthday: DateComponents? = nil   // день/месяц, год — если открыт
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

    /// Варианты таймера для меню.
    static let autoDeleteOptions: [(title: String, seconds: Int)] = [
        ("Выключить", 0), ("1 день", 86_400), ("1 неделя", 604_800), ("1 месяц", 2_678_400),
    ]

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
/// Связь контакта Apple с Telegram — в формате официального Telegram для iPhone
/// (submodules/AccountContext/Sources/DeviceContactData.swift): URL с меткой «Telegram»
/// и значением «https://t.me/@id<ID>». По нему Telegram сам узнаёт контакт; https-ссылка
/// переживает синхронизацию iCloud (соцпрофиль с tg://… iCloud выбрасывает).
/// Если есть username — дополнительно соцпрофиль «Telegram» со ссылкой https://t.me/<username>.
enum TelegramLink {
    static let service = "Telegram"
    static let urlLabel = "Telegram"
    private static let officialPrefix = "https://t.me/@id"

    static func isTelegram(_ service: String) -> Bool {
        service.caseInsensitiveCompare(Self.service) == .orderedSame
    }

    static func officialURL(_ id: Int64) -> String { officialPrefix + String(id) }

    /// ID из официальной ссылки «https://t.me/@id123» (как её разбирает Telegram).
    static func officialId(_ url: String) -> Int64? {
        guard url.hasPrefix(officialPrefix) else { return nil }
        return Int64(url.dropFirst(officialPrefix.count))
    }

    /// ID связанного пользователя: из официальной ссылки, иначе из соцпрофиля (старый формат).
    static func linkedId(_ r: ContactRecord) -> Int64? {
        r.urlAddresses.lazy.compactMap { officialId($0.value) }.first
            ?? r.socialProfiles.lazy.filter { isTelegram($0.service) }.compactMap { Int64($0.userIdentifier) }.first
    }

    static func linkedUsername(_ r: ContactRecord) -> String? {
        r.socialProfiles.first { isTelegram($0.service) && !$0.username.isEmpty && Int64($0.userIdentifier) != nil }?.username
    }

    /// ID из битой ссылки Telegram для iPhone 2021–2022 годов: «https://t.me/@idId(rawValue: 123456789)».
    static func brokenLinkId(_ url: String) -> Int64? {
        guard let r = url.range(of: #"t\.me/@idId\(rawValue:\s*(\d+)"#, options: .regularExpression) else { return nil }
        return Int64(url[r].filter(\.isNumber))
    }

    static func brokenLinkIds(_ r: ContactRecord) -> [Int64] {
        r.urlAddresses.compactMap { brokenLinkId($0.value) }
    }

    /// Почему связь нужно исправить (nil — всё в порядке).
    static func fixReason(_ r: ContactRecord) -> String? {
        if let id = brokenLinkIds(r).first { return "Битая ссылка Telegram (ID \(id))" }
        let hasOfficial = r.urlAddresses.contains { officialId($0.value) != nil }
        let legacy = r.socialProfiles.filter { isTelegram($0.service) && Int64($0.userIdentifier) != nil }
        if !hasOfficial, let id = legacy.first.flatMap({ Int64($0.userIdentifier) }) {
            return "Связь в старом формате (ID \(id))"
        }
        if legacy.contains(where: { $0.urlString.hasPrefix("tg:") || ($0.username.isEmpty && $0.urlString.isEmpty) }) {
            return "Лишний профиль Telegram без ссылки"
        }
        return nil
    }

    /// ID, который будет прописан при исправлении.
    static func fixTargetId(_ r: ContactRecord) -> Int64? { linkedId(r) ?? brokenLinkIds(r).first }

    /// Прописывает связь (user != nil) или убирает её (user == nil) в копии контакта.
    /// Старые и битые форматы при этом удаляются, остальные URL и соцпрофили не трогаются.
    static func setLink(_ m: CNMutableContact, from c: CNContact, user: TGUser?) {
        let otherURLs = c.urlAddresses.filter { lv in
            let v = lv.value as String
            return officialId(v) == nil && brokenLinkId(v) == nil
        }
        let otherProfiles = c.socialProfiles.filter { !isLinkProfile($0.value) }
        guard let user else {
            m.urlAddresses = otherURLs
            m.socialProfiles = otherProfiles
            return
        }
        m.urlAddresses = otherURLs + [CNLabeledValue(label: urlLabel, value: officialURL(user.id) as NSString)]
        m.socialProfiles = otherProfiles + (usernameProfile(for: user).map { [$0] } ?? [])
    }

    /// Соцпрофиль связи, который мы пишем или должны заменить: Telegram с числовым ID,
    /// со ссылкой tg://… или совсем пустой. Профили, созданные другими приложениями
    /// (например, Telegram с телефоном вместо ника), не трогаем.
    private static func isLinkProfile(_ p: CNSocialProfile) -> Bool {
        isTelegram(p.service) && (Int64(p.userIdentifier) != nil || p.urlString.hasPrefix("tg:")
            || (p.username.isEmpty && p.urlString.isEmpty))
    }

    /// Соцпрофиль с username (только если он есть) — кликабельная ссылка в «Контактах».
    static func usernameProfile(for u: TGUser) -> CNLabeledValue<CNSocialProfile>? {
        guard let un = u.username else { return nil }
        return CNLabeledValue(label: nil, value: CNSocialProfile(urlString: "https://t.me/\(un)", username: un,
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
        // сначала — ID из битой ссылки Telegram (надёжнее телефона)
        if let u = TelegramLink.brokenLinkIds(r).compactMap({ usersById[$0] }).first, appleByTelegramId[u.id] == nil {
            return .suggested(u)
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
