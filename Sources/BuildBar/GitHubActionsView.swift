import SwiftUI
import AppKit

struct ActionsTab: View {
    @ObservedObject var watcher: GitHubWatcher
    @State private var showingRepos = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            reposSection
            Divider()
            content
        }
    }

    // MARK: - Repos section

    private var reposSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showingRepos.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showingRepos ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("Repos")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("(\(watcher.repos.count))")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    if !watcher.perRepoErrors.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    if !showingRepos {
                        Button("Add…") { promptForRepo() }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if showingRepos {
                VStack(spacing: 0) {
                    ForEach(watcher.repos) { repo in
                        RepoRow(
                            watcher: watcher,
                            repo: repo,
                            error: watcher.perRepoErrors[repo.id]
                        )
                        Divider().padding(.leading, 30)
                    }
                    Button {
                        promptForRepo()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle")
                            Text("Add repo…")
                            Spacer()
                        }
                        .font(.system(size: 12))
                        .foregroundColor(.accentColor)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if watcher.repos.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No repos added").font(.subheadline).bold()
                Text("Click \"Add repo…\" and enter owner/repo. Uses your `gh` CLI auth.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        } else if watcher.runs.isEmpty && watcher.perRepoErrors.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(watcher.isRefreshing ? "Loading…" : "No workflow runs yet").font(.subheadline).bold()
                Text("Trigger a workflow on GitHub to see runs here.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(watcher.runs.prefix(30).enumerated()), id: \.element.id) { idx, ar in
                        RunRow(annotated: ar, tick: watcher.tick)
                        if idx < min(29, watcher.runs.count - 1) {
                            Divider().padding(.leading, 38)
                        }
                    }
                }
            }
            .frame(minHeight: 500, maxHeight: 800)
        }
    }

    private func promptForRepo() {
        let alert = NSAlert()
        alert.messageText = "Add a GitHub repo"
        alert.informativeText = "Format: owner/repo (e.g., facebook/react). Uses `gh` CLI under the hood."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "owner/repo"
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            watcher.addRepo(slug: field.stringValue)
            showingRepos = true
        }
    }
}

struct RepoRow: View {
    let watcher: GitHubWatcher
    let repo: GitHubRepoConfig
    let error: String?
    @State private var hovering = false
    @State private var showingColorPicker = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showingColorPicker = true
            } label: {
                ZStack {
                    Circle().fill(repo.color.swiftUIColor.opacity(0.2))
                    Circle().stroke(repo.color.swiftUIColor, lineWidth: 2)
                }
                .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingColorPicker, arrowEdge: .trailing) {
                ProjectColorPicker(current: repo.color) { newColor in
                    watcher.updateRepo(repo) { $0.color = newColor }
                    showingColorPicker = false
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(repo.slug).font(.system(size: 12, weight: .medium))
                if let error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button {
                BuildAction.openURL("https://github.com/\(repo.slug)/actions")
            } label: {
                Image(systemName: "arrow.up.right.square")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open Actions tab on GitHub")
            Button {
                watcher.removeRepo(repo)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary.opacity(hovering ? 1 : 0.5))
            }
            .buttonStyle(.plain)
            .help("Remove repo")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onHover { hovering = $0 }
    }
}

struct RunRow: View {
    let annotated: AnnotatedRun
    let tick: Date

    private var run: GitHubRun { annotated.run }
    private var repo: GitHubRepoConfig { annotated.repo }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: run.statusSymbol)
                .foregroundColor(statusColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(run.workflowName ?? "workflow")
                        .font(.system(size: 13, weight: .semibold))
                    if let branch = run.headBranch {
                        Text("·").foregroundColor(.secondary)
                        Text(branch).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    if let event = run.event {
                        Text("·").foregroundColor(.secondary)
                        Text(event).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    repoChip
                    Text(statusLabel).font(.caption).foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary)
                    Text(run.relativeTime(now: tick)).font(.caption).foregroundColor(.secondary)
                }
                if let title = run.displayTitle, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            if let url = run.url {
                Button {
                    BuildAction.openURL(url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("Open run on GitHub")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            BuildAction.openURL(run.url)
        }
    }

    private var statusLabel: String {
        if run.isInFlight {
            return "\(run.prettyStatus) · \(run.elapsedDuration(now: tick))"
        }
        return run.prettyStatus
    }

    private var repoChip: some View {
        Text(repo.displayName)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(repo.color.swiftUIColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(repo.color.swiftUIColor.opacity(0.15))
            )
            .lineLimit(1)
    }

    private var statusColor: Color {
        if run.status.lowercased() == "completed" {
            switch (run.conclusion ?? "").lowercased() {
            case "success": return .green
            case "failure": return .red
            case "cancelled": return .gray
            case "skipped": return .gray
            default: return .gray
            }
        }
        switch run.status.lowercased() {
        case "in_progress": return .orange
        case "queued", "waiting", "pending", "requested": return .yellow
        default: return .gray
        }
    }
}
