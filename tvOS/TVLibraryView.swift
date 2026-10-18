import SwiftUI
import SwiftData

/// The Apple TV shelf. Books arrive from the Mac; there's nothing to import here.
struct TVLibraryView: View {
    @Binding var navigationPath: NavigationPath

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]

    private var receiver: BookReceiver { .shared }

    /// Most recently read first, then newest arrivals — the book you're in the middle of
    /// should be the first thing the remote lands on.
    private var shelf: [Book] {
        books.sorted {
            switch ($0.lastReadDate, $1.lastReadDate) {
            case let (left?, right?): return left > right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return $0.dateAdded > $1.dateAdded
            }
        }
    }

    var body: some View {
        Group {
            if books.isEmpty {
                emptyLibrary
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 56), count: 6),
                        alignment: .leading,
                        spacing: 64
                    ) {
                        ForEach(shelf) { book in
                            tile(for: book)
                        }
                    }
                    .padding(.vertical, 40)
                }
            }
        }
        .navigationTitle("LingoBook")
        .overlay(alignment: .topTrailing) { arrivalNotice }
    }

    private func tile(for book: Book) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { navigationPath.append(book) } label: {
                BookCover(book: book)
                    .aspectRatio(2/3, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.card)
            .contextMenu {
                Button(role: .destructive) {
                    withAnimation { modelContext.delete(book) }
                    try? modelContext.save()
                } label: {
                    Label("Remove from Apple TV", systemImage: "trash")
                }
            }
            .accessibilityLabel(book.accessibilityDescription)

            VStack(alignment: .leading, spacing: 4) {
                Text(book.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Text(book.lastReadDate != nil && book.readingProgress > 0
                     ? "\(book.progressPercent)% read"
                     : book.author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accessibilityHidden(true)
        }
    }

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No Books Yet", systemImage: "books.vertical")
        } description: {
            Text("""
            On your Mac, right-click a book in LingoBook and choose Send to Apple TV. \
            Your Mac translates it, then it appears here while this app is open.
            """)
        }
        .frame(maxWidth: 1100)
    }

    @ViewBuilder
    private var arrivalNotice: some View {
        if receiver.incoming > 0 {
            notice(systemImage: nil, text: "Receiving a book from your Mac…")
        } else if let title = receiver.lastArrival {
            notice(systemImage: "checkmark.circle.fill", text: "“\(title)” added")
        }
    }

    private func notice(systemImage: String?, text: String) -> some View {
        HStack(spacing: 16) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(.green)
            } else {
                ProgressView()
            }
            Text(text)
        }
        .font(.callout)
        .padding(.horizontal, 32)
        .padding(.vertical, 18)
        .background(.regularMaterial, in: Capsule())
        .transition(.opacity)
    }
}
