import SwiftUI
import AppKit

extension ProjectColor {
    var swiftUIColor: Color {
        switch self {
        case .accent: return .accentColor
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        case .purple: return .purple
        case .pink: return .pink
        case .teal: return .teal
        case .yellow: return .yellow
        case .indigo: return .indigo
        }
    }
}

enum PlatformFilter: String, CaseIterable, Hashable {
    case all, ios, android
    var label: String {
        switch self {
        case .all: return "All"
        case .ios: return "iOS"
        case .android: return "Android"
        }
    }
}

enum StatusFilter: String, CaseIterable, Hashable {
    case all, building, finished, failed
    var label: String {
        switch self {
        case .all: return "All"
        case .building: return "Building"
        case .finished: return "Done"
        case .failed: return "Failed"
        }
    }
    var color: Color? {
        switch self {
        case .all: return nil
        case .building: return .orange
        case .finished: return .green
        case .failed: return .red
        }
    }
}

enum WatcherTab: String, CaseIterable, Hashable {
    case builds, vercel, actions
    var label: String {
        switch self {
        case .builds: return "EAS"
        case .vercel: return "Vercel"
        case .actions: return "Actions"
        }
    }
    var icon: String {
        switch self {
        case .builds: return "hammer.fill"
        case .vercel: return "triangle.fill"
        case .actions: return "gearshape.2.fill"
        }
    }
}

struct BuildMenuView: View {
    @ObservedObject var watcher: BuildWatcher
    @ObservedObject var vercel: VercelWatcher
    @ObservedObject var github: GitHubWatcher
    @AppStorage("activeTab") private var activeTabRaw: String = WatcherTab.builds.rawValue
    @State private var showingProjects = false
    @State private var searchText: String = ""
    @State private var platformFilter: PlatformFilter = .all
    @State private var statusFilter: StatusFilter = .all
    @AppStorage("groupByProject") private var groupByProject: Bool = false

    private var activeTab: WatcherTab {
        get { WatcherTab(rawValue: activeTabRaw) ?? .builds }
    }
    private func setTab(_ t: WatcherTab) { activeTabRaw = t.rawValue }

    private var filtered: [AnnotatedBuild] {
        watcher.builds.filter { ab in
            switch platformFilter {
            case .all: break
            case .ios: if !ab.build.isIOS { return false }
            case .android: if !ab.build.isAndroid { return false }
            }
            switch statusFilter {
            case .all: break
            case .building: if !ab.build.isInFlight { return false }
            case .finished: if ab.build.status != "FINISHED" { return false }
            case .failed: if ab.build.status != "ERRORED" { return false }
            }
            if !searchText.isEmpty {
                let s = searchText.lowercased()
                let haystack = [
                    ab.project.name,
                    ab.build.buildProfile ?? "",
                    ab.build.appVersion ?? "",
                    ab.build.platform,
                    ab.build.prettyStatus,
                    ab.build.gitCommitHash ?? ""
                ].joined(separator: " ").lowercased()
                if !haystack.contains(s) { return false }
            }
            return true
        }
    }

    private var grouped: [(project: Project, builds: [AnnotatedBuild])] {
        let byProject = Dictionary(grouping: filtered, by: { $0.project })
        return byProject
            .map { (project: $0.key, builds: $0.value.sorted { $0.build.createdAt > $1.build.createdAt }) }
            .sorted { $0.project.name.lowercased() < $1.project.name.lowercased() }
    }

    private var anyFilterActive: Bool {
        platformFilter != .all || statusFilter != .all || !searchText.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            tabBar
            Divider()
            switch activeTab {
            case .builds:
                buildsTabContent
            case .vercel:
                VercelTab(watcher: vercel)
            case .actions:
                ActionsTab(watcher: github)
            }
            Divider()
            footer
        }
        .frame(width: 420)
    }

    @ViewBuilder
    private var buildsTabContent: some View {
        if watcher.hasAuthError {
            authBanner
            Divider()
        }
        projectsSection
        Divider()
        filterStrip
        Divider()
        content
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(WatcherTab.allCases, id: \.self) { tab in
                Button {
                    setTab(tab)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.icon).font(.system(size: 11))
                        Text(tab.label).font(.system(size: 12, weight: activeTab == tab ? .semibold : .regular))
                        if let badge = badgeCount(for: tab), badge > 0 {
                            Text("\(badge)")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.orange))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .foregroundColor(activeTab == tab ? .accentColor : .secondary)
                    .background(
                        VStack(spacing: 0) {
                            Spacer()
                            Rectangle()
                                .fill(activeTab == tab ? Color.accentColor : Color.clear)
                                .frame(height: 2)
                        }
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func badgeCount(for tab: WatcherTab) -> Int? {
        switch tab {
        case .builds: return watcher.builds.filter { $0.build.isInFlight }.count
        case .vercel: return vercel.deployments.filter { $0.isInFlight }.count
        case .actions: return github.runs.filter { $0.run.isInFlight }.count
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "hammer.fill").foregroundColor(.accentColor)
            Text("BuildBar").font(.headline)
            if watcher.isPaused {
                Text("paused")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15)))
            }
            Spacer()
            Button {
                Task { await refreshActive() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(isActiveRefreshing ? 360 : 0))
                    .animation(isActiveRefreshing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isActiveRefreshing)
            }
            .buttonStyle(.plain)
            .disabled(isActiveRefreshing)
        }
        .padding(12)
    }

    private var isActiveRefreshing: Bool {
        switch activeTab {
        case .builds: return watcher.isRefreshing
        case .vercel: return vercel.isRefreshing
        case .actions: return github.isRefreshing
        }
    }

    private func refreshActive() async {
        switch activeTab {
        case .builds: await watcher.refresh()
        case .vercel: await vercel.refresh()
        case .actions: await github.refresh()
        }
    }

    private var authBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .foregroundColor(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not logged in to EAS").font(.system(size: 12, weight: .semibold))
                Text("Run `eas login` in your terminal, then refresh.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.1))
    }

    // MARK: - Projects section

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showingProjects.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: showingProjects ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("Projects")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("(\(watcher.projects.count))")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    if watcher.hasAnyError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                    Spacer()
                    if !showingProjects {
                        Button("Add…") { pickProjectFolder() }
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

            if showingProjects {
                VStack(spacing: 0) {
                    ForEach(watcher.projects) { project in
                        ProjectRow(
                            watcher: watcher,
                            project: project,
                            error: watcher.perProjectErrors[project.id],
                            onRemove: { watcher.removeProject(project) }
                        )
                        Divider().padding(.leading, 30)
                    }
                    Button {
                        pickProjectFolder()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.circle")
                            Text("Add project…")
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

    // MARK: - Filter strip

    private var filterStrip: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 11))
                TextField("Search builds…", text: $searchText)
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
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))

            HStack(spacing: 6) {
                ForEach(PlatformFilter.allCases, id: \.self) { p in
                    FilterChip(
                        label: p.label,
                        isOn: platformFilter == p,
                        accent: nil
                    ) { platformFilter = p }
                }
                Spacer().frame(width: 4)
                ForEach(StatusFilter.allCases, id: \.self) { s in
                    FilterChip(
                        label: s.label,
                        isOn: statusFilter == s,
                        accent: s.color
                    ) { statusFilter = s }
                }
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if watcher.projects.isEmpty {
            emptyState(
                title: "No projects added",
                message: "Click \"Add project…\" above and pick a folder containing eas.json."
            )
        } else if watcher.builds.isEmpty && !watcher.hasAnyError {
            emptyState(
                title: watcher.isRefreshing ? "Loading…" : "No builds yet",
                message: "Run `eas build` to see something here."
            )
        } else if filtered.isEmpty {
            emptyState(
                title: "No matches",
                message: "Try adjusting filters or clearing the search."
            )
        } else {
            ScrollView {
                if groupByProject {
                    groupedList
                } else {
                    flatList
                }
            }
            .frame(minHeight: 500, maxHeight: 800)
        }
    }

    @ViewBuilder
    private var flatList: some View {
        VStack(spacing: 0) {
            ForEach(Array(filtered.prefix(30).enumerated()), id: \.element.id) { idx, ab in
                BuildRow(watcher: watcher, annotated: ab, tick: watcher.tick)
                if idx < min(29, filtered.count - 1) {
                    Divider().padding(.leading, 38)
                }
            }
        }
    }

    @ViewBuilder
    private var groupedList: some View {
        VStack(spacing: 0) {
            ForEach(grouped, id: \.project.id) { section in
                HStack(spacing: 6) {
                    Circle()
                        .fill(section.project.color.swiftUIColor)
                        .frame(width: 8, height: 8)
                    Text(section.project.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text("(\(section.builds.count))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.06))
                ForEach(section.builds.prefix(20)) { ab in
                    BuildRow(watcher: watcher, annotated: ab, tick: watcher.tick)
                    Divider().padding(.leading, 38)
                }
            }
        }
    }

    private func emptyState(title: String, message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).bold()
            Text(message).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                watcher.isPaused.toggle()
            } label: {
                Image(systemName: watcher.isPaused ? "play.fill" : "pause.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help(watcher.isPaused ? "Resume polling" : "Pause polling")

            Menu {
                ForEach(BuildWatcher.intervalOptions, id: \.self) { secs in
                    Button {
                        watcher.pollIntervalSeconds = secs
                    } label: {
                        Label(intervalLabel(secs), systemImage: watcher.pollIntervalSeconds == secs ? "checkmark" : "")
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text("every \(intervalLabel(watcher.pollIntervalSeconds))")
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8))
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            if activeTab == .builds {
                Button {
                    groupByProject.toggle()
                } label: {
                    Image(systemName: groupByProject ? "rectangle.stack.fill" : "rectangle.stack")
                        .foregroundColor(groupByProject ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(groupByProject ? "Showing grouped by project" : "Group by project")
            }

            Spacer()

            if let t = currentLastUpdated {
                Text("Updated \(t, style: .time)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Menu {
                Toggle("Launch at login", isOn: Binding(
                    get: { LaunchAtLogin.isEnabled },
                    set: { LaunchAtLogin.setEnabled($0) }
                ))
                .disabled(!LaunchAtLogin.isBundled)
                if !LaunchAtLogin.isBundled {
                    Text("Run via ./run.sh to enable")
                        .font(.caption)
                }
                Divider()
                Button("Quit BuildBar") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape").foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(12)
    }

    private var currentLastUpdated: Date? {
        switch activeTab {
        case .builds: return watcher.lastUpdated
        case .vercel: return vercel.lastUpdated
        case .actions: return github.lastUpdated
        }
    }

    private func intervalLabel(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h"
    }

    private func pickProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add Expo project"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            for url in panel.urls {
                watcher.addProject(path: url.path)
            }
            showingProjects = true
        }
    }
}

// MARK: - Project row

struct ProjectRow: View {
    let watcher: BuildWatcher
    let project: Project
    let error: String?
    let onRemove: () -> Void
    @State private var hovering = false
    @State private var showingColorPicker = false
    @State private var showingUpdates = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showingColorPicker = true
            } label: {
                ZStack {
                    Circle().fill(project.color.swiftUIColor.opacity(0.2))
                    Circle().stroke(project.color.swiftUIColor, lineWidth: 2)
                    if error != nil {
                        Image(systemName: "exclamationmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.orange)
                    }
                }
                .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingColorPicker, arrowEdge: .trailing) {
                ProjectColorPicker(current: project.color) { newColor in
                    watcher.updateProject(project) { $0.color = newColor }
                    showingColorPicker = false
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.system(size: 12, weight: .medium))
                Text(project.path)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let error {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary.opacity(hovering ? 1 : 0.5))
            }
            .buttonStyle(.plain)
            .help("Remove project")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .popover(isPresented: $showingUpdates, arrowEdge: .trailing) {
            EASUpdatesView(projectName: project.name, projectPath: project.path)
        }
        .contextMenu {
            Button {
                showingUpdates = true
            } label: {
                Label("View latest updates", systemImage: "arrow.up.doc")
            }
            Button {
                BuildAction.openURL("file://\(project.path)")
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            Divider()
            Button {
                renamePrompt()
            } label: {
                Label("Rename…", systemImage: "pencil")
            }
            Button {
                showingColorPicker = true
            } label: {
                Label("Change color…", systemImage: "paintpalette")
            }
            Divider()
            Button(role: .destructive) {
                onRemove()
            } label: {
                Label("Remove project", systemImage: "trash")
            }
        }
    }

    @MainActor
    private func renamePrompt() {
        let alert = NSAlert()
        alert.messageText = "Rename project"
        alert.informativeText = project.path
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = project.name
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newName.isEmpty else { return }
            watcher.updateProject(project) { $0.name = newName }
        }
    }
}

// MARK: - Color picker

struct ProjectColorPicker: View {
    let current: ProjectColor
    let onSelect: (ProjectColor) -> Void

    private let columns = Array(repeating: GridItem(.fixed(22), spacing: 6), count: 5)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project color")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(ProjectColor.allCases, id: \.self) { c in
                    Button {
                        onSelect(c)
                    } label: {
                        ZStack {
                            Circle().fill(c.swiftUIColor)
                            if c == current {
                                Circle()
                                    .stroke(Color.primary.opacity(0.8), lineWidth: 2)
                                    .padding(-2)
                            }
                        }
                        .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help(c.displayName)
                }
            }
        }
        .padding(12)
    }
}

// MARK: - Filter chip

struct FilterChip: View {
    let label: String
    let isOn: Bool
    let accent: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let accent {
                    Circle().fill(accent).frame(width: 5, height: 5)
                }
                Text(label)
                    .font(.system(size: 10, weight: isOn ? .semibold : .regular))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .foregroundColor(isOn ? .white : .secondary)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isOn ? (accent ?? Color.accentColor) : Color.secondary.opacity(0.15))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Build row

struct BuildRow: View {
    let watcher: BuildWatcher
    let annotated: AnnotatedBuild
    let tick: Date
    @State private var copied = false
    @State private var showingQR = false
    @State private var working = false

    private var build: EASBuild { annotated.build }
    private var project: Project { annotated.project }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: build.statusSymbol)
                .foregroundColor(statusColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(build.prettyPlatform)
                        .font(.system(size: 13, weight: .semibold))
                    if let profile = build.buildProfile {
                        Text("·").foregroundColor(.secondary)
                        Text(profile).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                    if let version = build.appVersion {
                        Text("·").foregroundColor(.secondary)
                        Text("v\(version)").font(.system(size: 12)).foregroundColor(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    projectChip
                    Text(statusLabel).font(.caption).foregroundColor(.secondary)
                    Text("·").foregroundColor(.secondary)
                    Text(build.relativeTime(now: tick)).font(.caption).foregroundColor(.secondary)
                }
            }

            Spacer()

            if working {
                ProgressView().controlSize(.small).frame(width: 20)
            } else {
                if let url = build.installURL {
                    Button {
                        BuildAction.copy(url)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .foregroundColor(copied ? .green : .accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(copied ? "Copied!" : "Copy install link")
                }
                actionMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            BuildAction.openURL(build.logsURL ?? build.installURL)
        }
        .popover(isPresented: $showingQR, arrowEdge: .trailing) {
            if let url = build.installURL {
                QRCodeView(text: url)
            }
        }
        .contextMenu { menuItems }
    }

    @ViewBuilder
    private var actionMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundColor(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder
    private var menuItems: some View {
        if let logs = build.logsURL {
            Button {
                BuildAction.openURL(logs)
            } label: {
                Label("View logs on expo.dev", systemImage: "doc.text.magnifyingglass")
            }
        }
        if let url = build.installURL {
            Button {
                BuildAction.copy(url)
            } label: {
                Label("Copy install link", systemImage: "doc.on.doc")
            }
            Button {
                showingQR = true
            } label: {
                Label("Show QR code", systemImage: "qrcode")
            }
            Button {
                downloadAndReveal(url)
            } label: {
                Label("Download artifact", systemImage: "arrow.down.circle")
            }
            if build.isAndroid {
                Button {
                    downloadAndAdbInstall(url)
                } label: {
                    Label("Install via adb", systemImage: "smartphone")
                }
            }
        }
        if let hash = build.gitCommitHash {
            Divider()
            Button {
                BuildAction.copy(hash)
            } label: {
                Label("Copy commit (\(String(hash.prefix(7))))", systemImage: "number")
            }
            Button {
                openCommitOnGitHub(hash: hash)
            } label: {
                Label("Open commit on GitHub", systemImage: "arrow.up.right.square")
            }
        }
        if build.isInFlight {
            Divider()
            Button(role: .destructive) {
                cancelBuild()
            } label: {
                Label("Cancel build", systemImage: "stop.circle")
            }
        }
    }

    // MARK: - Action handlers

    private func downloadAndReveal(_ url: String) {
        Task {
            await MainActor.run { working = true }
            defer { Task { @MainActor in working = false } }
            do {
                let dest = try await BuildAction.downloadArtifact(from: url)
                await MainActor.run { BuildAction.revealInFinder(dest) }
            } catch {
                BuildAction.showAlert(
                    title: "Download failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func downloadAndAdbInstall(_ url: String) {
        Task {
            await MainActor.run { working = true }
            defer { Task { @MainActor in working = false } }
            do {
                let dest = try await BuildAction.downloadArtifact(from: url)
                try await BuildAction.adbInstall(apkPath: dest.path)
                BuildAction.showAlert(
                    title: "Installed",
                    message: "\(dest.lastPathComponent) installed via adb.",
                    style: .informational
                )
            } catch {
                BuildAction.showAlert(
                    title: "adb install failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func openCommitOnGitHub(hash: String) {
        Task {
            guard let remote = await BuildAction.gitRemoteURL(projectPath: project.path),
                  let url = BuildAction.githubCommitURL(remote: remote, hash: hash) else {
                BuildAction.showAlert(
                    title: "Couldn't open commit",
                    message: "No GitHub remote found for \(project.name)."
                )
                return
            }
            BuildAction.openURL(url.absoluteString)
        }
    }

    private func cancelBuild() {
        Task {
            await MainActor.run { working = true }
            defer { Task { @MainActor in working = false } }
            do {
                try await BuildAction.cancelBuild(projectPath: project.path, buildId: build.id)
                await watcher.refresh()
            } catch {
                BuildAction.showAlert(
                    title: "Cancel failed",
                    message: error.localizedDescription
                )
            }
        }
    }

    private var statusLabel: String {
        // For in-flight builds, show live elapsed time instead of just the status.
        if build.isInFlight {
            return "\(build.prettyStatus) · \(build.elapsedDuration(now: tick))"
        }
        return build.prettyStatus
    }

    private var projectChip: some View {
        Text(project.name)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(project.color.swiftUIColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(project.color.swiftUIColor.opacity(0.15))
            )
            .lineLimit(1)
    }

    private var statusColor: Color {
        switch build.status {
        case "FINISHED": return .green
        case "ERRORED": return .red
        case "CANCELED": return .gray
        case "IN_PROGRESS": return .orange
        case "IN_QUEUE", "NEW", "PENDING": return .yellow
        default: return .gray
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
