import Contacts
import SwiftUI

/// Окно объединения нескольких контактов Apple в один.
struct MergeSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let ids: [String]

    @State private var primaryId = ""
    @State private var scalars: [MergeScalar: String] = [:]
    @State private var birthdayIndex = 0
    @State private var imageFrom: String?
    @State private var keep = Set<String>()
    @State private var note = ""
    @State private var saving = false

    private var contacts: [CNContact] { ids.compactMap { model.cnContact($0) } }
    private var primary: CNContact? { model.cnContact(primaryId) }
    private var others: [CNContact] { contacts.filter { $0.identifier != primaryId } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Text("Объединение (\(ids.count))").font(.headline)
                Spacer()
                Button("Объединить") {
                    guard let primary else { return }
                    saving = true
                    let birthdays = ContactMerge.birthdayVariants(primary: primary, others: others)
                    Task {
                        let ok = await model.merge(
                            primaryId: primaryId, otherIds: others.map(\.identifier), scalars: scalars,
                            birthday: birthdays.indices.contains(birthdayIndex) ? birthdays[birthdayIndex] : nil,
                            imageFrom: imageFrom, keep: keep, note: note)
                        saving = false
                        if ok { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(primary == nil || saving)
            }
            .padding()
            Divider()
            if let primary {
                form(primary)
            }
        }
        .frame(width: 580, height: 680)
        .onAppear {
            // основным по умолчанию — контакт без заметки (его можно сохранить через Contacts.framework)
            primaryId = ids.first { !model.hasNote($0) } ?? ids[0]
            resetChoices()
        }
    }

    @ViewBuilder
    private func form(_ primary: CNContact) -> some View {
        let items = ContactMerge.items(primary: primary, others: others)
        let birthdays = ContactMerge.birthdayVariants(primary: primary, others: others)
        let withPhoto = contacts.filter { $0.imageData != nil }
        Form {
            Section {
                Picker("Основной контакт", selection: $primaryId) {
                    ForEach(contacts, id: \.identifier) { c in
                        Text(describe(c)).tag(c.identifier)
                    }
                }
                .onChange(of: primaryId) { resetChoices() }
            } footer: {
                Text("Основной контакт остаётся (с его идентификатором в iCloud), остальные удаляются. Копии всех сохранятся в истории.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Поля") {
                ForEach(MergeScalar.allCases) { f in
                    let variants = ContactMerge.variants(f, primary: primary, others: others)
                    if variants.count > 1 {
                        Picker(f.title, selection: Binding(get: { scalars[f] ?? "" }, set: { scalars[f] = $0 })) {
                            ForEach(variants, id: \.self) { Text($0).tag($0) }
                            Text("— пусто —").tag("")
                        }
                    } else if let v = variants.first {
                        LabeledContent(f.title, value: v)
                    }
                }
                if birthdays.count > 1 {
                    Picker("День рождения", selection: $birthdayIndex) {
                        ForEach(birthdays.indices, id: \.self) { i in Text(format(birthdays[i])).tag(i) }
                        Text("— пусто —").tag(-1)
                    }
                } else if let b = birthdays.first {
                    LabeledContent("День рождения", value: format(b))
                }
                if withPhoto.count > 1 {
                    Picker("Фото", selection: Binding(get: { imageFrom ?? "" }, set: { imageFrom = $0.isEmpty ? nil : $0 })) {
                        ForEach(withPhoto, id: \.identifier) { c in Text("из «\(describe(c))»").tag(c.identifier) }
                        Text("без фото").tag("")
                    }
                }
            }

            ForEach(MergeKind.allCases, id: \.self) { kind in
                let list = items.filter { $0.kind == kind }
                if !list.isEmpty {
                    Section(kind.title) {
                        ForEach(list) { item in
                            Toggle(isOn: Binding(get: { keep.contains(item.id) },
                                                 set: { if $0 { keep.insert(item.id) } else { keep.remove(item.id) } })) {
                                HStack {
                                    Text(item.text).textSelection(.enabled)
                                    Spacer()
                                    Text(item.label).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            Section("Заметка") {
                TextEditor(text: $note).frame(minHeight: 60)
            }
        }
        .formStyle(.grouped)
    }

    private func resetChoices() {
        guard let primary else { return }
        for f in MergeScalar.allCases { scalars[f] = ContactMerge.defaultChoice(f, primary: primary, others: others) }
        birthdayIndex = 0
        imageFrom = ([primary] + others).first { $0.imageData != nil }?.identifier
        keep = Set(ContactMerge.items(primary: primary, others: others).map(\.id))
        note = ContactMerge.mergedNote(([primaryId] + others.map(\.identifier)).map { model.contact($0)?.record.note })
    }

    private func describe(_ c: CNContact) -> String {
        let r = model.contact(c.identifier)?.record
        let name = r?.displayName ?? c.identifier
        let extra = [r?.phoneNumbers.first?.value, r?.emailAddresses.first?.value].compactMap { $0 }.first ?? ""
        return extra.isEmpty ? name : "\(name) — \(extra)"
    }

    private func format(_ d: DateComponents) -> String {
        [d.day, d.month, d.year].compactMap { $0 }.map { String(format: "%02d", $0) }.joined(separator: ".")
    }
}
