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

/// The tutor's side panel: ask about the page you're on, in plain language.
struct TutorPanel: View {

    @Bindable var model: TutorPanelModel
    let theme: BookTheme
    let context: TutorContext
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

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
        .background(theme.pageColor)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .foregroundStyle(theme.textColor.opacity(0.6))

            Text("Tutor")
                .font(.headline)
                .foregroundStyle(theme.textColor)

            Spacer()

            if !model.messages.isEmpty {
                Button("Clear", action: model.clear)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(theme.textColor.opacity(0.6))
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .foregroundStyle(theme.textColor.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close tutor")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

            Text("“Why « resta » and not « restait » ?”")
                .font(.caption)
                .italic()
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.textColor.opacity(0.4))

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

    private func bubble(for message: TutorMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role == .reader ? "You" : "Tutor")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(theme.textColor.opacity(0.45))

            if message.text.isEmpty && model.isResponding {
                // The model can take a few seconds to produce its first token.
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(theme.textColor.opacity(message.role == .reader ? 0.75 : 1))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
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

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask about this page…", text: $model.draft, axis: .vertical)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
