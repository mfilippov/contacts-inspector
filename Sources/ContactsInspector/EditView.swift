import SwiftUI

struct EditContactView: View {
    @EnvironmentObject var model: AppModel
    let id: String
    let original: EditableContact
    @State private var edit: EditableContact
    @State private var saving = false

    private var birthdayError: String? {
        do { _ = try EditableContact.parseDate(edit.birthday); return nil } catch { return "\(error)" }
    }

    init(id: String, original: EditableContact) {
        self.id = id
        self.original = original
        _edit = State(initialValue: original)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Отмена") { model.editingId = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Редактирование").font(.headline)
                Spacer()
                Button("Сохранить") {
                    saving = true
                    Task { _ = await model.save(edit, id: id); saving = false }
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(edit == original || saving || birthdayError != nil)
            }
            .padding(10)
            Divider()
            Form {
                NameSection(edit: $edit)
                LabeledListSection(title: "Телефоны", kind: .phone, items: $edit.phones, addTitle: "Добавить телефон")
                LabeledListSection(title: "Email", kind: .email, items: $edit.emails, addTitle: "Добавить email")
                LabeledListSection(title: "Сайты", kind: .url, items: $edit.urls, addTitle: "Добавить сайт")
                AddressSection(items: $edit.addresses)
                Section("День рождения") {
                    TextField("Дата", text: $edit.birthday, prompt: Text("дд.мм.гггг или дд.мм"))
                    if let err = birthdayError {
                        Text(err).font(.caption).foregroundStyle(.red)
                    }
                }
                LabeledListSection(title: "Связи", kind: .relation, items: $edit.relations, addTitle: "Добавить связь")
                RemovableSection(title: "Соцпрофили", items: $edit.socials)
                RemovableSection(title: "Мессенджеры", items: $edit.ims)
                RemovableSection(title: "Другие даты", items: $edit.dates)
                Section("Заметка") {
                    TextEditor(text: $edit.note).frame(minHeight: 60).font(.body)
                }
                if edit.hasPhoto {
                    Section("Фото") {
                        Toggle("Удалить фото", isOn: $edit.removePhoto)
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct NameSection: View {
    @Binding var edit: EditableContact

    var body: some View {
        Section("Имя") {
            TextField("Префикс", text: $edit.namePrefix, prompt: Text("не указано"))
            TextField("Имя", text: $edit.givenName, prompt: Text("не указано"))
            TextField("Отчество", text: $edit.middleName, prompt: Text("не указано"))
            TextField("Фамилия", text: $edit.familyName, prompt: Text("не указано"))
            TextField("Девичья фамилия", text: $edit.previousFamilyName, prompt: Text("не указано"))
            TextField("Суффикс", text: $edit.nameSuffix, prompt: Text("не указано"))
            TextField("Псевдоним", text: $edit.nickname, prompt: Text("не указано"))
        }
        Section("Фонетическое имя") {
            TextField("Имя", text: $edit.phoneticGivenName, prompt: Text("не указано"))
            TextField("Отчество", text: $edit.phoneticMiddleName, prompt: Text("не указано"))
            TextField("Фамилия", text: $edit.phoneticFamilyName, prompt: Text("не указано"))
        }
        Section("Работа") {
            TextField("Организация", text: $edit.organizationName, prompt: Text("не указано"))
            TextField("Отдел", text: $edit.departmentName, prompt: Text("не указано"))
            TextField("Должность", text: $edit.jobTitle, prompt: Text("не указано"))
        }
    }
}

/// Выбор метки из стандартных вариантов.
private struct LabelMenu: View {
    let kind: LabelKind
    @Binding var label: String

    var body: some View {
        // текущая метка может быть нестандартной — добавляем её в список
        let options = [""] + kind.options + (label.isEmpty || kind.options.contains(label) ? [] : [label])
        Picker("", selection: $label) {
            ForEach(options, id: \.self) { Text(LabelKind.title($0)).tag($0) }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
    }
}

private struct LabeledListSection: View {
    let title: String
    let kind: LabelKind
    @Binding var items: [EditLabeled]
    let addTitle: String

    var body: some View {
        Section(title) {
            ForEach($items) { $item in
                HStack {
                    LabelMenu(kind: kind, label: $item.label)
                    TextField("", text: $item.value)
                    RemoveButton { items.removeAll { $0.id == item.id } }
                }
            }
            Button(addTitle) { items.append(EditLabeled(originalId: nil, label: kind.options[0], value: "")) }
                .buttonStyle(.link)
        }
    }
}

private struct AddressSection: View {
    @Binding var items: [EditAddress]

    var body: some View {
        Section("Адреса") {
            ForEach($items) { $a in
                VStack(alignment: .leading) {
                    HStack {
                        LabelMenu(kind: .address, label: $a.label)
                        Spacer()
                        RemoveButton { items.removeAll { $0.id == a.id } }
                    }
                    TextField("Улица", text: $a.street)
                    HStack {
                        TextField("Город", text: $a.city)
                        TextField("Индекс", text: $a.postalCode).frame(maxWidth: 90)
                    }
                    HStack {
                        TextField("Регион", text: $a.state)
                        TextField("Страна", text: $a.country)
                    }
                }
            }
            Button("Добавить адрес") { items.append(EditAddress(originalId: nil, label: LabelKind.address.options[0])) }
                .buttonStyle(.link)
        }
    }
}

private struct RemovableSection: View {
    let title: String
    @Binding var items: [EditRemovable]

    var body: some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    HStack {
                        Text(item.text).textSelection(.enabled)
                        Spacer()
                        RemoveButton { items.removeAll { $0.id == item.id } }
                    }
                }
            }
        }
    }
}

private struct RemoveButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .help("Удалить")
    }
}
