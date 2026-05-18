import SwiftUI
import AppKit

struct VercelTab: View {
    @ObservedObject var watcher: VercelWatcher
    @State private var searchText: String = ""

    private var filtered: [VercelDeployment] {
        guard !searchText.isEmpty else { return watcher.deployments }
        let s = searchText.lowercased()
        return watcher.deployments.filter { searchableText(for: $0).contains(s) }
    }

    private func searchableText(for d: VercelDeployment) -> String {
        [
            d.name ?? "",
            d.url ?? "",
            d.target ?? "",
            d.state,
            d.meta?.githubCommitRef ?? "",
            d.meta?.githubCommitMessage ?? "",
            d.creator?.username ?? ""
        ].joined(separator: " ").lowercased()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !watcher.config.hasToken {
                noTokenView
            } else {
                searchBar
                Divider()
                content
            }
        }
    }

    private var noTokenView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "triangle.fill").foregroundColor(.accentColor)
                Text("Connect Vercel").font(.system(size: 13, weight: .semibold))
            }
            Text("Watch your Next.js deploys without leaving the menu bar. Create a token at vercel.com/account/tokens.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                Button("Add token…") { promptForToken() }
                    .buttonStyle(.borderedProminent)
                Button("Open vercel.com/account/tokens") {
                    BuildAction.openURL("https://vercel.com/account/tokens")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundColor(.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.system(size: 11))
            TextField("Search deploys…", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            Menu {
                Button("Edit token…") { promptForToken() }
                Button("Edit team ID…") { promptForTeamId() }
                Divider()
                Button("Disconnect Vercel", role: .destructive) {
                    watcher.config = VercelConfig(token: "")
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        if let err = watcher.error {
            VStack(alignment: .leading, spacing: 6) {
                Text("Vercel error").font(.subheadline).bold().foregroundColor(.orange)
                Text(err).font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                Button("Edit token") { promptForToken() }
                    .font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        } else if watcher.deployments.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(watcher.isRefreshing ? "Loading…" : "No recent deploys")
                    .font(.subheadline).bold()
                Text("Pushes to Vercel projects show up here within ~30s.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        } else if filtered.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No matches").font(.subheadline).bold()
                Text("Try clearing the search.").font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(filtered.prefix(20).enumerated()), id: \.element.id) { idx, d in
                        VercelRow(deployment: d, tick: watcher.tick)
                        if idx < min(19, filtered.count - 1) {
                            Divider().padding(.leading, 38)
                        }
                    }
                }
            }
            .frame(minHeight: 500, maxHeight: 800)
        }
    }

    private func promptForToken() {
        let alert = NSAlert()
        alert.messageText = "Vercel API token"
        alert.informativeText = "Create one at vercel.com/account/tokens. Stored locally in app preferences."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = watcher.config.token
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            var cfg = watcher.config
            cfg.token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            watcher.config = cfg
        }
    }

    private func promptForTeamId() {
        let alert = NSAlert()
        alert.messageText = "Vercel team ID (optional)"
        alert.informativeText = "Leave blank for personal account. Find it in your team's General settings."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = watcher.config.teamId ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            var cfg = watcher.config
            let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            cfg.teamId = v.isEmpty ? nil : v
            watcher.config = cfg
        }
    }
}

struct VercelRow: View {
    let deployment: VercelDeployment
    let tick: Date
    @State private var copied = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: deployment.statusSymbol)
                .foregroundColor(statusColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(deployment.name ?? "deploy")
                        .font(.system(size: 13, weight: .semibold))
                    if let target = deployment.target {
                        Text("·").foregroundColor(.secondary)
                        Text(target).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    if let branch = deployment.meta?.githubCommitRef {
                        Text("·").foregroundColor(.secondary)
                        Text(branch).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(statusLabel).font(.caption).foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary)
                    Text(deployment.relativeTime(now: tick)).font(.caption).foregroundColor(.secondary)
                    if let user = deployment.creator?.username {
                        Text("·").foregroundColor(.secondary)
                        Text("@\(user)").font(.caption).foregroundColor(.secondary)
                    }
                }
                if let msg = deployment.meta?.githubCommitMessage {
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            if let full = deployment.fullURL {
                Button {
                    BuildAction.copy(full)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundColor(copied ? .green : .accentColor)
                }
                .buttonStyle(.plain)
                .help(copied ? "Copied!" : "Copy deployment URL")
            }
            Menu {
                if let url = deployment.fullURL {
                    Button {
                        BuildAction.openURL(url)
                    } label: { Label("Open deployment", systemImage: "arrow.up.right.square") }
                }
                if let inspector = deployment.inspectorUrl {
                    Button {
                        BuildAction.openURL(inspector)
                    } label: { Label("View on Vercel dashboard", systemImage: "doc.text.magnifyingglass") }
                }
                if let sha = deployment.meta?.githubCommitSha {
                    Divider()
                    Button {
                        BuildAction.copy(sha)
                    } label: { Label("Copy commit (\(String(sha.prefix(7))))", systemImage: "number") }
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            BuildAction.openURL(deployment.inspectorUrl ?? deployment.fullURL)
        }
    }

    private var statusLabel: String {
        if deployment.isInFlight {
            return "\(deployment.prettyState) · \(deployment.elapsedDuration(now: tick))"
        }
        return deployment.prettyState
    }

    private var statusColor: Color {
        switch deployment.state.uppercased() {
        case "READY": return .green
        case "ERROR": return .red
        case "CANCELED": return .gray
        case "BUILDING": return .orange
        case "QUEUED", "INITIALIZING": return .yellow
        default: return .gray
        }
    }
}
