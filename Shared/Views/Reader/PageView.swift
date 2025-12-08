import SwiftUI

/// Single page of text content (used for both original and translated sides)
struct PageView: View {
    let paragraphs: [String]
    let isOriginal: Bool
    let chapterTitle: String
    let translatedChapterTitle: String
    let isFirstPage: Bool
    let fontSize: CGFloat
    let theme: BookTheme
    let isTranslating: Bool
    let onTranslate: (String) -> Void
    let onCopy: (String) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if paragraphs.isEmpty && !isOriginal && isTranslating {
                // Loading state for translation
                Spacer()
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                    Spacer()
                }
                Spacer()
            } else {
                // Page content
                VStack(alignment: .leading, spacing: 16) {
                    // Chapter heading on first page
                    if isFirstPage && !chapterTitle.isEmpty {
                        Text(isOriginal ? chapterTitle : translatedChapterTitle)
                            .font(.system(size: fontSize + 8, weight: .medium, design: .serif))
                            .foregroundStyle(theme.textColor)
                            .padding(.bottom, 8)
                    }
                    
                    // Paragraphs
                    ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, text in
                        Text(text)
                            .font(.system(size: fontSize, design: .serif))
                            .foregroundStyle(theme.textColor)
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .contextMenu {
                                if isOriginal {
                                    Button("Translate") {
                                        onTranslate(text)
                                    }
                                }
                                Button("Copy") {
                                    onCopy(text)
                                }
                            }
                    }
                    
                    Spacer()
                }
                .padding(.horizontal, 48)
                .padding(.vertical, 32)
            }
        }
    }
}

#Preview {
    PageView(
        paragraphs: ["This is a sample paragraph.", "And another one here."],
        isOriginal: true,
        chapterTitle: "Chapter 1",
        translatedChapterTitle: "Chapitre 1",
        isFirstPage: true,
        fontSize: 17,
        theme: .paper,
        isTranslating: false,
        onTranslate: { _ in },
        onCopy: { _ in }
    )
}
