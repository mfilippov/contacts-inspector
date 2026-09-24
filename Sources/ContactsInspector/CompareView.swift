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

    @AppStorage("compareA") private var accountA = ""
    @AppStorage("compareB") private var accountB = ""
    @State private var mode = Mode.differ
    @State private var selection = Set<String>()
    @State private var pending: Direction?
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
            }
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { m in Text("\(m.rawValue) (\(all[m, default: []].count))").tag(m) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
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
            let diff = AccountCompare.differences(ra, rb)
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
        if !pairs.isEmpty { done += await model.overwrite(pairs) }
        if !copies.isEmpty { done += await model.copyContacts(copies, to: target) }
        selection = []
        debugLog("compare apply \(d == .aToB ? "A→B" : "B→A"): \(done)")
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

/// Сравнение пары поле за полем.
private struct CompareDetail: View {
    @EnvironmentObject var model: AppModel
    let row: CompareRow
    let nameA: String
    let nameB: String

    var body: some View {
        let fa = row.a.flatMap { model.contact($0)?.record }.map(AccountCompare.fields) ?? []
        let fb = row.b.flatMap { model.contact($0)?.record }.map(AccountCompare.fields) ?? []
        let titles = (fa.isEmpty ? fb : fa).map(\.title)
        Form {
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
        }
        .formStyle(.grouped)
    }
}
