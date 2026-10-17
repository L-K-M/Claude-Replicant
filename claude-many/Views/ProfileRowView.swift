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

    private var state: InstanceState { manager.state(of: profile.id) }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .accessibilityLabel(statusTitle)

            Image(nsImage: MacPlatform.applicationIcon(at: manager.bundleURL(for: profile.app)))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityLabel(profile.app.name)

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

            switch state {
            case .running:
                Button("Stop") {
                    manager.stop(id: profile.id)
                }
                .buttonStyle(.bordered)
                .help("Quit this \(profile.app.name) instance")
            case .stopping, .restarting:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text(state == .restarting ? "Restarting…" : "Stopping…")
                        .foregroundStyle(.secondary)
                }
                .help("Waiting for the previous \(profile.app.name) instance to quit")
            case .stopped:
                Button("Start") {
                    do { try manager.start(id: profile.id) }
                    catch { manager.report(error) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.bundleStatus(for: profile.app) != .available)
                .help(profile.isDefault
                      ? "Launch the normal \(profile.app.productName) instance"
                      : "Launch \(profile.app.productName) with this profile's data directory")
            }

            Menu {
                if state == .running {
                    Button("Restart") { manager.restart(id: profile.id) }
                } else if state == .restarting {
                    Button("Cancel Restart") { manager.stop(id: profile.id) }
                }
                if !profile.isDefault {
                    Button("Rename…", action: requestRename)
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

    private var statusColor: Color {
        switch state {
        case .running: return .green
        case .stopping, .restarting: return .orange
        case .stopped: return Color.secondary.opacity(0.35)
        }
    }

    private var statusTitle: String {
        switch state {
        case .running: return "Running"
        case .stopping: return "Stopping"
        case .restarting: return "Restarting"
        case .stopped: return "Stopped"
        }
    }

    private var subtitle: String {
        if profile.isDefault {
            return "Your normal \(profile.app.name) account and data"
        }
        return MacPlatform.homeRelativePath(of: profile.dataDirectory)
    }
}
