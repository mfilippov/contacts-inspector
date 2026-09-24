import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading:
                ProgressView("Загружаю контакты…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let msg):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(msg).multilineTextAlignment(.center)
                    HStack {
                        Button("Открыть настройки «Контакты»") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!)
                        }
                        Button("Повторить") { Task { await model.load() } }
                    }
                }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded:
                NavigationSplitView {
                    Sidebar()
                } detail: {
                    switch model.filter {
                    case .summary: SummaryView()
                    case .backups: BackupsView()
                    case .telegram: TelegramView()
                    case .compare: CompareView()
                    default: ContactTable()
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) { BackupBanner() }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { Task { await model.load() } } label: { Label("Обновить", systemImage: "arrow.clockwise") }
                Button {
                    try? FileManager.default.createDirectory(at: model.historyDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(model.historyDir)
                } label: { Label("История", systemImage: "clock.arrow.circlepath") }
                .help("Копии контактов до правок и удалений")
                Button { model.backupNow() } label: {
                    Label("Бэкап", systemImage: "externaldrive.badge.checkmark")
                }
                .disabled(model.state != .loaded || model.backupInProgress)
            }
        }
        .alert(deleteTitle, isPresented: Binding(get: { model.pendingDelete != nil },
                                                             set: { if !$0 { model.pendingDelete = nil } })) {
            Button("Удалить", role: .destructive) {
                if let ids = model.pendingDelete { Task { await model.delete(ids) } }
                model.pendingDelete = nil
            }
            .keyboardShortcut(.defaultAction)
            if let ids = model.pendingDelete, case let linked = model.linkedTelegramUsers(ids), !linked.isEmpty {
                Button("Удалить и из Telegram (\(linked.count))", role: .destructive) {
                    Task { await model.deleteEverywhere(appleIds: ids) }
                    model.pendingDelete = nil
                }
            }
            Button("Отмена", role: .cancel) { model.pendingDelete = nil }
        } message: {
            Text(deleteMessage + "\n\nКонтакты удалятся из iCloud и со всех устройств. Копия сохранится в истории."
                 + (model.pendingDelete.map { model.linkedTelegramUsers($0).isEmpty ? "" : "\n\n«Удалить и из Telegram» уберёт связанных пользователей из контактов Telegram (чаты останутся)." } ?? ""))
        }
        .sheet(item: Binding(get: { model.mergeIds.map { MergeRequest(ids: $0) } }, set: { model.mergeIds = $0?.ids })) { r in
            MergeSheet(ids: r.ids)
        }
        .alert("Перевести имена в латиницу (\(model.pendingTranslit?.count ?? 0))?",
               isPresented: Binding(get: { model.pendingTranslit != nil }, set: { if !$0 { model.pendingTranslit = nil } }),
               presenting: model.pendingTranslit) { ids in
            Button("Перевести") { Task { await model.transliterate(ids) } }
                .keyboardShortcut(.defaultAction)
            Button("Отмена", role: .cancel) {}
        } message: { ids in
            let lines = ids.prefix(15).compactMap { model.translitPreview($0) }.map { "\($0.from) → \($0.to)" }
            Text(lines.joined(separator: "\n") + (ids.count > 15 ? "\n… и ещё \(ids.count - 15)" : "")
                 + "\n\nКириллица будет заменена. Копии контактов сохранятся в истории.")
        }
        .alert("Контакт с заметкой", isPresented: Binding(get: { model.noteBlockedContact != nil },
                                                          set: { if !$0 { model.noteBlockedContact = nil } }),
               presenting: model.noteBlockedContact) { id in
            Button("Открыть в Контактах") { model.openInContacts(id) }
                .keyboardShortcut(.defaultAction)
            Button("Отмена", role: .cancel) {}
        } message: { _ in
            Text("macOS не даёт приложению без специального разрешения Apple сохранять контакты с заметкой. Связь с Telegram и удаление для таких контактов работают через «Контакты», а поля отредактируйте в самих «Контактах».")
        }
        .alert("Готово", isPresented: Binding(get: { model.resultMessage != nil },
                                             set: { if !$0 { model.resultMessage = nil } })) {
            Button("OK") { model.resultMessage = nil }
        } message: {
            Text(model.resultMessage ?? "")
        }
        .alert("Ошибка", isPresented: Binding(get: { model.errorMessage != nil },
                                             set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Бэкап", isPresented: Binding(get: { model.backupMessage != nil },
                                            set: { if !$0 { model.backupMessage = nil } })) {
            Button("OK") { model.backupMessage = nil }
        } message: {
            Text(model.backupMessage ?? "")
        }
    }
}

extension RootView {
    var deleteTitle: String {
        let n = model.pendingDelete?.count ?? 0
        return n == 1 ? "Удалить контакт?" : "Удалить контакты (\(n))?"
    }

    var deleteMessage: String {
        let names = (model.pendingDelete ?? []).compactMap { model.contact($0)?.record.displayName }.sorted()
        let shown = names.prefix(10).joined(separator: "\n")
        return names.count > 10 ? shown + "\n… и ещё \(names.count - 10)" : shown
    }
}

struct BackupBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            if model.backupInProgress {
                ProgressView().controlSize(.small)
                Text("Сохраняю бэкап…")
            } else if let d = model.lastBackup {
                Image(systemName: "checkmark.shield").foregroundStyle(.green)
                Text("Последний бэкап: \(d.formatted(date: .abbreviated, time: .shortened))")
            } else {
                Image(systemName: "exclamationmark.shield").foregroundStyle(.orange)
                Text("Бэкап ещё не сделан — сделайте его перед любой чисткой.")
                Button("Сделать бэкап") { model.backupNow() }
            }
            Spacer()
            Text("\(model.contacts.count) контактов · \(model.notesSource)")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var tg: TelegramService

    var body: some View {
        // Выбор реализован кнопками, а не List(selection:), — встроенный выбор в сайдбаре не срабатывал.
        List {
            SidebarRow(title: "Сводка", symbol: "chart.bar", filter: .summary)
            SidebarRow(title: "Бэкапы", symbol: "externaldrive", filter: .backups, badge: model.backups.count)
            SidebarRow(title: "Telegram", symbol: "paperplane", filter: .telegram, badge: tg.users.count)
            SidebarRow(title: "Сравнение аккаунтов", symbol: "arrow.left.arrow.right.square", filter: .compare)
            SidebarRow(title: "Все контакты", symbol: "person.crop.rectangle.stack", filter: .all,
                       badge: model.contacts.count)

            Section("Аккаунты") {
                ForEach(model.containers, id: \.identifier) { c in
                    SidebarRow(title: model.displayName(c), symbol: model.symbol(c), filter: .container(c.identifier),
                               badge: model.contacts.filter { $0.record.containerId == c.identifier }.count)
                }
            }
            if !model.groups.isEmpty {
                Section("Группы") {
                    ForEach(model.groups, id: \.identifier) { g in
                        SidebarRow(title: g.name, symbol: "folder", filter: .group(g.identifier),
                                   badge: model.contacts.filter { $0.record.groupIds.contains(g.identifier) }.count)
                    }
                }
            }
            Section("Telegram") {
                let m = model.matcher
                let statuses = model.contacts.map { m.status($0.record) }
                SidebarRow(title: "Связаны", symbol: "link", filter: .tgLinked,
                           badge: statuses.filter(\.isLinked).count)
                SidebarRow(title: "Можно связать", symbol: "link.badge.plus", filter: .tgSuggested,
                           badge: statuses.filter(\.isSuggested).count)
                SidebarRow(title: "Без Telegram", symbol: "minus.circle", filter: .tgNone,
                           badge: statuses.filter { $0 == .none }.count)
                SidebarRow(title: "Имя отличается", symbol: "person.text.rectangle", filter: .tgNameDiffers,
                           badge: model.contacts.filter { model.nameDiffersFromTelegram($0.record, matcher: m) }.count)
            }
            Section("Проблемы") {
                SidebarRow(title: "Без телефона и email", symbol: "exclamationmark.circle", filter: .noPhoneNoEmail,
                           badge: model.contacts.filter { $0.record.phoneNumbers.isEmpty && $0.record.emailAddresses.isEmpty }.count)
                SidebarRow(title: "Битое фото", symbol: "photo.badge.exclamationmark", filter: .brokenPhoto,
                           badge: model.brokenPhotoIds.count)
                SidebarRow(title: "Имя кириллицей", symbol: "character.textbox", filter: .cyrillicNames,
                           badge: model.contacts.filter { model.hasCyrillicName($0.record) }.count)
                SidebarRow(title: "Возможные дубли", symbol: "person.2.badge.gearshape", filter: .duplicates,
                           badge: model.duplicateIds.count)
                SidebarRow(title: "Исправить связи Telegram", symbol: "link.badge.plus", filter: .tgNeedsFix,
                           badge: model.linksNeedingFix.count)
                SidebarRow(title: "Без имени", symbol: "person.fill.questionmark", filter: .missing(.name),
                           badge: model.contacts.count - model.count(.name).contacts)
            }
            Section("Заполнено поле") {
                ForEach(Field.allCases) { f in
                    SidebarRow(title: f.title, symbol: f.symbol, filter: .has(f), badge: model.count(f).contacts)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230)
    }
}

struct SidebarRow: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let symbol: String
    let filter: SidebarFilter
    var badge: Int? = nil

    var body: some View {
        let selected = model.filter == filter
        Button { model.filter = filter } label: {
            HStack {
                Label(title, systemImage: symbol).lineLimit(1)
                Spacer()
                if let badge, badge > 0 {
                    Text("\(badge)").monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.25) : Color.clear)
                .padding(.horizontal, 8)
        )
    }
}

struct SummaryView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let total = max(model.contacts.count, 1)
        List {
            Section("Заполненность полей (\(model.contacts.count) контактов)") {
                ForEach(Field.allCases) { f in
                    let (c, v) = model.count(f)
                    Button { model.filter = .has(f) } label: {
                        HStack {
                            Label(f.title, systemImage: f.symbol).frame(width: 190, alignment: .leading)
                            ProgressView(value: Double(c), total: Double(total)).frame(maxWidth: 200)
                            Text("\(c)").monospacedDigit().frame(width: 50, alignment: .trailing)
                            Text("\(Int((Double(c) / Double(total) * 100).rounded()))%")
                                .monospacedDigit().foregroundStyle(.secondary).frame(width: 45, alignment: .trailing)
                            Text(v > c ? "значений: \(v)" : "").foregroundStyle(.secondary)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 500, ideal: 620)
    }
}

struct ContactTable: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var tg: TelegramService
    @State private var confirmFix = false
    @State private var sortOrder = [KeyPathComparator(\ContactRow.displayName)]
    @State private var columns = TableColumnCustomization<ContactRow>()

    var body: some View {
        let matcher = model.matcher
        let rows = model.filtered.map { ContactRow($0, telegram: matcher.status($0.record)) }.sorted(using: sortOrder)
        Table(of: ContactRow.self, selection: $model.tableSelection, sortOrder: $sortOrder,
              columnCustomization: $columns) {
            nameColumns
            dataColumns
        } rows: {
            ForEach(rows) { TableRow($0) }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.filter == .tgNeedsFix, !rows.isEmpty {
                HStack {
                    Text("Битые ссылки t.me/@idId(rawValue: …) от Telegram для iPhone и связи в старом формате. Исправление запишет официальный формат Telegram: https://t.me/@id<ID>.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Исправить все (\(rows.count))") { confirmFix = true }.buttonStyle(.borderedProminent)
                }
                .padding(8)
                .background(.bar)
            }
        }
        .alert("Исправить связи Telegram (\(model.linksNeedingFix.count))?", isPresented: $confirmFix) {
            Button("Исправить") { Task { await model.fixTelegramLinks(model.linksNeedingFix.map(\.id)) } }
                .keyboardShortcut(.defaultAction)
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("В контакты запишется ссылка Telegram в официальном формате (и username, если пользователь есть в ваших контактах Telegram), битые ссылки и старые профили будут убраны. Копии контактов сохранятся в истории.")
        }
        .contextMenu(forSelectionType: String.self) { ids in
            ContactMenuItems(ids: ids)
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { model.startEditing(id) }
        }
        .onDeleteCommand { model.confirmDelete(model.tableSelection) }
        .onChange(of: rows.map(\.id), initial: true) { _, ids in model.tableOrder = ids }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Имя, телефон, email, заметка")
        .navigationSubtitle("\(rows.count) шт.")
        .inspector(isPresented: $model.showInspector) {
            Group {
                if model.tableSelection.count == 1, let id = model.tableSelection.first,
                   model.editingId == id, let e = model.editable(id) {
                    EditContactView(id: id, original: e).id(id)
                } else if model.tableSelection.count == 1, let c = model.contact(model.tableSelection.first) {
                    ContactDetail(contact: c)
                } else if model.tableSelection.count > 1 {
                    VStack(spacing: 12) {
                        Text("Выбрано: \(model.tableSelection.count)").foregroundStyle(.secondary)
                        Button("Объединить…") { model.mergeIds = Array(model.tableSelection) }
                        Button("Удалить выбранные…", role: .destructive) { model.confirmDelete(model.tableSelection) }
                    }
                } else {
                    Text("Выберите контакт").foregroundStyle(.secondary)
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 320, max: 600)
        }
        .toolbar {
            ToolbarItem {
                Button { model.confirmDelete(model.tableSelection) } label: { Label("Удалить", systemImage: "trash") }
                    .disabled(model.tableSelection.isEmpty)
                    .help("Удалить выбранные контакты")
            }
            ToolbarItem {
                Button { model.showInspector.toggle() } label: { Label("Карточка", systemImage: "sidebar.right") }
            }
        }
    }
}

extension ContactTable {
    typealias Col = KeyPathComparator<ContactRow>

    @TableColumnBuilder<ContactRow, Col>
    var nameColumns: some TableColumnContent<ContactRow, Col> {
        TableColumn("") { (r: ContactRow) in Avatar(data: r.thumbnail, size: 20) }
            .width(24).customizationID("photo")
        TableColumn("Контакт", value: \ContactRow.displayName) { (r: ContactRow) in
            Text(r.displayName).foregroundStyle(r.hasName ? .primary : .secondary)
        }.width(min: 120, ideal: 180).customizationID("display")
        TableColumn("Имя", value: \ContactRow.givenName).width(min: 60, ideal: 90).customizationID("given")
        TableColumn("Фамилия", value: \ContactRow.familyName).width(min: 60, ideal: 100).customizationID("family")
        TableColumn("Организация", value: \ContactRow.organization).width(min: 80, ideal: 130).customizationID("org")
        TableColumn("Телефоны", value: \ContactRow.phones).width(min: 100, ideal: 150).customizationID("phones")
        TableColumn("Email", value: \ContactRow.emails).width(min: 100, ideal: 170).customizationID("emails")
    }

    @TableColumnBuilder<ContactRow, Col>
    var dataColumns: some TableColumnContent<ContactRow, Col> {
        TableColumn("Адрес", value: \ContactRow.address).width(min: 80, ideal: 150).customizationID("address")
        TableColumn("ДР", value: \ContactRow.birthday).width(min: 60, ideal: 80).customizationID("birthday")
        TableColumn("Заметка", value: \ContactRow.note).width(min: 60, ideal: 120).customizationID("note")
        TableColumn("Прочее", value: \ContactRow.extra).width(min: 60, ideal: 120).customizationID("extra")
        TableColumn("Telegram", value: \ContactRow.telegram) { (r: ContactRow) in
            TelegramCell(status: r.telegramStatus)
        }.width(min: 90, ideal: 130).customizationID("telegram")
        TableColumn("Аккаунт", value: \ContactRow.account).width(min: 60, ideal: 80).customizationID("account")
    }
}

/// Строка таблицы: все значения уже склеены в строки, чтобы по ним можно было сортировать.
struct ContactRow: Identifiable {
    let id: String
    let thumbnail: Data?
    let displayName: String
    let hasName: Bool
    let givenName, familyName, organization, phones, emails, address, birthday, note, extra, account: String
    let telegram: String
    let telegramStatus: TGStatus

    init(_ c: AppContact, telegram status: TGStatus = .none) {
        telegramStatus = status
        switch status {
        case .linked(let id, let username, _, _): telegram = "1 " + (username.map { "@\($0)" } ?? String(id))
        case .suggested(let u): telegram = "2 " + u.name
        case .none: telegram = "3"
        }
        let r = c.record
        id = c.id
        thumbnail = c.thumbnail
        displayName = r.displayName
        hasName = Field.name.count(r) > 0
        givenName = [r.namePrefix, r.givenName, r.middleName].filter { !$0.isEmpty }.joined(separator: " ")
        familyName = [r.familyName, r.nameSuffix].filter { !$0.isEmpty }.joined(separator: " ")
        organization = [r.organizationName, r.jobTitle].filter { !$0.isEmpty }.joined(separator: " · ")
        phones = r.phoneNumbers.map(\.value).joined(separator: ", ")
        emails = r.emailAddresses.map(\.value).joined(separator: ", ")
        address = r.postalAddresses.map { [$0.city, $0.street].filter { !$0.isEmpty }.joined(separator: ", ") }
            .joined(separator: "; ")
        if let b = r.birthday {
            birthday = [b.day, b.month, b.year].compactMap { $0 }.map { String(format: "%02d", $0) }.joined(separator: ".")
        } else { birthday = "" }
        note = (r.note ?? "").replacingOccurrences(of: "\n", with: " ")
        var extra: [String] = []
        if !r.nickname.isEmpty { extra.append("псевдоним") }
        if !r.urlAddresses.isEmpty { extra.append("сайты \(r.urlAddresses.count)") }
        if !r.socialProfiles.isEmpty { extra.append("соц \(r.socialProfiles.count)") }
        if !r.instantMessageAddresses.isEmpty { extra.append("IM \(r.instantMessageAddresses.count)") }
        if !r.relations.isEmpty { extra.append("связи \(r.relations.count)") }
        if !r.dates.isEmpty { extra.append("даты \(r.dates.count)") }
        self.extra = extra.joined(separator: ", ")
        account = r.containerId == "_local:ABAccount" ? "Mac" : "iCloud"
    }
}

struct Avatar: View {
    let data: Data?
    let size: CGFloat

    var body: some View {
        if let data, let img = NSImage(data: data) {
            Image(nsImage: img).resizable().scaledToFill()
                .frame(width: size, height: size).clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill").resizable()
                .foregroundStyle(.tertiary).frame(width: size, height: size)
        }
    }
}

struct ContactDetail: View {
    @EnvironmentObject var model: AppModel
    let contact: AppContact
    @State private var showPhoto = false

    var body: some View {
        let r = contact.record
        // Form(.grouped), а не ScrollView: на macOS 27 кнопки в ScrollView — корне .inspector — не нажимаются
        // (см. repro/InspectorScrollButton).
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    Avatar(data: contact.image ?? contact.thumbnail, size: 96)
                        .opensPhoto((contact.image ?? contact.thumbnail).flatMap(NSImage.init(data:)),
                                    title: r.displayName, isPresented: $showPhoto)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(r.displayName).font(.title2.bold()).textSelection(.enabled)
                        HStack {
                            Button("Изменить") { model.startEditing(contact.id) }
                            Button("Удалить…", role: .destructive) { model.confirmDelete([contact.id]) }
                        }
                        .controlSize(.small)
                        if !r.organizationName.isEmpty || !r.jobTitle.isEmpty {
                            Text([r.jobTitle, r.departmentName, r.organizationName].filter { !$0.isEmpty }.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                        }
                        Text("Аккаунт: \(model.containerName(r.containerId))").font(.caption).foregroundStyle(.secondary)
                        if !r.groupIds.isEmpty {
                            Text("Группы: " + r.groupIds.map(model.groupName).joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

                FieldSection(title: "Имя", rows: [
                    ("Префикс", r.namePrefix), ("Имя", r.givenName), ("Отчество", r.middleName),
                    ("Фамилия", r.familyName), ("Девичья фамилия", r.previousFamilyName),
                    ("Суффикс", r.nameSuffix), ("Псевдоним", r.nickname),
                    ("Фонет. имя", r.phoneticGivenName), ("Фонет. отчество", r.phoneticMiddleName),
                    ("Фонет. фамилия", r.phoneticFamilyName), ("Фонет. организация", r.phoneticOrganizationName),
                ])
                FieldSection(title: "Работа", rows: [
                    ("Организация", r.organizationName), ("Отдел", r.departmentName), ("Должность", r.jobTitle),
                ])
                FieldSection(title: "Телефоны", rows: r.phoneNumbers.map { (label($0), $0.value) })
                FieldSection(title: "Email", rows: r.emailAddresses.map { (label($0), $0.value) })
                FieldSection(title: "Адреса", rows: r.postalAddresses.map { a in
                    (a.labelLocalized ?? a.label ?? "",
                     [a.street, a.subLocality, a.city, a.subAdministrativeArea, a.state, a.postalCode, a.country]
                        .filter { !$0.isEmpty }.joined(separator: ", "))
                })
                FieldSection(title: "Сайты", rows: r.urlAddresses.map { (label($0), $0.value) })
                FieldSection(title: "Даты", rows:
                    [("День рождения", format(r.birthday)), ("ДР (др. календарь)", format(r.nonGregorianBirthday))]
                    + r.dates.map { ($0.labelLocalized ?? $0.label ?? "", format($0)) })
                FieldSection(title: "Связи", rows: r.relations.map { (label($0), $0.value) })
                FieldSection(title: "Соцпрофили", rows: r.socialProfiles.map { s in
                    (s.service.isEmpty ? (s.label ?? "") : s.service,
                     [s.username, s.urlString].filter { !$0.isEmpty }.joined(separator: " · "))
                })
                TelegramCardSection(contact: contact)
                FieldSection(title: "Мессенджеры", rows: r.instantMessageAddresses.map { ($0.service, $0.username) })
                FieldSection(title: "Заметка", rows: [("", r.note ?? "")])

            Section {
                Text("ID: \(r.identifier)").font(.caption2).foregroundStyle(.tertiary).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    private func label(_ l: ContactRecord.Labeled) -> String {
        l.labelLocalized ?? l.label ?? ""
    }

    private func format(_ d: ContactRecord.DateValue?) -> String {
        guard let d else { return "" }
        let parts = [d.day.map { String(format: "%02d", $0) }, d.month.map { String(format: "%02d", $0) }, d.year.map(String.init)]
        let s = parts.compactMap { $0 }.joined(separator: ".")
        if let cal = d.calendar, cal != "gregorian" { return "\(s) (\(cal))" }
        return s
    }
}

/// Секция формы: показывает только непустые строки, пустая секция не рисуется.
struct FieldSection: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        let filled = rows.filter { !$0.1.isEmpty }
        if !filled.isEmpty {
            Section(title) {
                ForEach(Array(filled.enumerated()), id: \.offset) { _, row in
                    if row.0.isEmpty {
                        Text(row.1).textSelection(.enabled)
                    } else {
                        LabeledContent(row.0) {
                            Text(row.1).textSelection(.enabled).multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        }
    }
}

/// Ячейка «Telegram» в таблице контактов Apple.
struct TelegramCell: View {
    let status: TGStatus
    var body: some View {
        switch status {
        case .linked(let id, let username, let user, let outdated):
            HStack(spacing: 4) {
                Image(systemName: "link").foregroundStyle(user == nil ? Color.secondary : Color.accentColor)
                Text(username.map { "@\($0)" } ?? String(id))
                if outdated { Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange).help("Ник в Telegram изменился") }
            }
        case .suggested(let u):
            Text("найден: \(u.name)").foregroundStyle(.orange)
        case .none:
            Text("")
        }
    }
}

/// Блок «Telegram» в карточке контакта Apple.
struct TelegramCardSection: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var tg: TelegramService
    let contact: AppContact
    @State private var picking = false
    @State private var importFrom: TGUser?

    var body: some View {
        let status = model.matcher.status(contact.record)
        let fixReason = TelegramLink.fixReason(contact.record)
        Section("Telegram") {
            if let fixReason {
                LabeledContent(fixReason) {
                    Button("Исправить") { Task { await model.fixTelegramLinks([contact.id]) } }
                }
            }
            switch status {
            case .linked(let id, let username, let user, let outdated):
                HStack {
                    TGAvatar(path: user?.photoPath, size: 22)
                    Text(user?.name ?? "")
                    Text(username.map { "@\($0)" } ?? "").foregroundStyle(.secondary)
                    Text("ID \(id)").monospacedDigit().foregroundStyle(.secondary).textSelection(.enabled)
                }
                if user == nil && tg.auth == .ready {
                    Text("Этого пользователя нет в ваших контактах Telegram.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if let user {
                        Button("Перенести из Telegram…") { importFrom = user }
                    }
                    if let user, outdated {
                        Button("Обновить ник") { Task { await model.setTelegramLinks([(contact.id, user)]) } }
                    }
                    Button("Открыть в Telegram") {
                        NSWorkspace.shared.open(URL(string: username.map { "https://t.me/\($0)" } ?? "tg://user?id=\(id)")!)
                    }
                    Button("Отвязать", role: .destructive) { Task { await model.setTelegramLinks([(contact.id, nil)]) } }
                }.controlSize(.small)
            case .suggested(let u):
                HStack {
                    TGAvatar(path: u.photoPath, size: 22)
                    Text("Найден по телефону: \(u.name)")
                    if let un = u.username { Text("@\(un)").foregroundStyle(.secondary) }
                }
                HStack {
                    Button("Связать") { Task { await model.setTelegramLinks([(contact.id, u)]) } }
                    Button("Другой…") { picking = true }.disabled(tg.auth != .ready)
                }.controlSize(.small)
            case .none:
                if tg.auth == .ready {
                    Button("Связать с Telegram…") { picking = true }.controlSize(.small)
                } else {
                    Text("Не связан. Войдите в Telegram в разделе «Telegram».").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $picking) {
            TelegramUserPicker(title: "Связать «\(contact.record.displayName)» с Telegram") { u in
                Task { await model.setTelegramLinks([(contact.id, u)]) }
            }
        }
        .sheet(item: $importFrom) { u in
            TelegramImportSheet(contactId: contact.id, user: u)
        }
    }
}

/// Окно с фото в полном размере (открывается по клику на аватар).
struct PhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let image: NSImage
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: min(image.size.width, 800), maxHeight: min(image.size.height, 800))
                .padding([.horizontal, .bottom], 10)
                .onTapGesture { dismiss() }
        }
        .frame(minWidth: 320, minHeight: 320)
    }
}

extension View {
    /// Клик по аватару открывает фото в полном размере (если оно есть).
    func opensPhoto(_ image: NSImage?, title: String, isPresented: Binding<Bool>) -> some View {
        self
            .onTapGesture { if image != nil { isPresented.wrappedValue = true } }
            .help(image != nil ? "Открыть фото" : "")
            .sheet(isPresented: isPresented) {
                if let image { PhotoViewer(image: image, title: title) }
            }
    }
}

struct MergeRequest: Identifiable {
    let ids: [String]
    var id: String { ids.joined(separator: ",") }
}

/// Пункты контекстного меню таблицы контактов Apple.
struct ContactMenuItems: View {
    @EnvironmentObject var model: AppModel
    let ids: Set<String>

    var body: some View {
        if ids.count == 1, let id = ids.first {
            Button("Изменить") { model.startEditing(id) }
        }
        if ids.count > 1 {
            Button("Объединить (\(ids.count))…") { model.mergeIds = Array(ids) }
        }
        let cyr = cyrillicIds
        if !cyr.isEmpty {
            Button("Латиницей (\(cyr.count))…") { model.pendingTranslit = cyr }
        }
        Button(ids.count > 1 ? "Удалить (\(ids.count))…" : "Удалить…", role: .destructive) {
            model.confirmDelete(ids)
        }
    }

    private var cyrillicIds: [String] {
        ids.filter { id in model.contact(id).map { model.hasCyrillicName($0.record) } ?? false }
    }
}
