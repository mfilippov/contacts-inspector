import AppKit
import SwiftUI

struct BackupInfo: Identifiable {
    var id: String { url.path }
    let url: URL
    let date: Date?
    let contacts: Int
    let photos: Int
    let telegram: Int?
    let bytes: Int64

    var name: String { url.lastPathComponent }
    var dateText: String { date?.formatted(date: .abbreviated, time: .shortened) ?? name }
    var sizeText: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// Ищет в папке подпапки contacts-backup-* и собирает по ним сводку (новые сверху).
func scanBackups(in dir: URL) -> [BackupInfo] {
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd_HHmmss"
    return items
        .filter { $0.lastPathComponent.hasPrefix("contacts-backup-") && $0.hasDirectoryPath }
        .map { url in
            let stamp = url.lastPathComponent.replacingOccurrences(of: "contacts-backup-", with: "")
            let vcf = (try? String(contentsOf: url.appendingPathComponent("contacts.vcf"), encoding: .utf8)) ?? ""
            let contacts = vcf.components(separatedBy: "BEGIN:VCARD").count - 1
            let photos = ((try? fm.contentsOfDirectory(atPath: url.appendingPathComponent("photos").path)) ?? [])
                .filter { $0 != "thumb" && !$0.hasPrefix(".") }.count
            let tgData = try? Data(contentsOf: url.appendingPathComponent("telegram/contacts.json"))
            let telegram = tgData.flatMap { try? JSONDecoder().decode([TelegramBackupRecord].self, from: $0) }?.count
            var bytes: Int64 = 0
            if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let f as URL in e {
                    bytes += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
            return BackupInfo(url: url, date: fmt.date(from: stamp), contacts: max(contacts, 0),
                              photos: photos, telegram: telegram, bytes: bytes)
        }
        .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
}

struct BackupsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: BackupInfo.ID?
    @State private var toTrash: BackupInfo?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                Text(model.backupsDir.path(percentEncoded: false))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Button("Открыть") {
                    try? FileManager.default.createDirectory(at: model.backupsDir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(model.backupsDir)
                }
                Button("Сменить папку…") { model.chooseBackupsDir() }
                Spacer()
                Button {
                    model.backupNow()
                } label: {
                    Label("Сделать бэкап сейчас", systemImage: "externaldrive.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.backupInProgress)
            }
            .padding(10)
            Divider()
            if model.backups.isEmpty {
                ContentUnavailableView("Бэкапов пока нет", systemImage: "externaldrive",
                                       description: Text("Нажмите «Сделать бэкап сейчас»."))
            } else {
                Table(model.backups, selection: $selection) {
                    TableColumn("Дата") { (b: BackupInfo) in Text(b.dateText) }.width(min: 150, ideal: 180)
                    TableColumn("Контактов") { (b: BackupInfo) in Text("\(b.contacts)").monospacedDigit() }.width(80)
                    TableColumn("Фото") { (b: BackupInfo) in Text("\(b.photos)").monospacedDigit() }.width(60)
                    TableColumn("Telegram") { (b: BackupInfo) in
                        Text(b.telegram.map(String.init) ?? "—").monospacedDigit().foregroundStyle(b.telegram == nil ? .tertiary : .primary)
                    }.width(70)
                    TableColumn("Размер") { (b: BackupInfo) in Text(b.sizeText).monospacedDigit() }.width(80)
                    TableColumn("Папка") { (b: BackupInfo) in Text(b.name).foregroundStyle(.secondary) }
                }
                .contextMenu(forSelectionType: BackupInfo.ID.self) { ids in
                    if let b = model.backups.first(where: { ids.contains($0.id) }) {
                        Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([b.url]) }
                        Divider()
                        Button("Удалить в корзину…", role: .destructive) { toTrash = b }
                    }
                } primaryAction: { ids in
                    if let b = model.backups.first(where: { ids.contains($0.id) }) {
                        NSWorkspace.shared.activateFileViewerSelecting([b.url])
                    }
                }
            }
        }
        .navigationTitle("Бэкапы")
        .navigationSubtitle("\(model.backups.count) шт.")
        .task { await model.refreshBackups() }
        .confirmationDialog("Удалить бэкап \(toTrash?.dateText ?? "")?",
                            isPresented: Binding(get: { toTrash != nil }, set: { if !$0 { toTrash = nil } })) {
            Button("В корзину", role: .destructive) {
                if let b = toTrash { model.trashBackup(b) }
                toTrash = nil
            }
            Button("Отмена", role: .cancel) { toTrash = nil }
        }
    }
}
