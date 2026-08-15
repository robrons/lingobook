import Foundation

/// What the tutor can see of what you're reading.
///
/// The page text is the whole point: a tutor that can't see the sentence you're
/// looking at forces you to retype it, and answering "why this tense?" without the
/// surrounding clause is guesswork.
struct TutorContext: Sendable {
    let bookTitle: String
    let chapterTitle: String
    let pageText: String
}

struct TutorMessage: Identifiable, Sendable, Equatable {
    enum Role: Sendable {
        case reader
        case tutor
    }

    let id: UUID
    let role: Role
    var text: String

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

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Can't reach the local model. Start it with “brew services start ollama”."
        case .modelMissing(let model):
            return "The model “\(model)” isn't installed. Run “ollama pull \(model)”."
        case .badResponse(let code):
            return "The local model returned an unexpected response (HTTP \(code))."
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

    init(
        model: String = "ministral-3:8b",
        endpoint: URL = URL(string: "http://localhost:11434/api/chat")!
    ) {
        self.model = model
        self.endpoint = endpoint
    }

    // MARK: - Prompt

    /// The tutor's standing instructions.
    ///
    /// The line about admitting uncertainty is load-bearing, not politeness. A small
    /// model asked about `ne … point` will confidently explain that it reinforces a
    /// `pas` that isn't there — fluent, authoritative, and wrong. A reader learning the
    /// language cannot catch that, so the model is told to flag its own doubt.
    private func systemPrompt(for context: TutorContext) -> String {
        """
        You are a French reading tutor sitting beside an English speaker who is reading \
        “\(context.bookTitle)”. They can see the page; you can too.

        Answer in English, concisely — two or three sentences unless asked for more.
        Quote the French you are discussing inside « guillemets ».
        Name tenses, moods and constructions explicitly (passé simple, subjonctif, \
        and so on) — the reader is trying to learn them, not just get past them.
        If you are not certain, say so plainly instead of guessing. A confident wrong \
        answer teaches them something false, which is worse than saying "I'm not sure".
        Do not translate the whole passage unless you are asked to.

        The current chapter is “\(context.chapterTitle)”.

        The page in front of them reads:
        \"\"\"
        \(context.pageText)
        \"\"\"
        """
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
                    var wire: [WireMessage] = [
                        WireMessage(role: "system", content: systemPrompt(for: context))
                    ]
                    wire += history.map {
                        WireMessage(role: $0.role == .reader ? "user" : "assistant", content: $0.text)
                    }
                    wire.append(WireMessage(role: "user", content: question))

                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(
                        ChatRequest(model: model, messages: wire, stream: true)
                    )
                    // Generous: the first request after a cold start pays for loading
                    // several gigabytes of weights into memory before a token appears.
                    request.timeoutInterval = 180

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
                        let chunk = try JSONDecoder().decode(ChatChunk.self, from: data)
                        if let piece = chunk.message?.content, !piece.isEmpty {
                            continuation.yield(piece)
                        }
                        if chunk.done { break }
                    }

                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let error as URLError where error.code == .cannotConnectToHost
                    || error.code == .cannotFindHost {
                    continuation.finish(throwing: TutorError.notRunning)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Wire format

    private struct WireMessage: Encodable {
        let role: String
        let content: String
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [WireMessage]
        let stream: Bool
    }

    private struct ChatChunk: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
        let done: Bool
    }
}
