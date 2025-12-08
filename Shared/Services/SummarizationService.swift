import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Service for summarizing text using Apple's Foundation Models (macOS 26+)
@MainActor
@Observable
class SummarizationService {
    var summary: String = ""
    var isProcessing = false
    var error: String?
    
    /// Check if Foundation Models is available on this device
    var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return true
        }
        #endif
        return false
    }
    
    /// Check availability and return descriptive message
    var unavailableReason: String? {
        if !isAvailable {
            return "Summarization requires macOS Tahoe (26) or later with Apple Intelligence enabled."
        }
        return nil
    }
    
    /// Summarize the provided chapter text
    func summarize(chapterText: String, chapterTitle: String) async {
        guard isAvailable else {
            error = unavailableReason
            return
        }
        
        isProcessing = true
        summary = ""
        error = nil
        
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            await performSummarization(text: chapterText, title: chapterTitle)
        }
        #endif
        
        isProcessing = false
    }
    
    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func performSummarization(text: String, title: String) async {
        do {
            // Create a language model session
            let session = LanguageModelSession()
            
            // Create the summarization prompt
            let prompt = """
            Summarize the following page from a book. Provide a brief summary (2-3 sentences) that captures what happens on this page.
            
            \(title)
            
            Content:
            \(text.prefix(4000))
            
            Summary:
            """
            
            // Generate the summary using streaming
            var fullResponse = ""
            for try await chunk in session.streamResponse(to: prompt) {
                fullResponse = chunk.content
                // Update summary as it streams in
                await MainActor.run {
                    self.summary = fullResponse
                }
            }
            
        } catch {
            self.error = "Failed to generate summary: \(error.localizedDescription)"
        }
    }
    #endif
    
    /// Reset the service state
    func reset() {
        summary = ""
        isProcessing = false
        error = nil
    }
}
