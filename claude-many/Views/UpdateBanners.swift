import SwiftUI

/// Notices above the profile list after an app update: instances still
/// running the old version, and profiles that quit for the update.
struct UpdateBanners: View {
    @Bindable var manager: ProfileManager

    var body: some View {
        ForEach(manager.listedApps) { app in
            let outdated = manager.instancesNeedingRestart(for: app)
            if !outdated.isEmpty {
                restartBanner(for: app, outdated: outdated)
                Divider()
            }
        }

        ForEach(manager.profilesClosedForUpdate) { profile in
            closedBanner(for: profile)
            Divider()
        }
    }

    private func restartBanner(for app: ManagedApp, outdated: [ClaudeProfile]) -> some View {
        let version = manager.installedVersion(of: app) ?? ""
        let message = outdated.count == 1
            ? "“\(outdated[0].label)” still runs the previous version. Restart it to use the new one."
            : "\(outdated.count) profiles still run the previous version. Restart them to use the new one."
        return NoticeBanner(symbol: "arrow.triangle.2.circlepath.circle.fill",
                            title: "\(app.name) \(version) is installed",
                            message: message) {
            Button("Later") { manager.postponeRestart(for: app) }
            Button(outdated.count == 1 ? "Restart" : "Restart All") {
                for profile in outdated { manager.restart(id: profile.id) }
            }
        }
    }

    private func closedBanner(for profile: ClaudeProfile) -> some View {
        NoticeBanner(symbol: "exclamationmark.triangle.fill",
                     title: "“\(profile.label)” quit for a \(profile.app.name) update",
                     message: "If \(profile.app.name) reopened by itself, that window is Default \(profile.app.name) with your normal account, not “\(profile.label)”.") {
            Button("Dismiss") { manager.dismissClosedForUpdate(id: profile.id) }
            Button("Open “\(profile.label)”") {
                manager.dismissClosedForUpdate(id: profile.id)
                manager.open(id: profile.id)
            }
        }
    }
}

/// A one-line notice with actions, styled like the missing-app banner.
private struct NoticeBanner<Actions: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .symbolRenderingMode(.multicolor)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
