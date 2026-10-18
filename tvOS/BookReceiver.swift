import Foundation
import Network
import SwiftData

/// Listens on the local network for books sent from LingoBook on a Mac.
///
/// Apple TV has no file picker and no Translation framework, so this is the only way a
/// book gets here: the Mac translates it, finds this listener over Bonjour, and sends the
/// EPUB with its translations. A book sent again replaces its translations but keeps the
/// reading position already made on the TV.
@MainActor
@Observable
final class BookReceiver {
    static let shared = BookReceiver()

    /// Books arriving right now.
    private(set) var incoming = 0
    /// Title of the last book to arrive, for a brief "added" notice.
    private(set) var lastArrival: String?

    private var listener: NWListener?
    private var modelContext: ModelContext?
    private var arrivalNoticeTask: Task<Void, Never>?

    func start(modelContext: ModelContext) {
        self.modelContext = modelContext
        guard listener == nil else { return }

        do {
            let listener = try NWListener(using: .tcp)
            // No name: Bonjour uses the Apple TV's own, so the Mac can say which TV it's
            // sending to ("Living Room").
            listener.service = NWListener.Service(type: BookTransfer.serviceType)
            listener.newConnectionHandler = { connection in
                Task { @MainActor in BookReceiver.shared.accept(connection) }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .failed, .cancelled:
                    Task { @MainActor in BookReceiver.shared.listenerStopped() }
                default:
                    break
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            print("LingoBook: could not listen for books: \(error)")
        }
    }

    /// Lets the next `start` build a fresh listener.
    private func listenerStopped() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        incoming += 1
        connection.start(queue: .main)

        let headerSize = MemoryLayout<UInt64>.size
        connection.receive(minimumIncompleteLength: headerSize, maximumLength: headerSize) { header, _, _, _ in
            guard let header, let length = BookTransfer.length(fromHeader: header) else {
                Task { @MainActor in BookReceiver.shared.close(connection, received: nil) }
                return
            }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, _ in
                let transfer = body.flatMap { try? BookTransfer.decode(body: $0) }
                Task { @MainActor in BookReceiver.shared.close(connection, received: transfer) }
            }
        }
    }

    private func close(_ connection: NWConnection, received transfer: BookTransfer?) {
        incoming = max(0, incoming - 1)

        guard let transfer, store(transfer) else {
            connection.cancel()
            return
        }

        // Only acknowledge once it's saved — the Mac marks the book delivered on this byte.
        connection.send(
            content: Data([BookTransfer.acknowledgement]),
            completion: .contentProcessed { _ in connection.cancel() }
        )
        announce(transfer.title)
    }

    private func store(_ transfer: BookTransfer) -> Bool {
        guard let modelContext else { return false }

        let id = transfer.id
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })

        if let existing = try? modelContext.fetch(descriptor).first {
            existing.title = transfer.title
            existing.author = transfer.author
            existing.language = transfer.language
            existing.epubData = transfer.epubData
            existing.coverData = transfer.coverData
            existing.translationsData = transfer.translationsData
        } else {
            let book = Book(
                id: transfer.id,
                title: transfer.title,
                author: transfer.author,
                epubData: transfer.epubData,
                coverData: transfer.coverData,
                language: transfer.language
            )
            book.translationsData = transfer.translationsData
            modelContext.insert(book)
        }

        do {
            try modelContext.save()
            return true
        } catch {
            print("LingoBook: could not save received book: \(error)")
            return false
        }
    }

    private func announce(_ title: String) {
        lastArrival = title
        arrivalNoticeTask?.cancel()
        arrivalNoticeTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            BookReceiver.shared.lastArrival = nil
        }
    }
}
