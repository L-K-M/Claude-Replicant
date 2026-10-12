import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var manager: ProfileManager

    var body: some View {
        Form {
            Section("Claude Application") {
                LabeledContent("Claude.app") {
                    HStack(spacing: 8) {
                        if manager.bundleExists {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: manager.claudeBundleURL.path))
                                .resizable()
                                .frame(width: 20, height: 20)
                        }
                        Text(MacPlatform.homeRelativePath(of: manager.claudeBundleURL))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                HStack {
                    Button("Choose…") {
                        MacPlatform.chooseApplicationBundle { url in
                            if let url { manager.setBundleURL(url) }
                        }
                    }
                    Button("Reset to Default") {
                        manager.resetBundlePath()
                    }
                    .disabled(manager.claudeBundleURL == ProfileManager.defaultBundleURL)
                    Spacer()
                    Label(
                        manager.bundleExists ? "Found" : "Not found",
                        systemImage: manager.bundleExists
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(manager.bundleExists ? .green : .orange)
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                }
            }

            Section("Data") {
                LabeledContent("Profiles directory") {
                    HStack(spacing: 8) {
                        Text(MacPlatform.homeRelativePath(of: ProfileManager.profilesRootDirectory))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Reveal in Finder") {
                            try? FileManager.default.createDirectory(
                                at: ProfileManager.profilesRootDirectory,
                                withIntermediateDirectories: true
                            )
                            MacPlatform.revealInFinder(ProfileManager.profilesRootDirectory)
                        }
                    }
                }
            }

            Section {
                Text("Isolated profiles keep local configuration under ~/Library/Application Support/Claude-Many/Profiles. Default Claude uses its normal data and settings. Claude manages cloud data through its own services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
    }
}
