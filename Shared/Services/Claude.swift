import Foundation

/// Talks to Claude over the Anthropic API.
///
/// Plain `URLSession` rather than an SDK: there is no official Swift one, and the whole
/// surface used here is one streamed POST. Haiku because the questions asked about a page
/// are answered from the text sent with them, not from what the model remembers — the
/// small model's weak spot — and because on a television the first words need to arrive
/// in about a second.
///
/// The key is compiled in, from `tvOS/Secrets.swift` — git-ignored, so it stays off
/// GitHub. Fine for an app that only ever runs on your own Apple TV; anyone holding the
/// binary could dig it out, so this app is never one to hand to anyone else.
enum Claude {
    static let model = "claude-haiku-5-5"
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"

    struct Message: Encodable, Sendable {
        let role: String
        let content: String
    }

    /// A page the answer drew on, from a web search.
    struct Source: Equatable, Hashable, Sendable {
        let title: String
        let url: String

        /// "en.wikipedia.org", for showing where something came from on a screen that
        /// can't open links.
        var site: String {
            URL(string: url)?.host()?.replacingOccurrences(of: "www.", with: "") ?? url
        }
    }

    /// What comes down the stream: the answer's words, a search starting, and the pages
    /// the answer cites.
    enum Chunk: Sendable {
        case text(String)
        case searching
        case source(Source)
    }

    enum Failure: LocalizedError {
        case rejectedKey
        case busy
        case declined
        case http(Int, String?)

        var errorDescription: String? {
            switch self {
            case .rejectedKey:
                return "Claude didn't accept the API key built into this app. Check tvOS/Secrets.swift and rebuild."
            case .busy:
                return "Claude is busy right now. Try again in a moment."
            case .declined:
                return "Claude declined to answer that one."
            case .http(let code, let message):
                return message ?? "Claude returned an error (HTTP \(code))."
            }
        }
    }

    private struct Request: Encodable {
        struct OutputConfig: Encodable { let effort: String }
        struct CacheControl: Encodable { let type = "ephemeral" }
        /// The older web search tool: the newer `web_search_20260209` returns errors on
        /// Haiku 5.5. Two searches at most — about 2¢ and a few seconds, worst case.
        struct WebSearch: Encodable {
            let type = "web_search_20250305"
            let name = "web_search"
            let max_uses = 2
        }

        let model: String
        let max_tokens: Int
        let stream = true
        let system: String
        let messages: [Message]
        /// Low effort: a question about a page doesn't need long deliberation, and every
        /// token of thinking is a token of waiting on the sofa. Medium when searching: at
        /// low, stitching cited sentences together came out saying each fact twice.
        let output_config: OutputConfig
        /// Caches up to the end of the conversation, so a follow-up rereads the chapter
        /// at a tenth of the price instead of paying for it again.
        let cache_control = CacheControl()
        /// Only when the question may need the world outside the book. Claude decides
        /// whether to search; without the tool it can't.
        let tools: [WebSearch]?
    }

    /// One reply, a piece at a time as it's written.
    static func stream(
        system: String,
        messages: [Message],
        webSearch: Bool = false,
        maxTokens: Int = 1500
    ) -> AsyncThrowingStream<Chunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 60
                    request.setValue("application/json", forHTTPHeaderField: "content-type")
                    request.setValue(Secrets.claudeAPIKey, forHTTPHeaderField: "x-api-key")
                    request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
                    request.httpBody = try JSONEncoder().encode(
                        Request(
                            model: model,
                            max_tokens: maxTokens,
                            system: system,
                            messages: messages,
                            output_config: Request.OutputConfig(effort: webSearch ? "medium" : "low"),
                            tools: webSearch ? [Request.WebSearch()] : nil
                        )
                    )

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw failure(status: http.statusCode, body: body)
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let event = try JSONDecoder().decode(Event.self, from: Data(line.dropFirst(5).utf8))
                        switch event.type {
                        case "content_block_start":
                            if event.content_block?.type == "server_tool_use" { continuation.yield(.searching) }
                        case "content_block_delta":
                            if let text = event.delta?.text { continuation.yield(.text(text)) }
                            if let cited = event.delta?.citation, let url = cited.url {
                                continuation.yield(.source(Source(title: cited.title ?? url, url: url)))
                            }
                        case "message_delta":
                            if event.delta?.stop_reason == "refusal" { throw Failure.declined }
                        case "error":
                            throw Failure.http(0, event.error?.message)
                        default:
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The parts of a server-sent event this reads. Thinking and the search's own query
    /// arrive as deltas with no `text`, and are skipped.
    private struct Event: Decodable {
        struct Block: Decodable { let type: String }
        struct Citation: Decodable {
            let url: String?
            let title: String?
        }
        struct Delta: Decodable {
            let text: String?
            let stop_reason: String?
            let citation: Citation?
        }
        struct ErrorBody: Decodable { let message: String? }
        let type: String
        let content_block: Block?
        let delta: Delta?
        let error: ErrorBody?
    }

    private static func failure(status: Int, body: String) -> Failure {
        struct Envelope: Decodable {
            struct Body: Decodable { let message: String? }
            let error: Body?
        }
        switch status {
        case 401, 403: return .rejectedKey
        case 429, 529: return .busy
        default:
            let message = (try? JSONDecoder().decode(Envelope.self, from: Data(body.utf8)))?.error?.message
            return .http(status, message)
        }
    }
}
