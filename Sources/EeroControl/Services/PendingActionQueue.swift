import Foundation

actor PendingActionQueue {
    private let fileURL: URL
    private var items: [QueuedAction] = []

    init(fileName: String = "queued-actions.json") {
        fileURL = OfflineStateStore.appSupportDirectory().appendingPathComponent(fileName)
        items = Self.loadFromDisk(url: fileURL)
    }

    func all() -> [QueuedAction] {
        items.sorted { $0.queuedAt < $1.queuedAt }
    }

    func enqueue(_ action: EeroAction) {
        let item = QueuedAction(action: action, queuedAt: Date(), status: .pending, lastError: nil)
        items.removeAll { $0.id == item.id }
        items.append(item)
        persist()
    }

    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func clearReplayed() {
        items.removeAll { $0.status == .replayed }
        persist()
    }

    func mark(id: UUID, status: QueuedAction.ReplayStatus, error: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return
        }
        items[index].status = status
        items[index].lastError = error
        persist()
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(items)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure is non-fatal for queue behavior.
        }
    }

    private static func loadFromDisk(url: URL) -> [QueuedAction] {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([QueuedAction].self, from: data)
        } catch {
            return []
        }
    }
}
