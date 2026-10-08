import SwiftUI

/// A small shared visual layer for the Settings UI — a colored rounded-square icon
/// badge per sidebar section, matching Cotypist's settings sidebar (each section gets
/// its own accent color rather than a plain monochrome list icon). Everything else in
/// Settings intentionally stays on stock `.formStyle(.grouped)` — that already reads
/// as native and correct; the sidebar icons were the actual visual gap.
enum SectionAccent {
    static func color(for section: SettingsView.Section) -> Color {
        switch section {
        case .setup: return .blue
        case .general: return .gray
        case .engine: return .indigo
        case .context: return .orange
        case .personalization: return .purple
        case .textTools: return .teal
        case .emoji: return .yellow
        case .shortcuts: return .pink
        case .apps: return .red
        case .advanced: return .blue
        case .statistics: return .cyan
        case .about: return .brown
        }
    }
}

/// A colored rounded-square badge + SF Symbol, sized for a sidebar row — the visual
/// signature of Cotypist's Settings sidebar.
struct SidebarIconBadge: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}
