import Foundation

final class OfflineStateStore {
    private let fileURL: URL

    init(fileName: String = "cached-account-snapshot.json") {
        fileURL = Self.appSupportDirectory().appendingPathComponent(fileName)
    }

    func save(_ snapshot: EeroAccountSnapshot) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Intentionally ignore local cache write failures.
        }
    }

    func load() -> EeroAccountSnapshot? {
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(EeroAccountSnapshot.self, from: data)
        } catch {
            return nil
        }
    }

    static func appSupportDirectory() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("EeroControl", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
