import Foundation
import NaturalLanguage

/// What the tutor can see of what you're reading.
///
/// The page text is the whole point: a tutor that can't see the sentence you're
/// looking at forces you to retype it, and answering "why this tense?" without the
/// surrounding clause is guesswork.
struct TutorContext: Sendable {
    let bookTitle: String
    let bookAuthor: String
    let chapterTitle: String
    let pageText: String
    /// Identifies which page this is, so a turned page can be noticed mid-conversation.
    let pageID: String

    /// Where the reader is: "chapter 14 of 365, about 4% in".
    let position: String

    /// The chapters around the reader, current one marked.
    ///
    /// Without this the tutor knows the sentence in front of it and nothing else — not
    /// what this edition contains, not what has been read, not what is coming. Asked
    /// where to skip ahead to, it answers from a general memory of the novel and points
    /// at chapters already finished, because it has never been told any of that.
    /// A larger model would recall the book better and still be guessing about *this*
    /// copy of it.
    let outline: String

    /// The book's own language, as a BCP-47 code from the EPUB's metadata.
    var language: String?

    /// Wikipedia on this book and its author, fetched once when the book was imported.
    ///
    /// The model does not contain this. Asked when the novel was published or how it was
    /// received, an 8B model produces fluent, plausible, wrong dates — and a reader who
    /// came to the tutor precisely because they didn't know has no way to catch it.
    var about: String?

    /// What has happened in the chapters the reader has actually finished.
    var storySoFar: String?

    /// Encyclopedia notes for this one question, resolved just before it was sent.
    ///
    /// Per-question rather than standing, so it travels with the turn it belongs to and
    /// ages out of the conversation naturally.
    var references: String?
}

struct TutorMessage: Identifiable, Sendable, Equatable {
    enum Role: Sendable {
        case reader
        case tutor
        /// A divider in the transcript — "turned to a new page" — not a turn.
        case note
    }

    let id: UUID
    let role: Role
    var text: String

    /// Wikipedia articles this reply had in front of it, shown beneath it.
    var references: [String] = []

    /// Markers shown in the transcript but never sent to the model.
    var isNote: Bool { role == .note }

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// A conversational tutor for the page on screen.
///
/// Everything behind this protocol is swappable: a local model today, a hosted one
/// later, or a different local model when a better small one ships. Only the
/// implementation knows where the answer comes from — the panel never does.
protocol TutorService: Sendable {
    /// Answers in pieces as they arrive.
    ///
    /// Streaming rather than a single reply because a local model on a laptop takes a
    /// few seconds to finish a paragraph, and watching words appear reads as thinking
    /// while a spinner for the same duration reads as broken.
    func stream(
        question: String,
        context: TutorContext,
        history: [TutorMessage]
    ) -> AsyncThrowingStream<String, any Error>
}

enum TutorError: LocalizedError {
    case notRunning
    case modelMissing(String)
    case badResponse(Int)
    case modelSaid(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Can't reach the local model. Start it with “brew services start ollama”."
        case .modelMissing(let model):
            return "The model “\(model)” isn't installed. Run “ollama pull \(model)”."
        case .badResponse(let code):
            return "The local model returned an unexpected response (HTTP \(code))."
        case .modelSaid(let message):
            return "The local model stopped: \(message)"
        }
    }
}

// MARK: - Ollama plumbing

/// The wire format and connection details, shared by everything that talks to Ollama.
///
/// The tutor streams; the chapter summariser doesn't. Both want the same model, the same
/// endpoint, and the same keep-alive, and neither should own the definition of them.
enum Ollama {

    static let defaultModel = "ministral-3:8b"
    static let chatEndpoint = URL(string: "http://localhost:11434/api/chat")!

    /// Ollama drops a model from memory after about five idle minutes. A reader who asks
    /// a question every ten minutes would then pay the several-second cold start every
    /// single time — indistinguishable, from the outside, from an app that is simply
    /// slow. Each request pushes the eviction back out to half an hour.
    static let keepAlive = "30m"

    struct Message: Encodable, Sendable {
        let role: String
        let content: String
    }

    struct Options: Encodable, Sendable {
        var num_ctx: Int?
        var temperature: Double?
    }

    struct ChatRequest: Encodable, Sendable {
        let model: String
        let messages: [Message]
        let stream: Bool
        let options: Options
        let keep_alive: String
    }

    /// One streamed chunk, or an entire non-streamed reply — the shapes agree.
    struct ChatChunk: Decodable, Sendable {
        struct Content: Decodable, Sendable { let content: String? }
        let message: Content?
        let done: Bool?
        /// Ollama reports mid-stream failures as an ordinary line with this field set.
        /// Without decoding it, a model that fails to load surfaces to the reader as a
        /// raw Swift `DecodingError` about a missing key.
        let error: String?
    }

    static func request(
        messages: [Message],
        model: String,
        endpoint: URL,
        stream: Bool,
        contextTokens: Int,
        temperature: Double? = nil,
        timeout: TimeInterval
    ) throws -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            ChatRequest(
                model: model,
                messages: messages,
                stream: stream,
                options: Options(num_ctx: contextTokens, temperature: temperature),
                keep_alive: keepAlive
            )
        )
        request.timeoutInterval = timeout
        return request
    }

    /// Whether the thing that answers questions is actually there.
    ///
    /// The tutor's single biggest failure — Ollama not running — used to be discoverable
    /// only by asking a question and reading the error afterwards. This lets the panel
    /// say so up front, before a question is wasted on it.
    enum EngineState: Equatable {
        case checking
        case notRunning
        case modelMissing
        /// Installed, but not in memory: the next answer pays the cold-start wait.
        case cold
        case warm
    }

    static func engineState(model: String = defaultModel) async -> EngineState {
        func names(_ path: String) async throws -> [String] {
            var request = URLRequest(url: URL(string: "http://localhost:11434\(path)")!)
            request.timeoutInterval = 3
            let (data, _) = try await URLSession.shared.data(for: request)
            struct Listing: Decodable {
                struct Entry: Decodable { let name: String }
                let models: [Entry]
            }
            return (try JSONDecoder().decode(Listing.self, from: data)).models.map(\.name)
        }

        guard let installed = try? await names("/api/tags") else { return .notRunning }
        guard installed.contains(model) else { return .modelMissing }
        // /api/ps lists what is loaded in memory right now, which is the difference
        // between an answer starting in a second and in twenty.
        let loaded = (try? await names("/api/ps")) ?? []
        return loaded.contains(model) ? .warm : .cold
    }

    /// Maps the errors worth explaining; everything else passes through untouched.
    static func translate(_ error: any Error) -> any Error {
        if let urlError = error as? URLError,
           urlError.code == .cannotConnectToHost || urlError.code == .cannotFindHost {
            return TutorError.notRunning
        }
        return error
    }

    /// One complete reply, no streaming.
    ///
    /// For work with no reader waiting on it — summarising a finished chapter — where a
    /// token-by-token stream would be pure ceremony.
    static func complete(
        system: String,
        user: String,
        model: String = defaultModel,
        endpoint: URL = chatEndpoint,
        contextTokens: Int = 16_384,
        temperature: Double = 0.2,
        timeout: TimeInterval = 180
    ) async throws -> String {
        let request = try request(
            messages: [Message(role: "system", content: system),
                       Message(role: "user", content: user)],
            model: model,
            endpoint: endpoint,
            stream: false,
            contextTokens: contextTokens,
            temperature: temperature,
            timeout: timeout
        )

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw http.statusCode == 404
                    ? TutorError.modelMissing(model)
                    : TutorError.badResponse(http.statusCode)
            }
            let chunk = try JSONDecoder().decode(ChatChunk.self, from: data)
            if let error = chunk.error { throw TutorError.modelSaid(error) }
            return (chunk.message?.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw translate(error)
        }
    }
}

/// Talks to a model served by Ollama on this machine.
///
/// Nothing leaves the laptop and nothing is billed per token, which is the whole
/// reason for choosing a local model over a hosted one here.
struct OllamaTutor: TutorService {

    let model: String
    let endpoint: URL

    /// Ollama defaults to 4,096, which the page text and system prompt eat about a
    /// quarter of before a question is asked — a conversation then starts silently
    /// forgetting its own opening. 16K leaves room to actually hold a discussion; the
    /// cost is a larger KV cache in memory, which on this model is a few hundred MB.
    let contextTokens: Int

    /// How many earlier turns travel with a question.
    ///
    /// The transcript used to be resent in full, forever. Past the context window Ollama
    /// truncates silently and it truncates from the *top* — which is where the system
    /// prompt lives. So the longest, most involved conversations were exactly the ones
    /// that quietly lost their instructions, their outline, and now their background and
    /// story-so-far. The panel still shows everything; only what's sent is bounded.
    let historyTurns: Int

    init(
        model: String = Ollama.defaultModel,
        endpoint: URL = Ollama.chatEndpoint,
        contextTokens: Int = 16_384,
        historyTurns: Int = 12
    ) {
        self.model = model
        self.endpoint = endpoint
        self.contextTokens = contextTokens
        self.historyTurns = historyTurns
    }

    // MARK: - Prompt

    /// The assistant's standing instructions.
    ///
    /// Deliberately *not* a tutor persona. Given a teaching role, a model volunteers
    /// grammar drills and corrects the reader's own phrasing — turning every question
    /// into a lesson nobody asked for. Its job here is narrower and more useful: know
    /// what is on the page, then answer whatever is actually asked about it.
    ///
    /// The line about admitting uncertainty stays, and is load-bearing rather than
    /// politeness. Asked what `ne … point` is doing, an 8B model confidently explains
    /// that it reinforces a `pas` that isn't in the clause — fluent, authoritative, and
    /// wrong. A reader who is still learning the language cannot catch that.
    /// Names the reply language outright instead of asking the model to infer it.
    ///
    /// Telling it to "answer in the language they asked in" doesn't survive contact with
    /// a French page: given Hugo as context, this model answers an English question in
    /// French. Detection happens here, on device, and the instruction is stated as a
    /// fact — which it follows. Ambiguous or very short input falls back to English,
    /// since that is what a reader of an English-language app expects by default.
    private func languageInstruction(for question: String, context: TutorContext) -> String {
        let code = (context.language ?? "fr").split(separator: "-").first.map(String.init) ?? "fr"
        let bookLanguage = NLLanguage(code)
        let name = Locale.current.localizedString(forLanguageCode: code) ?? "the book's language"

        guard bookLanguage != .english else {
            return "Reply in English."
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(question)
        let score = recognizer.languageHypotheses(withMaximum: 3)[bookLanguage] ?? 0

        if score > 0.6 {
            return """
            The reader wrote to you in \(name) — they are practising the language. Reply \
            in \(name), pitched at the level they wrote at. Do not switch to English to \
            be helpful.
            """
        }

        return "The reader wrote to you in English. Reply in English, even though the page is in \(name)."
    }

    private func systemPrompt(for context: TutorContext, question: String) -> String {
        var sections: [String] = []

        sections.append("""
        You are helping someone read “\(context.bookTitle)” by \(context.bookAuthor). They \
        are on the page below and can see it; so can you. The current chapter is \
        “\(context.chapterTitle)” — \(context.position).
        """)

        sections.append("""
        Where they are in the book, with ▸ marking the chapter they are reading. \
        Anything above it they have already read; anything below is still to come. When \
        they ask where to skip to or what is coming, answer from this list and name the \
        chapter, never from general knowledge of the book:
        \(context.outline)
        """)

        // Reference material first, instructions after — so what the model is told to do
        // sits closest to the question it has to do it to.
        if let about = context.about {
            sections.append("""
            Background on this book, from Wikipedia. Where it disagrees with what you \
            remember, it is right and you are wrong:
            \(about)
            """)
        }

        if let storySoFar = context.storySoFar {
            sections.append("""
            What has happened so far, taken only from the chapters this reader has \
            actually finished. When they ask what has happened, or who someone is, answer \
            from this — never add events from your own memory of the book:
            \(storySoFar)
            """)
        }

        sections.append("""
        Answer whatever they ask about this page — what a word means, what just happened, \
        who someone is, a translation, the history behind a reference. Keep it short \
        unless they ask for depth.
        """)

        // Everything above the reader's position is fair game; everything below is the
        // book being spoiled by the thing that was supposed to help them read it.
        sections.append("""
        Don't reveal what happens after where they are now. If they ask you to guess \
        what comes next, speculate from what they have read and say plainly that you are \
        speculating. If they ask outright how it ends, warn them before you answer.
        """)

        sections.append(languageInstruction(for: question, context: context))

        sections.append("""
        Do not correct their spelling or grammar, and do not turn an answer into a \
        language lesson. If they want grammar explained they will ask; until then, just \
        answer the question.
        """)

        sections.append("If you are not certain, say so plainly instead of guessing.")

        sections.append("""
        Earlier questions in this conversation may have been about a different page. \
        The page quoted alongside the reader's latest question is the one in front of \
        them now — answer about that one.
        """)

        return sections.joined(separator: "\n\n")
    }

    /// The reader's question with the page attached to it.
    ///
    /// The page used to live in the system prompt, which sits above the entire
    /// conversation — so after a few exchanges a freshly turned page was buried under
    /// history about the previous one, and the model kept answering about whatever had
    /// been discussed most. Recency wins, so the page travels with the question.
    ///
    /// Only the newest turn carries it. Repeating the page on every historical turn
    /// would trade the bug for a context window full of duplicated text.
    private func questionWithPage(_ question: String, context: TutorContext) -> String {
        var parts = [
            """
            The page in front of me right now, from “\(context.chapterTitle)”:
            \"\"\"
            \(context.pageText)
            \"\"\"
            """
        ]

        // Between the page and the question: close enough to the question to be used,
        // far enough from it that the question is still the last thing read.
        if let references = context.references {
            parts.append(references)
        }

        parts.append(question)
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Streaming

    func stream(
        question: String,
        context: TutorContext,
        history: [TutorMessage]
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var wire: [Ollama.Message] = [
                        Ollama.Message(
                            role: "system",
                            content: systemPrompt(for: context, question: question)
                        )
                    ]
                    wire += history
                        .filter { !$0.isNote }
                        .suffix(historyTurns)
                        .map {
                            Ollama.Message(
                                role: $0.role == .reader ? "user" : "assistant",
                                content: $0.text
                            )
                        }
                    wire.append(
                        Ollama.Message(
                            role: "user",
                            content: questionWithPage(question, context: context)
                        )
                    )

                    // Generous: the first request after a cold start pays for loading
                    // several gigabytes of weights into memory before a token appears.
                    let request = try Ollama.request(
                        messages: wire,
                        model: model,
                        endpoint: endpoint,
                        stream: true,
                        contextTokens: contextTokens,
                        timeout: 180
                    )

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw http.statusCode == 404
                            ? TutorError.modelMissing(model)
                            : TutorError.badResponse(http.statusCode)
                    }

                    // Ollama streams newline-delimited JSON, one object per chunk.
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
                        let chunk = try JSONDecoder().decode(Ollama.ChatChunk.self, from: data)
                        if let error = chunk.error { throw TutorError.modelSaid(error) }
                        if let piece = chunk.message?.content, !piece.isEmpty {
                            continuation.yield(piece)
                        }
                        if chunk.done == true { break }
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Ollama.translate(error))
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
