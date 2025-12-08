import SwiftUI

/// Table of Contents sheet (Apple Books style)
struct TOCSheet: View {
    let tableOfContents: [EPUBService.TOCItem]
    let chapters: [EPUBService.Chapter]
    let currentChapterIndex: Int
    let onSelect: (Int) -> Void
    let onDismiss: () -> Void
    
    // Apple Books warm cream background
    private let warmBackground = Color(red: 0.976, green: 0.957, blue: 0.922)
    private let selectionColor = Color(red: 0.92, green: 0.89, blue: 0.84)
    private let textColor = Color(red: 0.2, green: 0.18, blue: 0.15)
    
    private func chapterIndex(for tocItem: EPUBService.TOCItem) -> Int? {
        chapters.firstIndex { ch in
            ch.href.contains(tocItem.href) || tocItem.href.contains(ch.href)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(textColor.opacity(0.5))
                        .frame(width: 28, height: 28)
                        .background(textColor.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                
                Spacer()
                
                Text("Contents")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textColor.opacity(0.6))
                
                Spacer()
                
                Color.clear.frame(width: 28, height: 28)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)
            
            Rectangle()
                .fill(textColor.opacity(0.1))
                .frame(height: 0.5)
            
            // TOC List
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(tableOfContents, id: \.id) { tocItem in
                            let idx = chapterIndex(for: tocItem)
                            let isSelected = idx == currentChapterIndex
                            let isPartHeader = tocItem.level == 0 && tocItem.label.lowercased().contains("part")
                            
                            Button {
                                if let idx = idx {
                                    onSelect(idx)
                                }
                            } label: {
                                Text(tocItem.label)
                                    .font(.system(
                                        size: 14,
                                        weight: isPartHeader ? .semibold : (isSelected ? .medium : .regular)
                                    ))
                                    .foregroundStyle(textColor)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.leading, CGFloat(tocItem.level) * 16 + 16)
                                    .padding(.trailing, 16)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(isSelected ? selectionColor : Color.clear)
                                            .padding(.horizontal, 8)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(tocItem.id)
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onAppear {
                    if let currentItem = tableOfContents.first(where: { chapterIndex(for: $0) == currentChapterIndex }) {
                        proxy.scrollTo(currentItem.id, anchor: .center)
                    }
                }
            }
        }
        .background(warmBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .frame(minWidth: 320, idealWidth: 350, minHeight: 500, idealHeight: 600)
    }
}
