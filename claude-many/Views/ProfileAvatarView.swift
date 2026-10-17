import SwiftUI
import AppKit

/// A profile's face in the list: the app icon for the Default entries, a
/// colored monogram with a small app badge for isolated profiles, so two
/// Claude accounts no longer look identical.
struct ProfileAvatarView: View {
    let profile: ClaudeProfile
    let appIcon: NSImage
    var size: CGFloat = 28

    var body: some View {
        if profile.isDefault {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: size, height: size)
                .accessibilityLabel(profile.app.name)
        } else {
            monogram
                .overlay(alignment: .bottomTrailing) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: size / 2, height: size / 2)
                        .offset(x: size / 8, y: size / 8)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(profile.app.name) profile, \(profile.displayColor.name)")
        }
    }

    private var monogram: some View {
        let color = profile.displayColor
        return Circle()
            .fill(color.swatchColor.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(profile.monogram)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(color.prefersDarkText ? Color.black.opacity(0.7) : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(size / 10)
            }
    }
}

/// The Color submenu for a profile: Automatic plus the palette, with a
/// checkmark on the current choice.
struct ProfileColorMenu: View {
    let profile: ClaudeProfile
    let choose: (ProfileColor?) -> Void

    var body: some View {
        Menu("Color") {
            Picker("Color", selection: Binding(get: { profile.color }, set: choose)) {
                Text("Automatic").tag(ProfileColor?.none)
                ForEach(ProfileColor.allCases) { color in
                    Label {
                        Text(color.name)
                    } icon: {
                        Image(nsImage: color.menuSwatch)
                    }
                    .tag(ProfileColor?.some(color))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

extension ProfileColor {
    var swatchColor: Color {
        switch self {
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .gray: return .gray
        }
    }

    /// White on yellow is unreadable.
    var prefersDarkText: Bool { self == .yellow }

    /// Menus draw SF Symbols as monochrome templates, so the swatch is a
    /// plain colored image.
    var menuSwatch: NSImage {
        let diameter: CGFloat = 12
        let image = NSImage(size: NSSize(width: diameter, height: diameter), flipped: false) { rect in
            NSColor(swatchColor).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
