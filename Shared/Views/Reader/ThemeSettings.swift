import SwiftUI

/// Theme settings popover for font size and theme selection
struct ThemeSettings: View {
    @Binding var fontSize: CGFloat
    @Binding var currentTheme: BookTheme
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Themes & Settings")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            
            Divider()
                .padding(.horizontal, -20)
            
            // Font size controls
            HStack(spacing: 0) {
                Button { if fontSize > 12 { fontSize -= 2 } } label: {
                    Text("A")
                        .font(.system(size: 14, weight: .regular))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
                .buttonStyle(.plain)
                
                Divider().frame(height: 26)
                
                Button { if fontSize < 28 { fontSize += 2 } } label: {
                    Text("A")
                        .font(.system(size: 20, weight: .regular))
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                }
                .buttonStyle(.plain)
            }
            .background(Color(red: 0.93, green: 0.90, blue: 0.85))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            
            // Theme grid (2x3 layout)
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    themeButton(.original)
                    themeButton(.quiet)
                    themeButton(.paper)
                }
                HStack(spacing: 12) {
                    themeButton(.bold)
                    themeButton(.calm)
                    themeButton(.focus)
                }
            }
        }
        .padding(20)
        .frame(width: 290)
        .background(Color(red: 0.976, green: 0.949, blue: 0.898))
    }
    
    private func themeButton(_ theme: BookTheme) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                currentTheme = theme
            }
        } label: {
            VStack(spacing: 6) {
                Text("Aa")
                    .font(.system(size: 22, weight: .regular, design: .serif))
                    .foregroundStyle(theme.previewTextColor)
                    .frame(width: 76, height: 56)
                    .background(theme.previewBgColor)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(currentTheme == theme ? Color.black : Color.clear, lineWidth: 2)
                    )
                
                Text(theme.name)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ThemeSettings(
        fontSize: .constant(17),
        currentTheme: .constant(.paper)
    )
}
