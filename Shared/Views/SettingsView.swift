import SwiftUI

/// App settings: the things you set once and forget.
///
/// Separate from the reader's "AA" popover on purpose. That popover is for decisions
/// you make *while reading* — size, theme, layout. Read language lives in both, backed
/// by the same AppStorage key, so they can't disagree.
struct SettingsView: View {
    @AppStorage("ttsLanguage") private var ttsLanguageRaw = TTSLanguage.both.rawValue
    @AppStorage("wikipediaLookupEnabled") private var wikipediaLookup = true

    var body: some View {
        Form {
            Section {
                Toggle("Look things up on Wikipedia", isOn: $wikipediaLookup)
            } header: {
                Text("Tutor")
            } footer: {
                // Honest about the one thing in this app that leaves the machine. The
                // model itself is local; this is the exception, and it's small: names,
                // not the book and not the questions.
                Text("""
                The tutor can't remember much about a book's history or its author on \
                its own, so it fetches Wikipedia's article on the book and the author \
                once when you import it, and looks up names and terms as you ask about \
                them. Only those names are sent to Wikipedia — never the pages you're \
                reading, and never your questions.
                """)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Read", selection: $ttsLanguageRaw) {
                    ForEach(TTSLanguage.allCases) { lang in
                        Text(lang.rawValue).tag(lang.rawValue)
                    }
                }
            } header: {
                Text("Read Aloud")
            } footer: {
                Text("""
                Narration uses the best system voice installed. The built-in defaults \
                are the robotic ones — for a far better narrator, download enhanced \
                voices in System Settings → Accessibility → Spoken Content → Voices \
                (e.g. Thomas or Audrey for French, Ava for English). The app picks \
                them up automatically.
                """)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    SettingsView()
}
