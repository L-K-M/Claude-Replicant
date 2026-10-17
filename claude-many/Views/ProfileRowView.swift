import SwiftUI

struct ProfileRowView: View {
    @Bindable var manager: ProfileManager
    let profile: ClaudeProfile
    let isEditing: Bool
    @Binding var draft: String
    var nameFieldFocused: FocusState<Bool>.Binding
    let commitEditing: () -> Void
    let cancelEditing: () -> Void
    let requestRename: () -> Void
    let requestDelete: () -> Void
    let requestColor: (ProfileColor?) -> Void

    private var isRunning: Bool { manager.isRunning(id: profile.id) }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(isRunning ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 10, height: 10)
                .accessibilityLabel(isRunning ? "Running" : "Stopped")

            ProfileAvatarView(
                profile: profile,
                appIcon: MacPlatform.applicationIcon(at: manager.bundleURL(for: profile.app))
            )

            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField("Profile Name", text: $draft)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .focused(nameFieldFocused)
                        .onSubmit(commitEditing)
                        .onKeyPress(.escape) {
                            cancelEditing()
                            return .handled
                        }
                        .frame(maxWidth: 280)
                } else {
                    Text(profile.label)
                        .font(.headline)
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if isRunning {
                Button {
                    manager.stop(id: profile.id)
                } label: {
                    Text("Stop").frame(minWidth: Self.actionButtonWidth)
                }
                .buttonStyle(.bordered)
                .help("Quit this \(profile.app.name) instance")
            } else {
                Button {
                    do { try manager.start(id: profile.id) }
                    catch { manager.report(error) }
                } label: {
                    Text("Start").frame(minWidth: Self.actionButtonWidth)
                }
                .buttonStyle(.bordered)
                .disabled(manager.bundleStatus(for: profile.app) != .available)
                .help(profile.isDefault
                      ? "Launch the normal \(profile.app.productName) instance"
                      : "Launch \(profile.app.productName) with this profile's data directory")
            }

            Menu {
                if !profile.isDefault {
                    Button("Rename…", action: requestRename)
                    ProfileColorMenu(profile: profile, choose: requestColor)
                }
                Button("Reveal in Finder") {
                    MacPlatform.revealInFinder(profile.dataDirectory)
                }
                Button("Copy Data Folder Path") {
                    MacPlatform.copyPathToPasteboard(profile.dataDirectory)
                }
                if !profile.isDefault {
                    Divider()
                    Button("Delete…", role: .destructive, action: requestDelete)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 16)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More actions")
        }
        .padding(.vertical, 4)
    }

    /// Start and Stop share a width so the trailing menus line up.
    private static let actionButtonWidth: CGFloat = 40

    private var subtitle: String {
        if profile.isDefault {
            return "Your normal \(profile.app.name) account and data"
        }
        return MacPlatform.homeRelativePath(of: profile.dataDirectory)
    }
}
