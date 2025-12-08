import SwiftUI

/// Summary sheet for Apple Intelligence summarization
struct SummarySheet: View {
    let chapterTitle: String
    let chapterText: String
    let onDismiss: () -> Void
    
    @State private var summarizationService = SummarizationService()
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Spacer()
                Text("Summary")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            Divider()
            
            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(chapterTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    if !summarizationService.isAvailable {
                        unavailableView
                    } else if let error = summarizationService.error {
                        errorView(message: error)
                    } else if summarizationService.summary.isEmpty && !summarizationService.isProcessing {
                        generatePromptView
                    } else {
                        summaryContentView
                    }
                }
                .padding(20)
            }
            
            Divider()
            
            // Footer
            HStack {
                Button("Close", action: onDismiss)
                    .keyboardShortcut(.escape)
                
                Spacer()
                
                if summarizationService.isAvailable && !summarizationService.isProcessing {
                    Button(summarizationService.summary.isEmpty ? "Generate" : "Regenerate") {
                        Task {
                            await summarizationService.summarize(
                                chapterText: chapterText,
                                chapterTitle: chapterTitle
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(minWidth: 400, idealWidth: 450, minHeight: 350, idealHeight: 400)
        #if os(macOS)
        .background(Color(nsColor: .textBackgroundColor))
        #else
        .background(Color(uiColor: .secondarySystemBackground))
        #endif
        .task {
            if summarizationService.isAvailable {
                await summarizationService.summarize(
                    chapterText: chapterText,
                    chapterTitle: chapterTitle
                )
            }
        }
    }
    
    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "apple.intelligence")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            
            Text("Apple Intelligence Required")
                .font(.headline)
            
            Text(summarizationService.unavailableReason ?? "Summarization is not available.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    private func errorView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            
            Text("Unable to Generate Summary")
                .font(.headline)
            
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    private var generatePromptView: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.quote")
                .font(.system(size: 36))
                .foregroundStyle(.blue)
            
            Text("Ready to summarize")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    
    private var summaryContentView: some View {
        VStack(alignment: .leading, spacing: 12) {
            if summarizationService.isProcessing {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Generating...").font(.caption).foregroundStyle(.secondary)
                }
            }
            
            if !summarizationService.summary.isEmpty {
                Text(summarizationService.summary)
                    .font(.system(size: 14, design: .serif))
                    .lineSpacing(4)
                    .textSelection(.enabled)
            }
        }
    }
}
