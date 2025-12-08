import Foundation
@preconcurrency import Translation

/// Translation result wrapper
struct TranslationResult {
    let original: String
    let translated: String
}

/// Service for translating text using Apple's Translation API
@MainActor
@Observable
class TranslationService {
    var isTranslating = false
    var error: String?
    var progress: Double = 0
    var results: [TranslationResult] = []
    
    /// Default source language (French)
    static let defaultSourceLanguage = Locale.Language(identifier: "fr")
    /// Default target language (English)
    static let defaultTargetLanguage = Locale.Language(identifier: "en")
    
    /// Pending translation requests
    var pendingTexts: [String] = []
    var configuration: TranslationSession.Configuration?
    
    /// Request translation of texts
    func requestTranslation(
        texts: [String],
        from source: Locale.Language = defaultSourceLanguage,
        to target: Locale.Language = defaultTargetLanguage
    ) {
        pendingTexts = texts
        results = []
        isTranslating = true
        progress = 0
        error = nil
        
        // Create or update configuration to trigger translation
        if configuration == nil {
            configuration = TranslationSession.Configuration(
                source: source,
                target: target
            )
        } else {
            configuration?.invalidate()
        }
    }
    
    /// Maximum characters per translation chunk to avoid API limits
    private let maxChunkSize = 500
    
    /// Split long text into smaller chunks by sentences
    private func splitIntoChunks(_ text: String) -> [String] {
        guard text.count > maxChunkSize else { return [text] }
        
        var chunks: [String] = []
        var currentChunk = ""
        
        // Split by sentence-ending punctuation
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?。！？"))
        
        for (index, sentence) in sentences.enumerated() {
            let trimmed = sentence.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            
            // Add back punctuation (assume period if not last)
            let punctuation = index < sentences.count - 1 ? ". " : ""
            let fullSentence = trimmed + punctuation
            
            if currentChunk.count + fullSentence.count > maxChunkSize && !currentChunk.isEmpty {
                chunks.append(currentChunk.trimmingCharacters(in: .whitespaces))
                currentChunk = fullSentence
            } else {
                currentChunk += fullSentence
            }
        }
        
        if !currentChunk.trimmingCharacters(in: .whitespaces).isEmpty {
            chunks.append(currentChunk.trimmingCharacters(in: .whitespaces))
        }
        
        return chunks.isEmpty ? [text] : chunks
    }
    
    /// Process translation with session (called from .translationTask)
    func performTranslation(using session: TranslationSession) async {
        guard !pendingTexts.isEmpty else {
            isTranslating = false
            return
        }
        
        do {
            // Prepare all translation requests
            var allRequests: [TranslationSession.Request] = []
            var requestMap: [(textIndex: Int, chunkIndex: Int)] = []
            
            for (textIndex, text) in pendingTexts.enumerated() {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let chunks = splitIntoChunks(text)
                    for (chunkIndex, chunk) in chunks.enumerated() {
                        allRequests.append(TranslationSession.Request(sourceText: chunk))
                        requestMap.append((textIndex: textIndex, chunkIndex: chunkIndex))
                    }
                }
            }
            
            // Perform batch translation
            var responseMap: [Int: [Int: String]] = [:]
            
            if !allRequests.isEmpty {
                let responses = try await session.translations(from: allRequests)
                for (index, response) in responses.enumerated() {
                    let mapping = requestMap[index]
                    if responseMap[mapping.textIndex] == nil {
                        responseMap[mapping.textIndex] = [:]
                    }
                    responseMap[mapping.textIndex]?[mapping.chunkIndex] = response.targetText
                }
            }
            
            // Assemble results
            var translatedResults: [TranslationResult] = []
            for (index, text) in pendingTexts.enumerated() {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    translatedResults.append(TranslationResult(original: text, translated: ""))
                } else if let chunks = responseMap[index] {
                    let sortedChunks = chunks.sorted { $0.key < $1.key }.map { $0.value }
                    translatedResults.append(TranslationResult(
                        original: text,
                        translated: sortedChunks.joined(separator: " ")
                    ))
                } else {
                    translatedResults.append(TranslationResult(original: text, translated: ""))
                }
                progress = Double(index + 1) / Double(pendingTexts.count)
            }
            
            results = translatedResults
            pendingTexts = []
            isTranslating = false
            
        } catch {
            self.error = error.localizedDescription
            isTranslating = false
        }
    }
    
    /// Get translated texts as array
    var translatedTexts: [String] {
        results.map { $0.translated }
    }
    
    /// Reset state
    func reset() {
        pendingTexts = []
        results = []
        isTranslating = false
        progress = 0
        error = nil
    }
}

// MARK: - Extensions

extension Locale.Language {
    /// Create a Language from a language code string
    static func from(_ code: String) -> Locale.Language {
        return Locale.Language(identifier: code)
    }
}
