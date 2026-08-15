import Foundation
import NaturalLanguage

/// What the tutor can see of what you're reading.
///
/// The page text is the whole point: a tutor that can't see the sentence you're
/// looking at forces you to retype it, and answering "why this tense?" without the
/// surrounding clause is guesswork.
struct TutorContext: Sendable {
    let bookTitle: String
    let chapterTitle: String
    let pageText: String
    /// Identifies which page this is, so a turned page can be noticed mid-conversation.
    let pageID: String
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

    /// Ollama defaults to 4,096, which the page text and system prompt eat about a
    /// quarter of before a question is asked — a conversation then starts silently
    /// forgetting its own opening. 16K leaves room to actually hold a discussion; the
    /// cost is a larger KV cache in memory, which on this model is a few hundred MB.
    let contextTokens: Int

    init(
        model: String = "ministral-3:8b",
        endpoint: URL = URL(string: "http://localhost:11434/api/chat")!,
        contextTokens: Int = 16_384
    ) {
        self.model = model
        self.endpoint = endpoint
        self.contextTokens = contextTokens
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
    private func languageInstruction(for question: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(question)
        let french = recognizer.languageHypotheses(withMaximum: 3)[.french] ?? 0

        if french > 0.6 {
            return """
            The reader wrote to you in French — they are practising the language. Reply \
            in French, pitched at the level they wrote at. Do not switch to English to \
            be helpful.
            """
        }

        return "The reader wrote to you in English. Reply in English, even though the page is French."
    }

    private func systemPrompt(for context: TutorContext, question: String) -> String {
        let languageInstruction = languageInstruction(for: question)
        return """
        You are helping someone read “\(context.bookTitle)”. They are on the page below \
        and can see it; so can you. The current chapter is “\(context.chapterTitle)”.

        Answer whatever they ask about this page — what a word means, what just happened, \
        who someone is, a translation, the history behind a reference. Keep it short \
        unless they ask for depth.

        \(languageInstruction)

        Do not correct their spelling or grammar, and do not turn an answer into a \
        language lesson. If they want grammar explained they will ask; until then, just \
        answer the question.

        If you are not certain, say so plainly instead of guessing.

        Earlier questions in this conversation may have been about a different page. \
        The page quoted alongside the reader's latest question is the one in front of \
        them now — answer about that one.
        """
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
        """
        The page in front of me right now, from “\(context.chapterTitle)”:
        \"\"\"
        \(context.pageText)
        \"\"\"

        \(question)
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
                        WireMessage(role: "system", content: systemPrompt(for: context, question: question))
                    ]
                    wire += history
                        .filter { !$0.isNote }
                        .map {
                            WireMessage(
                                role: $0.role == .reader ? "user" : "assistant",
                                content: $0.text
                            )
                        }
                    wire.append(
                        WireMessage(role: "user", content: questionWithPage(question, context: context))
                    )

                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONEncoder().encode(
                        ChatRequest(
                            model: model,
                            messages: wire,
                            stream: true,
                            options: .init(num_ctx: contextTokens)
                        )
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
        struct Options: Encodable {
            let num_ctx: Int
        }
        let model: String
        let messages: [WireMessage]
        let stream: Bool
        let options: Options
    }

    private struct ChatChunk: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
        let done: Bool
    }
}
