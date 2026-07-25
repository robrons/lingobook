import SwiftUI

// NOTE: this file still carries its old name so the Xcode project doesn't need editing.
// `PageNavigator` (Previous/Next buttons) has been replaced by `ReaderScrubber`.
// Renaming the file to ReaderScrubber.swift in Xcode is a safe follow-up.

/// Bottom chrome: a thin scrubber plus two quiet labels.
///
/// Replaces the old Previous/Next buttons. Paging is what the edges, arrow keys and
/// swipes are for; this exists to tell you where you are and to let you jump.
struct ReaderScrubber: View {
    /// Zero-based page within the current chapter.
    let currentPage: Int
    let totalPages: Int
    /// Progress through the whole book, 0…1.
    let bookProgress: Double
    let pagesLeftInChapter: Int
    let theme: BookTheme
    /// Commits a new zero-based page index. Called once, on release.
    let onScrub: (Int) -> Void

    /// Non-nil only while a drag is in flight, so the thumb follows the finger without
    /// repaginating or re-translating on every frame.
    @State private var dragFraction: Double?

    private let trackHeight: CGFloat = 3
    private let thumbSize: CGFloat = 11

    private var currentFraction: Double {
        guard totalPages > 1 else { return 0 }
        return Double(currentPage) / Double(totalPages - 1)
    }

    private var displayFraction: Double {
        dragFraction ?? currentFraction
    }

    private func page(for fraction: Double) -> Int {
        guard totalPages > 1 else { return 0 }
        let raw = (fraction * Double(totalPages - 1)).rounded()
        return min(max(Int(raw), 0), totalPages - 1)
    }

    private var trailingLabel: String {
        if let dragFraction {
            return "Page \(page(for: dragFraction) + 1) of \(max(1, totalPages))"
        }
        switch pagesLeftInChapter {
        case 0: return "Last page in this chapter"
        case 1: return "1 page left in this chapter"
        default: return "\(pagesLeftInChapter) pages left in this chapter"
        }
    }

    var body: some View {
        VStack(spacing: 7) {
            track

            HStack {
                Text("\(Int((bookProgress * 100).rounded()))%")
                Spacer(minLength: 12)
                Text(trailingLabel)
                    .lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.textColor.opacity(0.4))
            .monospacedDigit()
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = displayFraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.textColor.opacity(0.15))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(theme.textColor.opacity(0.35))
                    .frame(width: max(0, width * fraction), height: trackHeight)

                Circle()
                    .fill(theme.textColor.opacity(0.7))
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: thumbOffset(width: width, fraction: fraction))
                    .animation(dragFraction == nil ? .easeOut(duration: 0.2) : nil, value: fraction)
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(
                // minimumDistance 0 so a plain tap on the track also jumps.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragFraction = clamped(value.location.x / max(width, 1))
                    }
                    .onEnded { value in
                        let target = page(for: clamped(value.location.x / max(width, 1)))
                        dragFraction = nil
                        onScrub(target)
                    }
            )
            .disabled(totalPages <= 1)
        }
        .frame(height: 22)
    }

    /// Keeps the thumb inside the track at both ends instead of hanging off the edge.
    private func thumbOffset(width: CGFloat, fraction: Double) -> CGFloat {
        let travel = max(0, width - thumbSize)
        return travel * fraction
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// The only thing left when the chrome fades: a 2pt sliver of book progress along the
/// very bottom edge. Enough to orient you, quiet enough to forget.
struct ReaderProgressHairline: View {
    let progress: Double
    let theme: BookTheme

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(theme.textColor.opacity(0.2))
                .frame(width: geometry.size.width * min(max(progress, 0), 1), height: 2)
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

#Preview {
    VStack {
        Spacer()
        ReaderScrubber(
            currentPage: 4,
            totalPages: 42,
            bookProgress: 0.42,
            pagesLeftInChapter: 37,
            theme: .calm,
            onScrub: { _ in }
        )
    }
    .background(BookTheme.calm.pageColor)
}
