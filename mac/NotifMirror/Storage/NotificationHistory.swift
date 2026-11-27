import Combine
import Foundation

/// Rolling history of incoming mirrored notifications.
/// Persisted to a JSON file under Application Support so it survives restarts.
@MainActor
final class NotificationHistory: ObservableObject {
    static let shared = NotificationHistory()

    private let cap: Int = 500
    private let url: URL

    @Published private(set) var entries: [Entry] = []

    struct Entry: Identifiable, Codable, Hashable {
        let id: UUID
        let key: String
        let pkg: String
        let app: String
        let title: String
        let body: String
        let receivedAt: Date
        let silent: Bool
        let attachmentPath: String?
        /// Actions advertised by Android at post time (reply boxes, "Mark as
        /// read", etc.). Persisted so the user can reply / fire actions from
        /// the Mac history even after the live banner has been dismissed.
        /// Optional for backward-compat with history JSON written before
        /// this field existed.
        let actions: [ActionDescriptor]?
        /// Source phone identity (optional for backward-compat with pre-2.0 history JSON).
        let deviceId: String?
        let deviceName: String?
    }

    private init() {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("NotifMirror", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("history.json")
        load()
    }

    func record(
        _ p: WireMessage.Posted,
        attachmentPath: String?,
        deviceId: String? = nil,
        deviceName: String? = nil
    ) {
        let entry = Entry(
            id: UUID(),
            key: p.key,
            pkg: p.pkg,
            app: p.app,
            title: p.title?.isEmpty == false ? p.title! : p.app,
            body: (p.text ?? p.subText) ?? "",
            receivedAt: Date(),
            silent: p.silent,
            attachmentPath: attachmentPath,
            actions: p.actions.isEmpty ? nil : p.actions,
            deviceId: deviceId,
            deviceName: deviceName
        )
        entries.insert(entry, at: 0)
        if entries.count > cap {
            let removed = entries.suffix(entries.count - cap)
            removed.forEach { e in
                if let path = e.attachmentPath {
                    try? FileManager.default.removeItem(atPath: path)
                }
            }
            entries.removeLast(entries.count - cap)
        }
        save()
    }

    func clear() {
        entries.forEach { e in
            if let path = e.attachmentPath {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        entries.removeAll()
        save()
    }

    func clear(pkg: String) {
        for e in entries where e.pkg == pkg {
            if let path = e.attachmentPath {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        entries.removeAll { $0.pkg == pkg }
        save()
    }

    func remove(_ entry: Entry, preserveAttachment: Bool = false) {
        if let idx = entries.firstIndex(of: entry) {
            if !preserveAttachment, let path = entries[idx].attachmentPath {
                try? FileManager.default.removeItem(atPath: path)
            }
            entries.remove(at: idx)
            save()
        }
    }

    func restore(_ entry: Entry) {
        guard !entries.contains(where: { $0.id == entry.id }) else { return }
        let idx = entries.firstIndex { $0.receivedAt < entry.receivedAt } ?? entries.endIndex
        entries.insert(entry, at: idx)
        save()
    }

    func deleteAttachment(at path: String?) {
        guard let path else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.iso.decode([Entry].self, from: data)
        else { return }
        entries = decoded
    }

    private func save() {
        if let data = try? JSONEncoder.iso.encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
