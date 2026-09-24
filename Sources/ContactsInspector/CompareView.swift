import Contacts
import SwiftUI

/// Строка сравнения: пара контактов из двух аккаунтов или контакт только с одной стороны.
struct CompareRow: Identifiable {
    let a: String?
    let b: String?
    let aName: String
    let bName: String
    let diff: [String]
    var id: String { (a ?? "-") + "|" + (b ?? "-") }
    var diffText: String { diff.joined(separator: ", ") }
}

/// Раздел «Сравнение аккаунтов»: разница между двумя аккаунтами и ручной перенос в выбранную сторону.
struct CompareView: View {
    @EnvironmentObject var model: AppModel

    enum Mode: String, CaseIterable { case differ = "Отличаются", onlyA = "Только в A", onlyB = "Только в B", same = "Совпадают" }
    enum Direction { case aToB, bToA }
    enum Side { case a, b }

    @AppStorage("compareA") private var accountA = ""
    @AppStorage("compareB") private var accountB = ""
    @State private var mode = Mode.differ
    @State private var selection = Set<String>()
    @State private var pending: Direction?
    @State private var pendingDelete: Side?
    @State private var sortOrder = [KeyPathComparator(\CompareRow.aName)]

    var body: some View {
        let all = rows()
        let visible = all[mode, default: []].sorted(using: sortOrder)
        VStack(spacing: 0) {
            header(all)
            Divider()
            Table(visible, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("A: \(name(accountA))", value: \CompareRow.aName) { r in
                    Text(r.aName.isEmpty ? "—" : r.aName).foregroundStyle(r.a == nil ? .tertiary : .primary)
                }
                TableColumn("B: \(name(accountB))", value: \CompareRow.bName) { r in
                    Text(r.bName.isEmpty ? "—" : r.bName).foregroundStyle(r.b == nil ? .tertiary : .primary)
                }
                TableColumn("Отличается", value: \CompareRow.diffText) { r in
                    Text(r.diffText).foregroundStyle(.orange)
                }
            }
            .onChange(of: mode) { selection = [] }
            .inspector(isPresented: .constant(true)) {
                Group {
                    if selection.count == 1, let r = visible.first(where: { $0.id == selection.first }) {
                        CompareDetail(row: r, nameA: name(accountA), nameB: name(accountB))
                    } else {
                        Text(selection.isEmpty ? "Выберите строку" : "Выбрано: \(selection.count)").foregroundStyle(.secondary)
                    }
                }
                .inspectorColumnWidth(min: 300, ideal: 380, max: 600)
            }
        }
        .navigationTitle("Сравнение аккаунтов")
        .onAppear(perform: defaultAccounts)
        .alert(deleteTitle(visible), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Удалить", role: .destructive) {
                if let side = pendingDelete {
                    let ids = deleteIds(side, rows: visible)
                    Task { await model.delete(Set(ids)); selection = [] }
                }
                pendingDelete = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Отмена", role: .cancel) { pendingDelete = nil }
        } message: {
            Text(deleteMessage(visible))
        }
        .alert(alertTitle(visible), isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Перенести") {
                if let d = pending { Task { await apply(d, rows: visible) } }
                pending = nil
            }
            .keyboardShortcut(.defaultAction)
            Button("Отмена", role: .cancel) { pending = nil }
        } message: {
            Text(alertMessage(visible))
        }
    }

    // MARK: - Шапка

    private func header(_ all: [Mode: [CompareRow]]) -> some View {
        let containers = model.containers
        return VStack(spacing: 8) {
            HStack {
                Picker("A", selection: $accountA) {
                    ForEach(containers, id: \.identifier) { Text(model.displayName($0)).tag($0.identifier) }
                }
                .fixedSize()
                Button { swap(&accountA, &accountB); selection = [] } label: { Image(systemName: "arrow.left.arrow.right") }
                    .help("Поменять местами")
                Picker("B", selection: $accountB) {
                    ForEach(containers, id: \.identifier) { Text(model.displayName($0)).tag($0.identifier) }
                }
                .fixedSize()
                Spacer()
                Button("A → B (\(count(.aToB, rows: all[mode, default: []])))") { pending = .aToB }
                    .disabled(count(.aToB, rows: all[mode, default: []]) == 0)
                    .help("Сделать B таким же, как A: перезаписать пары, скопировать недостающие")
                Button("B → A (\(count(.bToA, rows: all[mode, default: []])))") { pending = .bToA }
                    .disabled(count(.bToA, rows: all[mode, default: []]) == 0)
                    .help("Сделать A таким же, как B")
                Button("Фото A → B (\(photoPairs(all[mode, default: []]).count))") {
                    let pairs = photoPairs(all[mode, default: []])
                    Task {
                        let r = await model.pushPhotos(pairs)
                        model.resultMessage = "Фото загружено: \(r.done)" + (r.failed.isEmpty ? "" :
                            "\nНе удалось (\(r.failed.count)):\n" + r.failed.prefix(15).joined(separator: "\n"))
                    }
                }
                .disabled(photoPairs(all[mode, default: []]).isEmpty)
                .help("Заново загрузить фото из A в B — для пар, где в A есть фото")
                Divider().frame(height: 16)
                Button("Удалить в A (\(deleteIds(.a, rows: all[mode, default: []]).count))", role: .destructive) { pendingDelete = .a }
                    .disabled(deleteIds(.a, rows: all[mode, default: []]).isEmpty)
                Button("Удалить в B (\(deleteIds(.b, rows: all[mode, default: []]).count))", role: .destructive) { pendingDelete = .b }
                    .disabled(deleteIds(.b, rows: all[mode, default: []]).isEmpty)
            }
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { m in Text("\(m.rawValue) (\(all[m, default: []].count))").tag(m) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if model.loadingPhotos {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Загружаю фото — пока они не загружены, фото не сравниваются").font(.callout).foregroundStyle(.secondary)
                }
            }
            if containers.count < 2 {
                Text("Подключён только один аккаунт. Добавьте Google в «Системных настройках» → «Интернет-аккаунты» → Google → «Контакты».")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(10)
    }

    // MARK: - Данные

    private func rows() -> [Mode: [CompareRow]] {
        guard !accountA.isEmpty, !accountB.isEmpty, accountA != accountB else { return [:] }
        let a = model.records(in: accountA), b = model.records(in: accountB)
        let byId = Dictionary((a + b).map { ($0.identifier, $0) }, uniquingKeysWith: { x, _ in x })
        let match = AccountCompare.match(a, b)
        var out: [Mode: [CompareRow]] = [:]
        for p in match.pairs {
            guard let ra = byId[p.a], let rb = byId[p.b] else { continue }
            var diff = AccountCompare.differences(ra, rb)
            // пока фото читаются через Contacts.app, их не сравниваем — иначе ложные расхождения
            if !model.loadingPhotos, !model.photoHiddenOnMac(p.a), !model.photoHiddenOnMac(p.b),
               AccountCompare.photosDiffer(model.photoHash(p.a), model.photoHash(p.b)) {
                diff.append("Фото")
            }
            out[diff.isEmpty ? .same : .differ, default: []]
                .append(CompareRow(a: p.a, b: p.b, aName: ra.displayName, bName: rb.displayName, diff: diff))
        }
        out[.onlyA] = match.onlyA.compactMap { byId[$0] }.map { CompareRow(a: $0.identifier, b: nil, aName: $0.displayName, bName: "", diff: []) }
        out[.onlyB] = match.onlyB.compactMap { byId[$0] }.map { CompareRow(a: nil, b: $0.identifier, aName: "", bName: $0.displayName, diff: []) }
        return out
    }

    /// Строки, к которым применяется действие: выделенные, а если ничего не выделено — все видимые.
    private func targets(_ rows: [CompareRow]) -> [CompareRow] {
        selection.isEmpty ? rows : rows.filter { selection.contains($0.id) }
    }

    private func count(_ d: Direction, rows: [CompareRow]) -> Int {
        targets(rows).filter { r in
            switch d {
            case .aToB: r.a != nil && (r.b == nil || !r.diff.isEmpty)
            case .bToA: r.b != nil && (r.a == nil || !r.diff.isEmpty)
            }
        }.count
    }

    private func apply(_ d: Direction, rows: [CompareRow]) async {
        let list = targets(rows)
        let target = d == .aToB ? accountB : accountA
        let pairs = list.compactMap { r -> (target: String, source: String)? in
            guard let a = r.a, let b = r.b, !r.diff.isEmpty else { return nil }
            return d == .aToB ? (b, a) : (a, b)
        }
        let copies = list.compactMap { r -> String? in
            d == .aToB ? (r.b == nil ? r.a : nil) : (r.a == nil ? r.b : nil)
        }
        var done = 0
        var failed: [String] = []
        if !pairs.isEmpty { let r = await model.overwrite(pairs); done += r.done; failed += r.failed }
        if !copies.isEmpty { let r = await model.copyContacts(copies, to: target); done += r.done; failed += r.failed }
        selection = []
        debugLog("compare apply \(d == .aToB ? "A→B" : "B→A"): \(done), failed \(failed.count)")
        model.backupMessage = nil
        model.resultMessage = "Перенесено: \(done)" + (failed.isEmpty ? "" :
            "\nНе удалось (\(failed.count)):\n" + failed.prefix(15).joined(separator: "\n")
            + (failed.count > 15 ? "\n… и ещё \(failed.count - 15)" : ""))
    }

    /// Пары (получатель B, источник A) у строк, к которым применяется действие, где в A есть фото.
    private func photoPairs(_ rows: [CompareRow]) -> [(target: String, source: String)] {
        targets(rows).compactMap { r in
            guard let a = r.a, let b = r.b, model.contact(a)?.record.hasImage == true else { return nil }
            return (b, a)
        }
    }

    /// Контакты стороны A или B у строк, к которым применяется действие.
    private func deleteIds(_ side: Side, rows: [CompareRow]) -> [String] {
        targets(rows).compactMap { side == .a ? $0.a : $0.b }
    }

    private func deleteTitle(_ rows: [CompareRow]) -> String {
        guard let side = pendingDelete else { return "" }
        return "Удалить в «\(name(side == .a ? accountA : accountB))» (\(deleteIds(side, rows: rows).count))?"
    }

    private func deleteMessage(_ rows: [CompareRow]) -> String {
        guard let side = pendingDelete else { return "" }
        let names = deleteIds(side, rows: rows).compactMap { model.contact($0)?.record.displayName }.sorted()
        return names.prefix(12).joined(separator: "\n") + (names.count > 12 ? "\n… и ещё \(names.count - 12)" : "")
            + "\n\nКонтакты удалятся из этого аккаунта (и со всех устройств, где он подключён). Копии сохранятся в истории."
    }

    private func alertTitle(_ rows: [CompareRow]) -> String {
        guard let d = pending else { return "" }
        let (from, to) = d == .aToB ? (name(accountA), name(accountB)) : (name(accountB), name(accountA))
        return "Перенести \(from) → \(to) (\(count(d, rows: rows)))?"
    }

    private func alertMessage(_ rows: [CompareRow]) -> String {
        guard let d = pending else { return "" }
        let list = targets(rows).filter { d == .aToB ? $0.a != nil : $0.b != nil }
        let overwrite = list.filter { $0.a != nil && $0.b != nil && !$0.diff.isEmpty }.count
        let create = list.filter { d == .aToB ? $0.b == nil : $0.a == nil }.count
        let to = d == .aToB ? name(accountB) : name(accountA)
        var parts: [String] = []
        if overwrite > 0 { parts.append("перезаписать в «\(to)»: \(overwrite)") }
        if create > 0 { parts.append("создать в «\(to)»: \(create)") }
        return parts.joined(separator: "\n") + "\n\nПерезаписываемые контакты сохранятся в истории. Удаления не выполняются."
    }

    private func name(_ id: String) -> String {
        model.containers.first { $0.identifier == id }.map { model.displayName($0) } ?? "—"
    }

    private func defaultAccounts() {
        let ids = model.containers.map(\.identifier)
        if !ids.contains(accountA) { accountA = ids.first ?? "" }
        if !ids.contains(accountB) || accountB == accountA { accountB = ids.first { $0 != accountA } ?? "" }
    }
}

/// Сравнение пары поле за полем; значения многозначных полей — по одному, с удалением на любой стороне.
private struct CompareDetail: View {
    @EnvironmentObject var model: AppModel
    let row: CompareRow
    let nameA: String
    let nameB: String

    private static let listTitles: Set<String> = ["Телефоны", "Email", "Сайты", "Адреса", "Соцпрофили"]

    var body: some View {
        let fa = row.a.flatMap { model.contact($0)?.record }.map(AccountCompare.fields) ?? []
        let fb = row.b.flatMap { model.contact($0)?.record }.map(AccountCompare.fields) ?? []
        let titles = (fa.isEmpty ? fb : fa).map(\.title).filter { !Self.listTitles.contains($0) }
        let ca = row.a.flatMap { model.cnContact($0) }
        let cb = row.b.flatMap { model.cnContact($0) }
        Form {
            PhotoSection(a: row.a, b: row.b, nameA: nameA, nameB: nameB)
            ForEach(titles, id: \.self) { title in
                let a = fa.first { $0.title == title }
                let b = fb.first { $0.title == title }
                if !(a?.display ?? "").isEmpty || !(b?.display ?? "").isEmpty {
                    Section {
                        LabeledContent(nameA) { Text(a?.display ?? "—").textSelection(.enabled).multilineTextAlignment(.trailing) }
                        LabeledContent(nameB) { Text(b?.display ?? "—").textSelection(.enabled).multilineTextAlignment(.trailing) }
                    } header: {
                        HStack {
                            Text(title)
                            if a?.key != b?.key { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                        }
                    }
                }
            }
            ForEach(MergeKind.allCases, id: \.self) { kind in
                ValuesSection(kind: kind, a: ca, b: cb)
            }
        }
        .formStyle(.grouped)
    }
}

/// Фото обеих сторон рядом и совпадают ли они.
private struct PhotoSection: View {
    @EnvironmentObject var model: AppModel
    let a: String?
    let b: String?
    let nameA: String
    let nameB: String

    var body: some View {
        let ha = a.flatMap { model.photoHash($0) }
        let hb = b.flatMap { model.photoHash($0) }
        let hidden = (a.map(model.photoHiddenOnMac) ?? false) || (b.map(model.photoHiddenOnMac) ?? false)
        if ha != nil || hb != nil || a.flatMap({ model.photo($0) }) != nil || b.flatMap({ model.photo($0) }) != nil {
            Section {
                HStack(alignment: .top, spacing: 24) {
                    side(a, title: nameA, hash: ha)
                    side(b, title: nameB, hash: hb)
                    Spacer()
                }
            } header: {
                HStack {
                    Text("Фото")
                    if !hidden, AccountCompare.photosDiffer(ha, hb) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(ha == nil || hb == nil ? "есть только с одной стороны" : "разные изображения")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func side(_ id: String?, title: String, hash: UInt64?) -> some View {
        VStack(spacing: 4) {
            let data = id.flatMap { model.photo($0) }
            if hash != nil, let data, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                let hiddenHere = id.map(model.photoHiddenOnMac) ?? false
                RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 72, height: 72)
                    .overlay(Text(hiddenHere ? "с Mac\nне видно" : (data == nil ? "нет" : "битое"))
                        .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary))
                    .help(hiddenHere ? "Mac не получает фото из Google — проверить можно на contacts.google.com" : "")
            }
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Значения одного многозначного поля обеих сторон: где есть (A / B) и кнопки удаления.
private struct ValuesSection: View {
    @EnvironmentObject var model: AppModel
    let kind: MergeKind
    let a: CNContact?
    let b: CNContact?

    var body: some View {
        let ia = a.map { ContactMerge.labeled($0).map(\.0).filter { $0.kind == kind } } ?? []
        let ib = b.map { ContactMerge.labeled($0).map(\.0).filter { $0.kind == kind } } ?? []
        let idsA = Set(ia.map(\.id)), idsB = Set(ib.map(\.id))
        let all = ia + ib.filter { !idsA.contains($0.id) }
        if !all.isEmpty {
            Section {
                ForEach(all) { item in
                    let inA = idsA.contains(item.id), inB = idsB.contains(item.id)
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text).textSelection(.enabled)
                                .foregroundStyle(inA && inB ? Color.primary : Color.orange)
                            Text([item.label, inA && inB ? "в A и B" : (inA ? "только в A" : "только в B")]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if inA, let a {
                            Button("− A") { Task { await model.removeValue(contactId: a.identifier, itemId: item.id) } }
                                .help("Удалить это значение в A")
                        }
                        if inB, let b {
                            Button("− B") { Task { await model.removeValue(contactId: b.identifier, itemId: item.id) } }
                                .help("Удалить это значение в B")
                        }
                    }
                    .controlSize(.small)
                }
            } header: {
                HStack {
                    Text(kind.title)
                    if idsA != idsB { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange) }
                }
            }
        }
    }
}
