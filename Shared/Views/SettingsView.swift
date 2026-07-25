import SwiftUI

/// App settings: the things you set once and forget.
///
/// Separate from the reader's "AA" popover on purpose. That popover is for decisions
/// you make *while reading* — size, theme, layout. Read language lives in both, backed
/// by the same AppStorage key, so they can't disagree.
struct SettingsView: View {
    @AppStorage("ttsLanguage") private var ttsLanguageRaw = TTSLanguage.both.rawValue

    var body: some View {
        Form {
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
        #if os(macOS)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        #endif
    }
}

#Preview {
    SettingsView()
}
