import SwiftUI

/// Holds one conversation with the tutor about the book being read.
///
/// Deliberately separate from `ReaderViewModel`: the tutor is a guest in the reader,
/// not part of it. Nothing here can renumber a page or move the reader's place.
@MainActor
@Observable
final class TutorPanelModel {

    var messages: [TutorMessage] = []
    var draft = ""
    var isResponding = false
    var errorMessage: String?

    /// Collapsed to just its title bar. Kept here rather than in the view so the panel
    /// reopens the way it was left.
    var isMinimized = false

    /// Displacement from the panel's resting corner, in points. Also here so dragging
    /// the card somewhere useful survives closing and reopening it.
    var position: CGSize = .zero

    /// The page the last question was asked about, so a page turn can be marked.
    private var lastPageID: String?

    private let tutor: any TutorService
    private var streamTask: Task<Void, Never>?

    init(tutor: any TutorService = OllamaTutor()) {
        self.tutor = tutor
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isResponding
    }

    func send(context: TutorContext) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isResponding else { return }

        draft = ""
        errorMessage = nil
        // History excludes the question being asked — the service appends it itself.
        let history = messages

        // Say so in the transcript when the book has moved on since the last question,
        // so an answer that leans on the earlier page is legible rather than baffling.
        if let lastPageID, lastPageID != context.pageID, !messages.isEmpty {
            messages.append(TutorMessage(role: .note, text: "Turned to a new page"))
        }
        lastPageID = context.pageID

        messages.append(TutorMessage(role: .reader, text: question))

        let reply = TutorMessage(role: .tutor, text: "")
        messages.append(reply)
        isResponding = true

        streamTask = Task { [tutor] in
            do {
                for try await piece in tutor.stream(
                    question: question, context: context, history: history
                ) {
                    guard let index = messages.firstIndex(where: { $0.id == reply.id }) else { return }
                    messages[index].text += piece
                }
            } catch {
                errorMessage = error.localizedDescription
                // Drop the empty shell rather than leaving a blank bubble behind.
                if let index = messages.firstIndex(where: { $0.id == reply.id }),
                   messages[index].text.isEmpty {
                    messages.remove(at: index)
                }
            }
            isResponding = false
        }
    }

    func stop() {
        streamTask?.cancel()
        isResponding = false
    }

    func clear() {
        stop()
        messages.removeAll()
        errorMessage = nil
    }
}

/// The tutor's floating panel: ask about the page you're on, in plain language.
struct TutorPanel: View {

    @Bindable var model: TutorPanelModel
    let theme: BookTheme
    let context: TutorContext
    let onClose: () -> Void
    /// Non-nil while the reader is holding space to dictate.
    var listeningStatus: String?
    /// Speaks a reply aloud on demand — playback is never automatic.
    var onSpeak: ((String) -> Void)?

    /// Live drag, discarded when the gesture ends — the committed value moves to
    /// `model.position` so it outlives the gesture.
    @GestureState private var dragTranslation: CGSize = .zero

    private static let expandedHeight: CGFloat = 480

    var body: some View {
        VStack(spacing: 0) {
            header

            if !model.isMinimized {
                Divider()

                if model.messages.isEmpty {
                    emptyState
                } else {
                    transcript
                }

                if let errorMessage = model.errorMessage {
                    errorNotice(errorMessage)
                }

                Divider()

                composer
            }
        }
        .frame(height: model.isMinimized ? nil : Self.expandedHeight)
        // Material rather than the page colour: this card sits *above* the text, and
        // needs to read as floating rather than as a torn-off piece of the page.
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(theme.textColor.opacity(0.12))
        )
        .shadow(color: .black.opacity(0.28), radius: 22, y: 8)
        .offset(
            x: model.position.width + dragTranslation.width,
            y: model.position.height + dragTranslation.height
        )
    }

    // MARK: - Header (also the drag handle)

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .foregroundStyle(theme.textColor.opacity(0.6))

            Text("Tutor")
                .font(.headline)
                .foregroundStyle(theme.textColor)

            Spacer()

            if !model.messages.isEmpty && !model.isMinimized {
                Button("Clear", action: model.clear)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(theme.textColor.opacity(0.6))
            }

            iconButton(
                model.isMinimized ? "chevron.up" : "minus",
                help: model.isMinimized ? "Expand" : "Minimise",
                label: model.isMinimized ? "Expand tutor" : "Minimise tutor"
            ) {
                withAnimation(.easeOut(duration: 0.18)) { model.isMinimized.toggle() }
            }

            iconButton("xmark", help: "Close", label: "Close tutor", action: onClose)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // The grab area sits *behind* the controls rather than wrapping them. Wrapping
        // meant the drag gesture and the buttons competed for the same click: hold
        // perfectly still and the button won, twitch a pixel and the drag claimed it
        // and swallowed the tap. Behind, a click on a button is simply a click on the
        // button, and everything else falls through to the handle.
        .background(
            Color.clear
                .contentShape(Rectangle())
                .gesture(dragGesture)
        )
    }

    /// A header button with a hit target the size of the button, not the size of the glyph.
    ///
    /// `.buttonStyle(.plain)` takes its clickable region from the rendered shape, which
    /// for `minus` is a horizontal sliver two points tall — so clicks mostly sailed past
    /// it into the drag handle behind, and minimise appeared broken while the fatter
    /// `xmark` next to it worked fine. The explicit frame plus `contentShape` gives every
    /// icon the same honest 22pt square to aim at.
    private func iconButton(
        _ symbol: String,
        help: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .foregroundStyle(theme.textColor.opacity(0.6))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }

    private var dragGesture: some Gesture {
        // `.global`, not the default local space. Locally, translation is measured
        // against a view that this very gesture is moving — each frame shifts the
        // origin the next event is measured from, so the card chases the cursor and
        // judders. Global coordinates don't move under it.
        // 6pt rather than 1: a click is never perfectly still, and at 1pt the hand
        // tremor in an ordinary click registered as a drag.
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .updating($dragTranslation) { value, state, _ in
                state = value.translation
            }
            .onEnded { value in
                // Clamped so the card can't be thrown off-screen and stranded there.
                // It rests in the bottom-right corner, so travel is leftward and upward.
                model.position.width = min(40, max(-1100, model.position.width + value.translation.width))
                model.position.height = min(40, max(-760, model.position.height + value.translation.height))
            }
    }

    // MARK: - Body states

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()

            Image(systemName: "character.book.closed")
                .font(.system(size: 26))
                .foregroundStyle(theme.textColor.opacity(0.25))

            Text("Ask about this page")
                .font(.callout)
                .foregroundStyle(theme.textColor.opacity(0.6))

            Text("“What's quinquina, and why is she making it?”")
                .font(.caption)
                .italic()
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.textColor.opacity(0.4))

            Text("Hold space to speak")
                .font(.caption2)
                .foregroundStyle(theme.textColor.opacity(0.35))
                .padding(.top, 2)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.messages) { message in
                        bubble(for: message)
                            .id(message.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: model.messages.last?.text) {
                guard let last = model.messages.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(for message: TutorMessage) -> some View {
        if message.isNote {
            HStack(spacing: 8) {
                Rectangle().frame(height: 1).opacity(0.12)
                Text(message.text)
                    .font(.caption2)
                    .fixedSize()
                Rectangle().frame(height: 1).opacity(0.12)
            }
            .foregroundStyle(theme.textColor.opacity(0.45))
        } else {
            exchange(message)
        }
    }

    private func exchange(_ message: TutorMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role == .reader ? "You" : "Tutor")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.textColor.opacity(0.45))

            if message.text.isEmpty && model.isResponding {
                // The model can take a few seconds to produce its first token.
                ProgressView()
                    .controlSize(.small)
            } else if message.role == .reader {
                // The reader's own words go through verbatim — nothing to interpret.
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(theme.textColor.opacity(0.75))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                MarkdownText(raw: message.text)
                    .font(.callout)
                    .foregroundStyle(theme.textColor)
                    .textSelection(.enabled)

                if let onSpeak, !model.isResponding || message.id != model.messages.last?.id {
                    Button {
                        onSpeak(Self.spoken(message.text))
                    } label: {
                        Label("Read aloud", systemImage: "speaker.wave.2")
                            .labelStyle(.iconOnly)
                            .font(.caption)
                            .foregroundStyle(theme.textColor.opacity(0.45))
                            .frame(width: 22, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Read this aloud")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text(message)
                .font(.caption)
                .foregroundStyle(theme.textColor.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.textColor.opacity(0.05))
    }

    // MARK: - Composer

    /// Markdown read aloud is a mess of "asterisk asterisk", so strip the markup and
    /// speak the words. `AttributedString` already knows how to do this correctly.
    private static func spoken(_ raw: String) -> String {
        raw.components(separatedBy: .newlines).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let attributed = try? AttributedString(
                markdown: trimmed,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) else { return trimmed }
            return String(attributed.characters)
        }
        .joined(separator: "\n")
    }

    private var composer: some View {
        VStack(spacing: 6) {
            if let listeningStatus {
                HStack(spacing: 6) {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: true)
                    Text(listeningStatus)
                    Spacer()
                }
                .font(.caption)
                .foregroundStyle(theme.textColor.opacity(0.7))
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            composerRow
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var composerRow: some View {
        HStack(spacing: 8) {
            TextField(
                model.draft.isEmpty ? "Hold space to speak, or type…" : "Ask about this page…",
                text: $model.draft,
                axis: .vertical
            )
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .font(.callout)
                .foregroundStyle(theme.textColor)
                .onSubmit { model.send(context: context) }

            if model.isResponding {
                Button(action: model.stop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title3)
                        .foregroundStyle(theme.textColor.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop")
            } else {
                Button {
                    model.send(context: context)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title3)
                        .foregroundStyle(model.canSend ? Color.accentColor : theme.textColor.opacity(0.25))
                }
                .buttonStyle(.plain)
                .disabled(!model.canSend)
                .accessibilityLabel("Ask")
            }
        }
    }
}

// MARK: - Markdown

/// Renders the small slice of Markdown a chat model actually emits.
///
/// SwiftUI's `Text` will parse *inline* Markdown from an `AttributedString` — bold,
/// italic, code — but knows nothing about block structure, so a numbered list arrives
/// as one run-on paragraph with its asterisks showing. This splits the reply into
/// paragraphs and list items first, then hands each line's inline markup to
/// `AttributedString`. Anything it doesn't recognise falls through as plain text,
/// which is the right failure: a stray asterisk beats a blank bubble.
private struct MarkdownText: View {

    let raw: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    inline(text)
                        .fixedSize(horizontal: false, vertical: true)

                case .item(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker)
                            .monospacedDigit()
                        inline(text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Block {
        case paragraph(String)
        case item(marker: String, text: String)
    }

    /// Parsed replies, kept between renders.
    ///
    /// A drag re-evaluates this view on every mouse event, and re-splitting every
    /// message in the transcript each time was the other half of the judder. The reply
    /// text is a perfectly good cache key: while dragging it isn't changing at all, and
    /// while streaming only the last message's entry is ever missed.
    @MainActor private static var cache: [String: [Block]] = [:]

    private var blocks: [Block] {
        if let hit = Self.cache[raw] { return hit }
        let parsed = parse()
        if Self.cache.count > 512 { Self.cache.removeAll(keepingCapacity: true) }
        Self.cache[raw] = parsed
        return parsed
    }

    private func parse() -> [Block] {
        var out: [Block] = []
        var pending: [String] = []

        func flushParagraph() {
            let joined = pending.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !joined.isEmpty { out.append(.paragraph(joined)) }
            pending.removeAll()
        }

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                flushParagraph()
            } else if let item = listItem(trimmed) {
                flushParagraph()
                out.append(.item(marker: item.marker, text: item.text))
            } else {
                pending.append(trimmed)
            }
        }

        flushParagraph()
        return out
    }

    /// A leading `1.` or `-` marker, if the line opens a list item.
    ///
    /// The bullet pattern requires whitespace after the marker, which is what keeps a
    /// line beginning `**Hougomont**` from being mistaken for a `*` bullet.
    private func listItem(_ line: String) -> (marker: String, text: String)? {
        if let range = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            return (String(line[range]).trimmingCharacters(in: .whitespaces),
                    String(line[range.upperBound...]))
        }
        if let range = line.range(of: #"^[-*•]\s+"#, options: .regularExpression) {
            return ("•", String(line[range.upperBound...]))
        }
        return nil
    }

    private func inline(_ text: String) -> Text {
        guard let attributed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return Text(text)
        }
        return Text(attributed)
    }
}
