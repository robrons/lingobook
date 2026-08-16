import Foundation
import SwiftData

/// Builds the app's SwiftData container.
///
/// If the store cannot be opened — a failed migration, a corrupt file — the existing
/// store is moved aside as a timestamped backup rather than deleted, so a schema change
/// can never silently destroy someone's library. The backup path is logged.
enum ModelContainerFactory {

    @MainActor
    static func makeContainer() -> ModelContainer {
        let schema = Schema([Book.self, ChapterSummary.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            print("LingoBook: could not open the library store: \(error)")

            if let backupPath = backUpStore(at: configuration.url) {
                print("LingoBook: previous library preserved at \(backupPath)")
            }

            do {
                return try ModelContainer(for: schema, configurations: [configuration])
            } catch {
                fatalError("Could not create ModelContainer after backing up the old store: \(error)")
            }
        }
    }

    /// Moves the store aside, returning the backup path of the main store file.
    ///
    /// SQLite keeps the database in three files — `default.store` plus the `-shm` and `-wal`
    /// journals. All three must move together; leaving orphaned journals behind would confuse
    /// the fresh store we create next.
    private static func backUpStore(at url: URL) -> String? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let suffix = "backup-" + formatter.string(from: Date())

        var mainBackupPath: String?

        for journalSuffix in ["", "-shm", "-wal"] {
            let source = URL(fileURLWithPath: url.path + journalSuffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }

            let destination = URL(fileURLWithPath: source.path + "." + suffix)
            do {
                try fileManager.moveItem(at: source, to: destination)
                if journalSuffix.isEmpty { mainBackupPath = destination.path }
            } catch {
                print("LingoBook: failed to back up \(source.lastPathComponent): \(error)")
            }
        }

        return mainBackupPath
    }
}
