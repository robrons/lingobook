import SwiftUI
import SwiftData
import Network

/// Finds Apple TVs running LingoBook on the local network and hands them translated books.
///
/// The TV can only listen while its app is open — tvOS suspends it otherwise — so the Mac
/// keeps watching for one for as long as LingoBook runs here. A book that's ready goes the
/// moment a TV appears, and keeps being retried while one is visible but not answering.
@MainActor
@Observable
final class AppleTVSender {
    static let shared = AppleTVSender()

    /// Names of the Apple TVs currently advertising LingoBook.
    private(set) var appleTVNames: [String] = []
    /// Books on the wire right now, each with the attempt carrying it.
    private var attempts: [UUID: UUID] = [:]

    func isSending(_ book: Book) -> Bool { attempts[book.id] != nil }

    /// Long enough for a large book over slow Wi-Fi; short enough that a TV that has
    /// vanished doesn't leave a book stuck on "Sending…".
    private static let attemptTimeout: Duration = .seconds(90)

    private var browser: NWBrowser?
    private var endpoints: [NWEndpoint] = []
    /// Which TV to try next. Moves on after a failure, so one listed-but-gone TV (asleep,
    /// app closed, a simulator that was shut down) can't block the others.
    private var endpointCursor = 0
    private var modelContext: ModelContext?
    private var retryTask: Task<Void, Never>?

    func start(modelContext: ModelContext) {
        self.modelContext = modelContext
        guard browser == nil else { return }

        let browser = NWBrowser(for: .bonjour(type: BookTransfer.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            let endpoints = results.map(\.endpoint)
            Task { @MainActor in AppleTVSender.shared.update(endpoints) }
        }
        browser.start(queue: .main)
        self.browser = browser

        // A TV that was asleep, or whose app was in the background, can stay listed
        // without answering. Keep knocking while something is waiting to go.
        retryTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                AppleTVSender.shared.sendWaitingBooks()
            }
        }
    }

    private func update(_ endpoints: [NWEndpoint]) {
        self.endpoints = endpoints
        appleTVNames = endpoints.compactMap {
            if case let .service(name, _, _, _) = $0 { return name }
            return nil
        }
        sendWaitingBooks()
    }

    func sendWaitingBooks() {
        guard let modelContext, !endpoints.isEmpty else { return }
        let endpoint = endpoints[endpointCursor % endpoints.count]

        let waiting = AppleTVStatus.waiting.rawValue
        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.appleTVStatusRaw == waiting })
        for book in (try? modelContext.fetch(descriptor)) ?? [] where attempts[book.id] == nil {
            send(book, to: endpoint)
        }
    }

    private func send(_ book: Book, to endpoint: NWEndpoint) {
        let transfer = BookTransfer(
            id: book.id,
            title: book.title,
            author: book.author,
            language: book.language,
            epubData: book.epubData,
            coverData: book.coverData,
            translationsData: book.translationsData
        )
        guard let payload = try? transfer.encoded() else { return }

        let id = book.id
        let attempt = UUID()
        attempts[id] = attempt

        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: payload, completion: .contentProcessed { error in
                    guard error == nil else {
                        Task { @MainActor in AppleTVSender.shared.finish(id, attempt, connection, delivered: false) }
                        return
                    }
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, _, _ in
                        let delivered = data?.first == BookTransfer.acknowledgement
                        Task { @MainActor in AppleTVSender.shared.finish(id, attempt, connection, delivered: delivered) }
                    }
                })
            case .failed, .waiting:
                // `.waiting` means the TV is listed but not reachable; the retry loop will
                // try again rather than leaving this connection hanging.
                Task { @MainActor in AppleTVSender.shared.finish(id, attempt, connection, delivered: false) }
            default:
                break
            }
        }
        connection.start(queue: .main)

        // A connection to a TV that's listed but gone never fails on its own — it just
        // keeps trying to find it. Give up, so the retry loop can try again or elsewhere.
        Task {
            try? await Task.sleep(for: Self.attemptTimeout)
            AppleTVSender.shared.finish(id, attempt, connection, delivered: false)
        }
    }

    private func finish(_ id: UUID, _ attempt: UUID, _ connection: NWConnection, delivered: Bool) {
        connection.stateUpdateHandler = nil
        connection.cancel()
        // A late timeout or callback from an earlier attempt must not end a newer one.
        guard attempts[id] == attempt else { return }
        attempts[id] = nil

        guard delivered else {
            endpointCursor += 1
            return
        }
        guard let modelContext else { return }

        let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == id })
        if let book = try? modelContext.fetch(descriptor).first {
            book.appleTVStatus = .sent
            try? modelContext.save()
        }
    }
}

/// Hosts the Mac's half of the Apple TV link inside the window: starts looking for TVs,
/// and gives `BookPreparer` the translation session only SwiftUI can create.
struct AppleTVBridge: ViewModifier {
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content
            .translationTask(BookPreparer.shared.configuration) { session in
                await BookPreparer.shared.run(using: session)
            }
            .task {
                AppleTVSender.shared.start(modelContext: modelContext)
                BookPreparer.shared.resumeUnfinished(in: modelContext)
            }
    }
}

/// What a library card says about the book's trip to the Apple TV.
struct AppleTVBadge: View {
    let book: Book

    var body: some View {
        if let label {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(label).monospacedDigit()
            }
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .padding(6)
            .help(help)
        }
    }

    private var preparer: BookPreparer { .shared }
    private var sender: AppleTVSender { .shared }

    private var label: String? {
        if preparer.failures[book.id] != nil { return "Couldn't translate" }
        switch book.appleTVStatus {
        case .none:
            return nil
        case .preparing:
            guard let progress = preparer.progress[book.id] else { return "Queued" }
            return "Translating \(Int((progress * 100).rounded()))%"
        case .waiting:
            return sender.isSending(book) ? "Sending…" : "Waiting for Apple TV"
        case .sent:
            return "On Apple TV"
        }
    }

    private var symbol: String {
        if preparer.failures[book.id] != nil { return "exclamationmark.triangle.fill" }
        switch book.appleTVStatus {
        case .preparing: return "character.book.closed"
        case .waiting: return "appletv"
        case .sent: return "checkmark.circle.fill"
        case .none: return "appletv"
        }
    }

    private var help: String {
        if let failure = preparer.failures[book.id] { return failure }
        switch book.appleTVStatus {
        case .waiting: return "Open LingoBook on your Apple TV and it will arrive. Keep LingoBook open on this Mac until then."
        case .preparing: return "Translating the whole book so it can be read on Apple TV."
        case .sent:
            guard let skipped = preparer.skippedCounts[book.id] else {
                return "This book is in LingoBook on your Apple TV."
            }
            return "This book is in LingoBook on your Apple TV. \(skipped) lines the translator wouldn't take show in the original only."
        case .none: return ""
        }
    }
}
