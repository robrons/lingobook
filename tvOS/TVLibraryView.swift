import SwiftUI
import SwiftData

/// The Apple TV shelf, laid out like Books' library: the book you're reading up top, large,
/// with how far you've got; then every book as a cover with nothing under it but where you
/// stand with it. Books arrive from the Mac; there's nothing to import here.
struct TVLibraryView: View {
    @Binding var navigationPath: NavigationPath

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.dateAdded, order: .reverse) private var books: [Book]
    /// The book in All Books that has focus, so its caption can move with its cover.
    @FocusState private var focusedBook: UUID?

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

    /// The book to pick up where you left off, if you've started one.
    private var current: Book? {
        shelf.first { $0.lastReadDate != nil && $0.readingProgress > 0 && $0.readingProgress < 1 }
    }

    private static let columns = 6
    private static let gridSpacing: CGFloat = 48

    var body: some View {
        Group {
            if books.isEmpty {
                emptyLibrary
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 64) {
                        Text("Library")
                            .font(.system(size: 64, weight: .bold))

                        if let current {
                            continueReading(current)
                        }

                        VStack(alignment: .leading, spacing: 32) {
                            if current != nil {
                                Text("All Books")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            LazyVGrid(
                                columns: Array(
                                    repeating: GridItem(.flexible(), spacing: Self.gridSpacing, alignment: .bottom),
                                    count: Self.columns
                                ),
                                alignment: .leading,
                                spacing: 72
                            ) {
                                ForEach(shelf) { book in
                                    tile(for: book)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 40)
                }
                .scrollClipDisabled()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        #if DEBUG
        .task {
            let index = UserDefaults.standard.integer(forKey: "LBShelfFocus")
            guard index > 0, shelf.indices.contains(index - 1) else { return }
            try? await Task.sleep(for: .milliseconds(500))
            focusedBook = shelf[index - 1].id
        }
        #endif
        .overlay(alignment: .topTrailing) { arrivalNotice }
        .animation(.easeOut(duration: 0.3), value: receiver.incoming)
        .animation(.easeOut(duration: 0.3), value: receiver.lastArrival)
    }

    // MARK: - Continue Reading

    /// Books' "Continue": the current book, large, with how far you've got.
    private func continueReading(_ book: Book) -> some View {
        HStack(alignment: .bottom, spacing: 64) {
            Button { navigationPath.append(book) } label: {
                CoverArt(book: book, width: 260)
            }
            .buttonStyle(.borderless)
            .contextMenu { removeButton(for: book) }
            .accessibilityLabel("Continue reading \(book.accessibilityDescription)")

            VStack(alignment: .leading, spacing: 14) {
                Text("Continue Reading")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(book.title)
                    .font(.system(size: 52, weight: .bold))
                    .lineLimit(2)
                Text(book.author)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 20) {
                    ProgressView(value: book.readingProgress)
                        .frame(width: 360)
                    Text("\(book.progressPercent)%")
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 18)
            }
            .padding(.bottom, 24)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Shelf

    /// A cover, and under it only what Books shows: how far you've got, or that it's new.
    /// The borderless style lifts the cover and moves its caption with it, as the TV app's
    /// posters do — so the two never fall out of line when focus arrives.
    private func tile(for book: Book) -> some View {
        let isFocused = focusedBook == book.id
        return Button { navigationPath.append(book) } label: {
            VStack(alignment: .leading, spacing: 16) {
                CoverArt(book: book, width: nil)
                // One height for every caption — a "NEW" pill is taller than "13%", and
                // with mixed heights the grid set some covers higher than others.
                status(for: book)
                    .frame(height: 36, alignment: .leading)
                    // The focused cover grows; its caption steps down to stay clear of it,
                    // as a poster's title does in the TV app.
                    .offset(y: isFocused ? 22 : 0)
                    .animation(.easeOut(duration: 0.2), value: isFocused)
            }
        }
        .buttonStyle(.borderless)
        .focused($focusedBook, equals: book.id)
        .contextMenu { removeButton(for: book) }
        .accessibilityLabel(book.accessibilityDescription)
    }

    @ViewBuilder
    private func status(for book: Book) -> some View {
        if book.readingProgress >= 1 {
            Text("Finished")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        } else if book.lastReadDate != nil && book.readingProgress > 0 {
            Text("\(book.progressPercent)%")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        } else {
            Text("NEW")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.blue, in: Capsule())
        }
    }

    private func removeButton(for book: Book) -> some View {
        Button(role: .destructive) {
            withAnimation { modelContext.delete(book) }
            try? modelContext.save()
        } label: {
            Label("Remove from Apple TV", systemImage: "trash")
        }
    }

    // MARK: - Empty and arrivals

    private var emptyLibrary: some View {
        ContentUnavailableView {
            Label("No Books Yet", systemImage: "books.vertical")
        } description: {
            Text("""
            On your Mac, right-click a book in LingoBook and choose Send to Apple TV. \
            It appears here while this app is open.
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

/// A cover in a uniform 2:3 frame. Real covers vary a little in shape, and showing each at
/// its own proportions left a shelf of mismatched heights — uneven rather than bookish.
private struct CoverArt: View {
    let book: Book
    /// Fixed width, or nil to fill the grid column.
    let width: CGFloat?

    var body: some View {
        Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay { BookCover(book: book) }
            .frame(width: width)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            // The borderless button lifts only an `Image` in its label, and a generated
            // cover is shapes and text — so focus on a coverless book was invisible.
            // Marking the cover itself gives every book the same lift and sheen.
            .hoverEffect(.highlight)
    }
}
