import SwiftUI

/// A data folder no profile uses, with ways to list it again or trash it.
struct UnlistedDataRow: View {
    let data: UnlistedProfileData
    let restore: () -> Void
    let moveToTrash: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(data.suggestedLabel)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Button("Restore", action: restore)
                .buttonStyle(.bordered)
                .help("List it again as a \(data.app.name) profile that uses this folder")

            Menu {
                actions
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 16)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More actions")
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("Restore", action: restore)
            actions
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button("Reveal in Finder") {
            MacPlatform.revealInFinder(data.directory)
        }
        Divider()
        Button("Move to Trash…", role: .destructive, action: moveToTrash)
    }

    private var subtitle: String {
        var parts = ["\(data.app.name) data", MacPlatform.homeRelativePath(of: data.directory)]
        if let modified = data.modified {
            parts.insert("changed \(modified.formatted(.relative(presentation: .named)))", at: 1)
        }
        return parts.joined(separator: " · ")
    }
}
