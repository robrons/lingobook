import SwiftUI

/// Ask on the Mac and iPad: questions about the page on screen, answered by Claude.
///
/// The same conversation as Apple TV's Ask — three ready-made questions, anything else
/// typed (or dictated with the system's own dictation), web search for typed questions
/// only. It sits beside the page rather than over it, so the text being asked about is
/// never the text it hides; the page simply lays itself out a little narrower.
struct AskPanel: View {
    let conversation: AskConversation
    let theme: BookTheme
    /// The page as it is at the moment of asking — read then, not when the panel opened.
    let context: () -> PageContext?
    let onClose: () -> Void

    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    static let width: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            transcript

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                suggestions
                field
            }
            .padding(14)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.textColor.opacity(0.1))
                .frame(width: 1)
        }
        // Follows the page, as the AA popover does: Night stays night.
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Ask")
                .font(.system(size: 17, weight: .semibold))
            Text("About this page · Claude")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close Ask")
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if conversation.isEmpty {
                        Text("Ask about the people, the words, or what's going on. Claude sees this chapter up to the page you're on, and won't tell you what comes next.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(conversation.entries) { entry in
                        AskEntryView(entry: entry)
                            .id(entry.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
            }
            .frame(maxHeight: .infinity)
            // A new question goes to the top, so its answer is read from its first line.
            .onChange(of: conversation.entries.count) { _, _ in
                guard let question = latestQuestion else { return }
                withAnimation { proxy.scrollTo(question.id, anchor: .top) }
            }
            // Until the answer is long enough there's nothing below the question to scroll
            // into, so it stops short of the top. Keep lifting it while the answer arrives.
            .onChange(of: conversation.entries.last?.text) { _, _ in
                guard conversation.isAnswering, let question = latestQuestion else { return }
                proxy.scrollTo(question.id, anchor: .top)
            }
        }
    }

    private var latestQuestion: AskConversation.Entry? {
        conversation.entries.last(where: { $0.role == .reader })
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(AskConversation.suggestions) { suggestion in
                Button {
                    guard let context = context() else { return }
                    conversation.ask(suggestion, about: context)
                } label: {
                    Label(suggestion.label, systemImage: suggestion.systemImage)
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(conversation.isAnswering)
            }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            TextField("Ask anything about this page…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .focused($fieldFocused)
                .onSubmit(send)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            if conversation.isAnswering {
                Button { conversation.stop() } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Stop answering")
            } else {
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                }
                .buttonStyle(.plain)
                .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.accentColor)
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityLabel("Ask")
            }
        }
        .task { fieldFocused = true }
    }

    private func send() {
        let question = draft
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !conversation.isAnswering,
              let context = context() else { return }
        draft = ""
        conversation.ask(question, about: context)
    }
}

private struct AskEntryView: View {
    let entry: AskConversation.Entry

    var body: some View {
        switch entry.role {
        case .reader:
            Text(entry.text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .multilineTextAlignment(.trailing)
        case .claude where entry.text.isEmpty:
            status(entry.isSearching ? "Searching the web…" : "Reading the page…")
        case .claude:
            VStack(alignment: .leading, spacing: 10) {
                Text(AskConversation.styled(entry.text))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if entry.isSearching {
                    status("Searching the web…")
                }
                if !entry.sources.isEmpty {
                    sources(entry.sources)
                }
            }
        case .problem:
            Label(entry.text, systemImage: "exclamationmark.triangle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func status(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 13))
    }

    /// Where a web answer came from. Unlike on a television, these open.
    private func sources(_ sources: [Claude.Source]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Sources", systemImage: "globe")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(sources.prefix(4), id: \.url) { source in
                if let url = URL(string: source.url) {
                    Link(destination: url) {
                        Text("\(source.title) — \(source.site)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 11))
                }
            }
        }
    }
}
