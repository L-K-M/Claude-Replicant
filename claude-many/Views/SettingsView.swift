import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var manager: ProfileManager

    var body: some View {
        Form {
            ForEach(ManagedApp.allCases) { app in
                applicationSection(for: app)
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
                Text("Isolated profiles keep local configuration under ~/Library/Application Support/Claude-Many/Profiles. Default Claude and Default ChatGPT use their normal data and settings. Each app manages cloud data through its own services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
        // Keeps the bundle checks current if the main window closes first.
        .task { await manager.monitorRunningProcesses() }
    }

    private func applicationSection(for app: ManagedApp) -> some View {
        let bundle = manager.bundleURL(for: app)
        let status = manager.lastKnownBundleStatus(for: app)
        return Section("\(app.name) Application") {
            LabeledContent(app.bundleName) {
                HStack(spacing: 8) {
                    if status != .missing {
                        Image(nsImage: MacPlatform.applicationIcon(at: bundle))
                            .resizable()
                            .frame(width: 20, height: 20)
                    }
                    Text(MacPlatform.homeRelativePath(of: bundle))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            HStack {
                Button("Choose…") {
                    MacPlatform.chooseApplicationBundle(named: app.bundleName) { url in
                        if let url { manager.setBundleURL(url, for: app) }
                    }
                }
                Button("Reset to Default") {
                    manager.resetBundlePath(for: app)
                }
                .disabled(bundle == app.defaultBundleURL)
                Spacer()
                Label(
                    statusTitle(status),
                    systemImage: status == .available
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(status == .available ? .green : .orange)
                .labelStyle(.titleAndIcon)
                .font(.callout)
            }
            if let version = manager.installedVersion(of: app) {
                LabeledContent("Version") {
                    Text(version)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if app.isNewerThanChecked(version) {
                    Text("\(AppBranding.name) was checked with \(app.name) \(app.checkedVersion). If profiles stop staying separate after this update, see the README.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if status == .unsupported {
                Text("This build cannot run separate profiles. ChatGPT Classic is not supported; install the current \(app.productName) app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if status == .otherApp {
                Text("This is not \(app.productName). Choose \(app.bundleName).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusTitle(_ status: AppBundleStatus) -> String {
        switch status {
        case .available: return "Found"
        case .missing: return "Not found"
        case .unsupported: return "Unsupported"
        case .otherApp: return "Wrong app"
        }
    }
}
