import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var manager: ProfileManager
    @AppStorage(AppPreferences.showsMenuBarExtra) private var showsMenuBarExtra = false
    @State private var loginItemStatus = LoginItem.status
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Show in menu bar", isOn: $showsMenuBarExtra)
                Text("Start, stop, and switch profiles from the menu bar. \(AppBranding.name) keeps running when its window is closed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Open \(AppBranding.name) at login", isOn: opensAtLogin)
                Text("Profiles with Open at Launch checked in their … menu start with it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if loginItemStatus == .needsApproval {
                    HStack {
                        Text("Allow \(AppBranding.name) in Login Items to finish.")
                            .font(.caption)
                        Spacer()
                        Button("Open Login Items…", action: LoginItem.openSystemSettings)
                    }
                }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

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
        // Approved or changed in System Settings meanwhile, perhaps.
        .onAppear { loginItemStatus = LoginItem.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItemStatus = LoginItem.status
        }
        .frame(width: 480)
        .padding()
    }

    private var opensAtLogin: Binding<Bool> {
        Binding(
            get: { loginItemStatus != .off },
            set: { enabled in
                do {
                    try LoginItem.setEnabled(enabled)
                    loginItemError = nil
                } catch {
                    loginItemError = "Could not change the login item: \(error.localizedDescription)"
                }
                loginItemStatus = LoginItem.status
            }
        )
    }

    private func applicationSection(for app: ManagedApp) -> some View {
        let bundle = manager.bundleURL(for: app)
        let status = manager.bundleStatus(for: app)
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
            if status == .unsupported {
                Text("This build cannot run separate profiles. ChatGPT Classic is not supported; install the current \(app.productName) app.")
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
        }
    }
}
