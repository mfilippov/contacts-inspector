import AppKit
import CoreImage
import SwiftUI

/// Раздел «Telegram»: вход и таблица контактов Telegram со связями с Apple.
struct TelegramView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var tg: TelegramService

    var body: some View {
        Group {
            switch tg.auth {
            case .ready:
                TelegramContactsTable()
            case .notConfigured:
                TelegramSetupView()
            case .signedOut:
                ContentUnavailableView {
                    Label("Telegram не подключён", systemImage: "paperplane")
                } description: {
                    Text("Войдите, чтобы сопоставить контакты Telegram с контактами Apple.")
                } actions: {
                    Button("Войти") { tg.start() }.buttonStyle(.borderedProminent)
                }
            case .starting, .loggingOut:
                ProgressView(tg.auth == .starting ? "Подключаюсь к Telegram…" : "Выхожу…")
            case .waitPhone:
                TelegramLoginChoice()
            case .waitQR(let link):
                TelegramQRView(link: link)
            case .waitCode(let info):
                TelegramStep(title: "Код подтверждения", prompt: "12345", note: info) { tg.submitCode($0) }
            case .waitPassword(let hint):
                TelegramStep(title: "Пароль двухэтапной проверки", prompt: "Пароль",
                             note: hint.isEmpty ? "" : "Подсказка: \(hint)", secure: true) { tg.submitPassword($0) }
            case .unsupported(let msg):
                ContentUnavailableView("Вход не завершён", systemImage: "exclamationmark.triangle", description: Text(msg))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Telegram")
        .alert("Telegram", isPresented: Binding(get: { tg.lastError != nil }, set: { if !$0 { tg.lastError = nil } })) {
            Button("OK") { tg.lastError = nil }
        } message: {
            Text(tg.lastError ?? "")
        }
    }
}

/// Ожидание номера: сразу запрашиваем QR-код — это основной способ входа.
private struct TelegramLoginChoice: View {
    @EnvironmentObject var tg: TelegramService

    var body: some View {
        ProgressView("Готовлю QR-код…")
            .task { tg.requestQR() }
    }
}

/// Вход по номеру телефона — запасной вариант под QR-кодом.
private struct PhoneLoginSection: View {
    @EnvironmentObject var tg: TelegramService
    @State private var expanded = false
    @State private var phone = ""

    var body: some View {
        DisclosureGroup("Войти по номеру телефона", isExpanded: $expanded) {
            HStack {
                TextField("+7 900 000-00-00", text: $phone).onSubmit(send).frame(width: 200)
                Button("Получить код", action: send).disabled(phone.trimmed.isEmpty)
            }
            .padding(.top, 6)
        }
        .frame(width: 320)
    }

    private func send() {
        guard !phone.trimmed.isEmpty else { return }
        tg.submitPhone(phone.trimmed)
    }
}

private struct TelegramQRView: View {
    @EnvironmentObject var tg: TelegramService
    let link: String

    var body: some View {
        VStack(spacing: 16) {
            if let img = qrImage(link) {
                Image(nsImage: img).interpolation(.none).resizable().frame(width: 240, height: 240)
                    .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("1. Откройте Telegram на телефоне")
                Text("2. Настройки → Устройства → Подключить устройство")
                Text("3. Наведите камеру на этот код")
            }
            Text("Код обновляется автоматически. Если включён облачный пароль, после сканирования приложение его спросит.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
            PhoneLoginSection()
        }
        .padding()
    }

    private func qrImage(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

private struct TelegramSetupView: View {
    @EnvironmentObject var tg: TelegramService
    @State private var apiId = ""
    @State private var apiHash = ""

    var body: some View {
        Form {
            Section {
                Text("В эту сборку не встроены ключи Telegram API. Их можно ввести вручную — они бесплатные.")
                Link("Открыть my.telegram.org → API development tools", destination: URL(string: "https://my.telegram.org/apps")!)
                Text("Создайте приложение (название любое, платформа Desktop) и скопируйте App api_id и App api_hash. Ключи хранятся в связке ключей macOS.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Ключи API") {
                TextField("api_id", text: $apiId)
                TextField("api_hash", text: $apiHash)
            }
            Button("Подключить") { tg.configure(apiId: Int(apiId.trimmed) ?? 0, apiHash: apiHash) }
                .buttonStyle(.borderedProminent)
                .disabled(Int(apiId.trimmed) == nil || apiHash.trimmed.count < 16)
        }
        .formStyle(.grouped)
        .frame(maxWidth: 560)
    }
}

private struct TelegramStep: View {
    let title: String
    let prompt: String
    let note: String
    var secure = false
    let submit: (String) -> Void
    @State private var value = ""

    var body: some View {
        Form {
            Section(title) {
                if secure {
                    SecureField(prompt, text: $value).onSubmit(send)
                } else {
                    TextField(prompt, text: $value).onSubmit(send)
                }
                if !note.isEmpty { Text(note).font(.callout).foregroundStyle(.secondary) }
            }
            Button("Продолжить", action: send).buttonStyle(.borderedProminent).disabled(value.trimmed.isEmpty)
        }
        .formStyle(.grouped)
        .frame(maxWidth: 480)
    }

    private func send() {
        guard !value.trimmed.isEmpty else { return }
        submit(value.trimmed)
        value = ""
    }
}

// MARK: - Таблица контактов Telegram

struct TGRow: Identifiable {
    let user: TGUser
    let appleIds: [String]
    let appleName: String
    let suggestedId: String?   // контакт Apple, найденный по телефону (если ещё не связан)
    let chat: TGChatInfo?
    var id: Int64 { user.id }
    /// Для сортировки: 0 — нет чата, 1 — архив, 2 — есть; затем по дате последнего сообщения.
    var chatSort: String {
        guard let c = chat, c.hasDialog else { return "0" }
        return (c.isArchived ? "1" : "2") + String(Int(c.lastMessageDate?.timeIntervalSince1970 ?? 0))
    }
    var autoDelete: Int { chat?.autoDelete ?? 0 }
    var name: String { user.name }
    var phone: String { user.phoneDisplay }
    var username: String { user.username.map { "@\($0)" } ?? "" }
    var idText: String { String(user.id) }
}

private struct TelegramContactsTable: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var tg: TelegramService
    @State private var selection = Set<Int64>()
    @State private var search = ""
    @State private var pickFor: TGUser?
    @State private var confirmSync = false
    @State private var sortOrder = [KeyPathComparator(\TGRow.name)]
    @State private var showCard = true

    var body: some View {
        let rows = makeRows().sorted(using: sortOrder)
        let plan = model.telegramSyncPlan()
        VStack(spacing: 0) {
            HStack {
                Text("Контактов в Telegram: \(tg.users.count) · связано: \(rows.filter { !$0.appleIds.isEmpty }.count) · с чатом: \(rows.filter { $0.chat?.hasDialog == true }.count)")
                    .foregroundStyle(.secondary)
                if tg.loadingContacts || tg.loadingChats { ProgressView().controlSize(.small) }
                Spacer()
                Button { Task { await tg.loadContacts() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                Button { model.backupNow() } label: { Label("Бэкап", systemImage: "externaldrive.badge.plus") }
                    .disabled(model.backupInProgress)
                    .help("Полный бэкап: контакты Apple и Telegram")
                Button { confirmSync = true } label: { Label("Синхронизировать (\(plan.count))", systemImage: "link") }
                    .buttonStyle(.borderedProminent)
                    .disabled(plan.isEmpty)
                Button("Выйти") { tg.logOut() }
            }
            .padding(10)
            Divider()
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("") { (r: TGRow) in TGAvatar(path: r.user.photoPath, size: 20) }.width(24)
                TableColumn("Имя", value: \TGRow.name).width(min: 120, ideal: 180)
                TableColumn("Телефон", value: \TGRow.phone).width(min: 100, ideal: 140)
                TableColumn("Username", value: \TGRow.username).width(min: 80, ideal: 130)
                TableColumn("ID", value: \TGRow.idText) { (r: TGRow) in
                    Text(r.idText).monospacedDigit().foregroundStyle(.secondary)
                }.width(min: 80, ideal: 110)
                TableColumn("Контакт Apple", value: \TGRow.appleName) { (r: TGRow) in AppleLinkCell(row: r) }
                    .width(min: 150, ideal: 220)
                TableColumn("Чат", value: \TGRow.chatSort) { (r: TGRow) in ChatCell(chat: r.chat) }
                    .width(min: 80, ideal: 110)
                TableColumn("Автоудаление", value: \TGRow.autoDelete) { (r: TGRow) in
                    Text(TGChatInfo.describeAutoDelete(r.autoDelete))
                }.width(min: 70, ideal: 90)
            }
            .contextMenu(forSelectionType: Int64.self) { ids in
                if ids.count == 1, let r = rows.first(where: { $0.id == ids.first }) {
                    if let sid = r.suggestedId, r.appleIds.isEmpty {
                        Button("Связать с «\(model.contact(sid)?.record.displayName ?? "")»") {
                            Task { await model.setTelegramLinks([(sid, r.user)]) }
                        }
                    }
                    Button("Связать с контактом Apple…") { pickFor = r.user }
                    if !r.appleIds.isEmpty {
                        Button("Отвязать") { Task { await model.setTelegramLinks(r.appleIds.map { ($0, nil) }) } }
                        Button("Показать контакт Apple") { model.filter = .all; model.search = ""; model.tableSelection = Set(r.appleIds) }
                    }
                    Divider()
                    Button("Открыть в Telegram") { NSWorkspace.shared.open(URL(string: r.user.link)!) }
                }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Имя, телефон, username")
        }
        .inspector(isPresented: $showCard) {
            Group {
                if selection.count == 1, let u = tg.users.first(where: { $0.id == selection.first }) {
                    TelegramContactCard(user: u).id(u.id)
                } else {
                    Text(selection.isEmpty ? "Выберите контакт" : "Выбрано: \(selection.count)").foregroundStyle(.secondary)
                }
            }
            .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
        }
        .toolbar {
            ToolbarItem {
                Button { showCard.toggle() } label: { Label("Карточка", systemImage: "sidebar.right") }
            }
        }
        .sheet(item: $pickFor) { user in
            AppleContactPicker(title: "Связать «\(user.name)» с контактом Apple") { id in
                Task { await model.setTelegramLinks([(id, user)]) }
            }
        }
        .confirmationDialog("Синхронизировать с Telegram?", isPresented: $confirmSync, titleVisibility: .visible) {
            Button("Записать связи (\(plan.count))") { Task { await model.setTelegramLinks(plan.map { ($0.contactId, $0.user) }) } }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(syncMessage(plan))
        }
    }

    private func makeRows() -> [TGRow] {
        let m = model.matcher
        // обратный индекс: пользователь Telegram → контакт Apple, предложенный по телефону
        var suggested: [Int64: String] = [:]
        for c in model.contacts { if case .suggested(let u) = m.status(c.record) { suggested[u.id] = c.id } }
        let q = search.trimmed
        return tg.users
            .filter { u in
                q.isEmpty || u.name.localizedCaseInsensitiveContains(q) || u.phone.contains(q.filter(\.isNumber).isEmpty ? "\u{0}" : q.filter(\.isNumber))
                    || (u.username ?? "").localizedCaseInsensitiveContains(q)
            }
            .map { u in
                let ids = m.appleContacts(for: u)
                let name = ids.compactMap { model.contact($0)?.record.displayName }.joined(separator: ", ")
                return TGRow(user: u, appleIds: ids, appleName: name.isEmpty ? (suggested[u.id].flatMap { model.contact($0)?.record.displayName }.map { "~ " + $0 } ?? "") : name,
                             suggestedId: suggested[u.id], chat: tg.chats[u.id])
            }
    }

    private func syncMessage(_ plan: [(contactId: String, user: TGUser)]) -> String {
        let lines = plan.prefix(12).map { p in
            "\(model.contact(p.contactId)?.record.displayName ?? "?") → \(p.user.username.map { "@\($0)" } ?? p.user.name) (\(p.user.id))"
        }
        var text = "В контакты Apple будет прописан Telegram (ID, username, ссылка):\n\n" + lines.joined(separator: "\n")
        if plan.count > 12 { text += "\n… и ещё \(plan.count - 12)" }
        return text + "\n\nКопии контактов до изменения сохранятся в истории."
    }
}

private struct ChatCell: View {
    let chat: TGChatInfo?
    var body: some View {
        if let c = chat, c.hasDialog {
            HStack(spacing: 4) {
                Image(systemName: c.isArchived ? "archivebox" : "bubble.left.and.bubble.right")
                    .foregroundStyle(c.isArchived ? Color.secondary : Color.accentColor)
                Text(c.lastMessageDate?.formatted(date: .numeric, time: .omitted) ?? "")
            }
            .help(c.isArchived ? "Чат в архиве" : "Есть чат")
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Карточка контакта Telegram

struct TelegramContactCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var tg: TelegramService
    let user: TGUser
    @State private var full: TGFullInfo?
    @State private var bigPhoto: String?
    @State private var picking = false

    var body: some View {
        let m = model.matcher
        let linked = m.appleContacts(for: user)
        let suggested = model.contacts.first { if case .suggested(let u) = m.status($0.record) { u.id == user.id } else { false } }
        let chat = tg.chats[user.id]
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    TGAvatar(path: bigPhoto ?? user.photoPath, size: 96)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(user.name).font(.title2.bold()).textSelection(.enabled)
                        if !user.usernames.isEmpty {
                            Text(user.usernames.map { "@\($0)" }.joined(separator: " ")).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Text(user.status).font(.caption).foregroundStyle(.secondary)
                        Button("Открыть в Telegram") { NSWorkspace.shared.open(URL(string: user.link)!) }
                            .controlSize(.small)
                    }
                }

                CardSection(title: "Контакт", rows: [
                    ("Телефон", user.phoneDisplay),
                    ("ID", String(user.id)),
                    ("Взаимный контакт", user.isMutual ? "да" : "нет"),
                ])

                if let full {
                    CardSection(title: "О пользователе", rows: [
                        ("О себе", full.bio),
                        ("День рождения", full.birthdate),
                        ("Ваша заметка", full.note),
                        ("Общие группы", full.groupsInCommon > 0 ? String(full.groupsInCommon) : ""),
                    ])
                } else {
                    ProgressView().controlSize(.small)
                }

                CardSection(title: "Чат", rows: chat?.hasDialog == true ? [
                    ("Статус", chat!.isArchived ? "в архиве" : "в основном списке"),
                    ("Последнее сообщение", chat!.lastMessageDate?.formatted(date: .abbreviated, time: .shortened) ?? ""),
                    ("Автоудаление", chat!.autoDelete > 0 ? TGChatInfo.describeAutoDelete(chat!.autoDelete) : "выключено"),
                ] : [("Статус", tg.loadingChats ? "загружаю чаты…" : "чата нет")])

                VStack(alignment: .leading, spacing: 6) {
                    Text("Контакт Apple").font(.headline)
                    if !linked.isEmpty {
                        ForEach(linked, id: \.self) { id in
                            HStack {
                                Avatar(data: model.contact(id)?.thumbnail, size: 22)
                                Text(model.contact(id)?.record.displayName ?? id)
                                Spacer()
                                Button("Показать") { model.filter = .all; model.search = ""; model.tableSelection = [id] }
                            }
                        }
                        Button("Отвязать", role: .destructive) {
                            Task { await model.setTelegramLinks(linked.map { ($0, nil) }) }
                        }.controlSize(.small)
                    } else if let s = suggested {
                        Text("Найден по телефону: \(s.record.displayName)").foregroundStyle(.orange)
                        HStack {
                            Button("Связать") { Task { await model.setTelegramLinks([(s.id, user)]) } }
                            Button("Другой…") { picking = true }
                        }.controlSize(.small)
                    } else {
                        Text("Не связан").foregroundStyle(.secondary)
                        Button("Связать с контактом Apple…") { picking = true }.controlSize(.small)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            full = await tg.fullInfo(user.id)
            bigPhoto = await tg.bigPhoto(user)
        }
        .sheet(isPresented: $picking) {
            AppleContactPicker(title: "Связать «\(user.name)» с контактом Apple") { id in
                Task { await model.setTelegramLinks([(id, user)]) }
            }
        }
    }
}

/// Секция карточки: показывает только непустые строки.
private struct CardSection: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        let filled = rows.filter { !$0.1.isEmpty }
        if !filled.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(Array(filled.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            Text(row.0).foregroundStyle(.secondary).frame(minWidth: 110, alignment: .leading)
                            Text(row.1).textSelection(.enabled)
                        }
                    }
                }
            }
            Divider()
        }
    }
}

private struct AppleLinkCell: View {
    let row: TGRow
    var body: some View {
        if !row.appleIds.isEmpty {
            Label(row.appleName, systemImage: "link").labelStyle(.titleAndIcon)
        } else if row.suggestedId != nil {
            Text(row.appleName.replacingOccurrences(of: "~ ", with: "найден: ")).foregroundStyle(.orange)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

struct TGAvatar: View {
    let path: String?
    let size: CGFloat
    var body: some View {
        if let path, let img = NSImage(contentsOfFile: path) {
            Image(nsImage: img).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
        } else {
            Image(systemName: "paperplane.circle.fill").resizable().foregroundStyle(.tertiary)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Выбор пары для ручной связи

struct AppleContactPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onPick: (String) -> Void
    @State private var search = ""

    var body: some View {
        let q = search.trimmed
        let items = model.contacts.filter { c in
            q.isEmpty || c.record.displayName.localizedCaseInsensitiveContains(q)
                || c.record.phoneNumbers.contains { $0.value.filter(\.isNumber).contains(q.filter(\.isNumber)) && !q.filter(\.isNumber).isEmpty }
        }.sorted { $0.record.displayName.localizedCompare($1.record.displayName) == .orderedAscending }
        PickerSheet(title: title, search: $search) {
            ForEach(items) { c in
                Button { onPick(c.id); dismiss() } label: {
                    HStack {
                        Avatar(data: c.thumbnail, size: 22)
                        Text(c.record.displayName)
                        Spacer()
                        Text(c.record.phoneNumbers.first?.value ?? "").foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}

struct TelegramUserPicker: View {
    @EnvironmentObject var tg: TelegramService
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onPick: (TGUser) -> Void
    @State private var search = ""

    var body: some View {
        let q = search.trimmed
        let items = tg.users.filter { u in
            q.isEmpty || u.name.localizedCaseInsensitiveContains(q) || (u.username ?? "").localizedCaseInsensitiveContains(q)
                || (!q.filter(\.isNumber).isEmpty && u.phone.contains(q.filter(\.isNumber)))
        }
        PickerSheet(title: title, search: $search) {
            ForEach(items) { u in
                Button { onPick(u); dismiss() } label: {
                    HStack {
                        TGAvatar(path: u.photoPath, size: 22)
                        Text(u.name)
                        if let un = u.username { Text("@\(un)").foregroundStyle(.secondary) }
                        Spacer()
                        Text(u.phoneDisplay).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
}

private struct PickerSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var search: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            TextField("Поиск", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal)
            List { content() }
        }
        .frame(width: 520, height: 560)
    }
}
