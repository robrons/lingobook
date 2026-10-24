import SwiftUI

/// Contents, as Apple TV lays it out: a panel down the left of the page, the book's cover
/// and title at its head, opened on the chapter you're reading.
struct TOCSheet: View {
    let book: Book
    let titles: [String]
    let currentIndex: Int
    let theme: BookTheme
    let onSelect: (Int) -> Void

    static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                BookCover(book: book)
                    .aspectRatio(2/3, contentMode: .fill)
                    .frame(width: 44, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(book.title)
                        .font(.system(size: 16, weight: .bold))
                        .lineLimit(2)
                    Text(book.author)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding([.top, .horizontal], 22)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(titles.indices, id: \.self) { index in
                            Button {
                                onSelect(index)
                            } label: {
                                HStack(spacing: 12) {
                                    Text(titles[index])
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    if index == currentIndex {
                                        Text("Reading")
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(PanelRowButtonStyle(alignment: .leading, isSelected: index == currentIndex))
                            .id(index)
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 22)
                }
                .scrollIndicators(.never)
                .onAppear {
                    proxy.scrollTo(currentIndex, anchor: .center)
                }
            }
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 6)
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
}
