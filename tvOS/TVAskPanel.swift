import SwiftUI
import UIKit

/// Ask: questions about the page on screen, answered by Claude.
///
/// A panel down the right, like Themes & Settings, so the page it's about stays in view.
/// Three questions are ready to click, since typing on a television is a chore; anything
/// else goes in the field below them, where the Siri Remote's microphone dictates.
///
/// The answers are read in a mode of their own. Moving up from the buttons enters it; then
/// the touch surface scrolls the text like a page under the thumb, and nothing else in
/// the panel can take focus, so a swipe can't fling you out of what you're reading.
/// Clicking down returns to the buttons, and Back closes the panel.
struct TVAskPanel: View {
    let conversation: AskConversation
    let theme: BookTheme
    /// Set while the answers are being read, so the reader can take the top bar out of
    /// reach of a swipe too.
    @Binding var isReading: Bool
    /// The page as it is at the moment of asking — read then, not when the panel opened.
    let context: () -> PageContext?

    @State private var draft = ""
    @FocusState private var focus: Field?
    @State private var position = ScrollPosition()
    @State private var offset: CGFloat = 0
    @State private var maxOffset: CGFloat = 0
    /// Where the text was when the thumb went down.
    @State private var swipeStart: CGFloat?
    /// Set once dictation has put words in the field; sends them after a pause.
    @State private var dictationSend: Task<Void, Never>?

    private enum Field: Hashable {
        case suggestion(String)
        case answers
        case field
    }

    /// How far the text moves for the remote's travel. A swipe across half the surface
    /// reports about 1,100; this carries it about a panel's height. The text follows the
    /// thumb, as on a touchscreen: swipe up to read on.
    private static let scrollRate: CGFloat = 0.5

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(alignment: .firstTextBaseline) {
                Text("Ask")
                    .font(.system(size: 30, weight: .bold))
                Spacer()
                Text(isReading ? "Swipe to scroll · Click down to ask more" : "About this page · Claude")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            transcript

            // Not disabled while an answer comes in — tvOS moves focus off a button that
            // goes disabled, and `ask` ignores a question asked mid-answer anyway. Only
            // while reading, when focus is on the answers and must stay there.
            HStack(spacing: 16) {
                ForEach(AskConversation.suggestions) { suggestion in
                    Button {
                        guard let context = context() else { return }
                        conversation.ask(suggestion, about: context)
                    } label: {
                        Label(suggestion.label, systemImage: suggestion.systemImage)
                            .font(.system(size: 24, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .buttonStyle(PanelButtonStyle(theme: theme))
                    .focused($focus, equals: .suggestion(suggestion.id))
                    .disabled(isReading)
                }
            }

            TextField("Ask anything about this page…", text: $draft)
                .font(.system(size: 26))
                .focused($focus, equals: .field)
                .disabled(isReading)
                .onSubmit(send)
                .onChange(of: draft) { old, new in
                    noteDictation(from: old, to: new)
                }
        }
        .padding(44)
        .frame(width: 1000)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .focusSection()
        .task {
            // One click from the question most often wanted.
            focus = .suggestion(AskConversation.suggestions[0].id)
            #if DEBUG
            // `-LBDictate "phrase"`: puts the phrase in the field after a few seconds, as
            // dictation would, for trying the auto-send without a microphone.
            if let phrase = UserDefaults.standard.string(forKey: "LBDictate") {
                try? await Task.sleep(for: .seconds(15))
                draft = phrase
            }
            #endif
        }
        .onChange(of: focus) { _, newValue in
            isReading = newValue == .answers
        }
        .onDisappear { isReading = false }
        .background {
            RemoteSwipes(isEnabled: isReading) { event in
                handle(event)
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if conversation.isEmpty {
                    Text("Ask about the people, the words, or what's going on. Claude sees this chapter up to the page you're on, and won't tell you what comes next.")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(conversation.entries) { entry in
                    EntryView(entry: entry)
                        .id(entry.id)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: [CGFloat].self) { geometry in
            [geometry.contentOffset.y, geometry.contentSize.height - geometry.containerSize.height]
        } action: { _, values in
            offset = values[0]
            maxOffset = max(0, values[1])
        }
        .frame(maxHeight: .infinity)
        // One focusable region, not one per line: on tvOS focus moving is the only thing
        // that scrolls, and an answer is a page of text, not a list of things to pick.
        .focusable(!conversation.isEmpty)
        .focused($focus, equals: .answers)
        .focusEffectDisabled()
        // A click on the clickpad's lower edge leaves. Swipes don't arrive as move
        // commands, so scrolling down can't throw you out. (`RemoteSwipes` hears the
        // same click from the remote directly; leaving twice lands in the same place.)
        .onMoveCommand { direction in
            if direction == .down { leaveAnswers() }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(isReading ? 0.35 : 0), lineWidth: 3)
                .animation(.easeOut(duration: 0.18), value: isReading)
        }
        // A new question goes to the top, so its answer is read from its first line.
        // Through the reader's proxy, not `position`: setting `position` to the id it
        // already holds is no change, so it wouldn't lift the question again as the
        // answer grows beneath it.
        .onChange(of: conversation.entries.count) { _, _ in
            guard let question = latestQuestion else { return }
            withAnimation { proxy.scrollTo(question.id, anchor: .top) }
        }
        // Until the answer is long enough there's nothing below the question to scroll
        // into, so it stops short of the top. Keep lifting it while the answer arrives.
        .onChange(of: conversation.entries.last?.text) { _, _ in
            guard conversation.isAnswering, swipeStart == nil, let question = latestQuestion else { return }
            proxy.scrollTo(question.id, anchor: .top)
        }
        }
    }

    private var latestQuestion: AskConversation.Entry? {
        conversation.entries.last(where: { $0.role == .reader })
    }

    private func handle(_ event: RemoteSwipes.Event) {
        switch event {
        case .moved(let travel):
            let start = swipeStart ?? offset
            swipeStart = start
            position.scrollTo(y: clamped(start - travel * Self.scrollRate))
        case .ended(let travel, let velocity):
            // A flick carries on a little, as a scroll view does under a finger.
            let start = swipeStart ?? offset
            swipeStart = nil
            let target = clamped(start - (travel + velocity * 0.12) * Self.scrollRate)
            withAnimation(.easeOut(duration: 0.35)) { position.scrollTo(y: target) }
        case .clickedDown:
            leaveAnswers()
        }
    }

    /// Back to the buttons. They're disabled while reading, and focus can't land on a
    /// disabled button — so enable them first, and move focus once that has taken.
    private func leaveAnswers() {
        guard isReading else { return }
        isReading = false
        Task { focus = .suggestion(AskConversation.suggestions[0].id) }
    }

    private func send() {
        dictationSend?.cancel()
        let question = draft
        draft = ""
        guard let context = context() else { return }
        conversation.ask(question, about: context)
    }

    // MARK: - Dictation

    /// Sends a dictated question without a trip to Done.
    ///
    /// Dictation arrives in words and phrases; the keyboard types a letter at a time. So
    /// a change that adds a word or more at once is the microphone, and once it has been
    /// quiet for a moment the question is finished: send it and close the keyboard, and
    /// the answer is already on its way when the panel comes back. Typing is never sent
    /// early — it still ends with Done.
    private func noteDictation(from old: String, to new: String) {
        let added = new.count - old.count
        let isDictation = added >= 4 && new.hasPrefix(old.trimmingCharacters(in: .whitespaces))
        guard isDictation || dictationSend != nil else { return }
        dictationSend?.cancel()
        guard !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            dictationSend = nil
            return
        }
        dictationSend = Task {
            try? await Task.sleep(for: Self.dictationPause)
            guard !Task.isCancelled else { return }
            dictationSend = nil
            Self.closeKeyboard()
            // Focus stays on the field: one click and the next question can be dictated.
            send()
        }
    }

    /// Long enough for a breath between phrases, short enough not to feel like waiting.
    private static let dictationPause: Duration = .seconds(1.5)

    /// The tvOS keyboard is a full-screen controller of its own; ending editing takes it
    /// down, and anything still presented over the window is dismissed.
    private static func closeKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first
        window?.rootViewController?.presentedViewController?.dismiss(animated: true)
    }

    private func clamped(_ y: CGFloat) -> CGFloat {
        min(max(0, y), maxOffset)
    }
}

private struct EntryView: View {
    let entry: AskConversation.Entry

    var body: some View {
        switch entry.role {
        case .reader:
            Text(entry.text)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .claude where entry.text.isEmpty:
            status(entry.isSearching ? "Searching the web…" : "Reading the page…")
        case .claude:
            VStack(alignment: .leading, spacing: 16) {
                Text(AskConversation.styled(entry.text))
                    .font(.system(size: 28))
                    .lineSpacing(6)
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
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func status(_ label: String) -> some View {
        HStack(spacing: 14) {
            ProgressView()
            Text(label)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 28))
    }

    /// Where a web answer came from. Sites, not links: nothing on a television opens them,
    /// but "en.wikipedia.org" against a date says how far to trust it.
    private func sources(_ sources: [Claude.Source]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Sources", systemImage: "globe")
                .font(.system(size: 20, weight: .semibold))
            ForEach(sources.prefix(4), id: \.url) { source in
                Text("\(source.title) — \(source.site)")
                    .font(.system(size: 20))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(.secondary)
    }
}

/// The Siri Remote's touch surface and its down click, read straight from the window
/// while the answers are being read — the same way the reader reads page turns.
///
/// The focus engine would otherwise read a swipe as "move focus", and there is nothing to
/// move to while reading; this sees the thumb move from the first point instead.
private struct RemoteSwipes: UIViewRepresentable {
    enum Event {
        /// The thumb has moved this far up or down since it touched down.
        case moved(CGFloat)
        /// It lifted: how far it went, and how fast it was moving.
        case ended(CGFloat, velocity: CGFloat)
        /// The bottom edge of the clickpad, pressed.
        case clickedDown
    }

    var isEnabled: Bool
    var onEvent: (Event) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.coordinator = context.coordinator
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: SurfaceView, context: Context) {
        context.coordinator.onEvent = onEvent
        for recognizer in context.coordinator.recognizers {
            recognizer.isEnabled = isEnabled
        }
    }

    static func dismantleUIView(_ view: SurfaceView, coordinator: Coordinator) {
        for recognizer in coordinator.recognizers {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
    }

    final class SurfaceView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let coordinator else { return }
            for recognizer in coordinator.recognizers {
                recognizer.view?.removeGestureRecognizer(recognizer)
                window?.addGestureRecognizer(recognizer)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onEvent: (Event) -> Void = { _ in }

        private(set) lazy var pan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            pan.cancelsTouchesInView = false
            pan.delaysTouchesBegan = false
            pan.delegate = self
            return pan
        }()

        private(set) lazy var down: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(clickedDown))
            tap.allowedPressTypes = [NSNumber(value: UIPress.PressType.downArrow.rawValue)]
            tap.allowedTouchTypes = []
            tap.delegate = self
            return tap
        }()

        var recognizers: [UIGestureRecognizer] { [pan, down] }

        @objc private func clickedDown() { onEvent(.clickedDown) }

        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            let travel = pan.translation(in: pan.view).y
            switch pan.state {
            case .changed:
                onEvent(.moved(travel))
            case .ended, .cancelled, .failed:
                onEvent(.ended(travel, velocity: pan.velocity(in: pan.view).y))
            default:
                break
            }
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}
