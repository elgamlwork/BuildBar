import Foundation
import SwiftUI
import UserNotifications

// MARK: - Models

struct GitHubRepoConfig: Codable, Identifiable, Hashable {
    let id: UUID
    var slug: String   // "owner/repo"
    var color: ProjectColor

    init(id: UUID = UUID(), slug: String, color: ProjectColor = .accent) {
        self.id = id
        self.slug = slug
        self.color = color
    }

    var displayName: String {
        slug.split(separator: "/").last.map(String.init) ?? slug
    }
}

struct GitHubRun: Codable, Identifiable, Hashable {
    let databaseId: Int
    let displayTitle: String?
    let workflowName: String?
    let headBranch: String?
    let event: String?
    let status: String
    let conclusion: String?
    let url: String?
    let createdAt: String
    let updatedAt: String?

    var id: Int { databaseId }

    var isInFlight: Bool {
        ["in_progress", "queued", "requested", "waiting", "pending"].contains(status.lowercased())
    }

    var prettyStatus: String {
        if status.lowercased() == "completed" {
            return (conclusion ?? "Completed").replacingOccurrences(of: "_", with: " ").capitalized
        }
        return status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var statusSymbol: String {
        switch status.lowercased() {
        case "completed":
            switch (conclusion ?? "").lowercased() {
            case "success": return "checkmark.circle.fill"
            case "failure": return "xmark.octagon.fill"
            case "cancelled": return "minus.circle.fill"
            case "skipped": return "forward.fill"
            default: return "questionmark.circle"
            }
        case "in_progress": return "arrow.triangle.2.circlepath"
        case "queued", "waiting", "pending", "requested": return "clock.fill"
        default: return "questionmark.circle"
        }
    }

    var createdAtDate: Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: createdAt) ?? ISO8601DateFormatter().date(from: createdAt)
    }

    func relativeTime(now: Date = Date()) -> String {
        guard let date = createdAtDate else { return "" }
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return "\(Int(elapsed))s ago" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }

    func elapsedDuration(now: Date = Date()) -> String {
        guard let date = createdAtDate else { return "" }
        let elapsed = Int(max(0, now.timeIntervalSince(date)))
        let h = elapsed / 3600, m = (elapsed % 3600) / 60, s = elapsed % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }
}

struct AnnotatedRun: Identifiable, Hashable {
    let repo: GitHubRepoConfig
    let run: GitHubRun
    var id: String { "\(repo.id.uuidString)-\(run.id)" }
}

// MARK: - Service

enum GHError: LocalizedError {
    case ghNotInstalled
    case notLoggedIn
    case commandFailed(String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .ghNotInstalled: return "Install GitHub CLI (`brew install gh`) and log in (`gh auth login`)."
        case .notLoggedIn: return "Run `gh auth login` to authenticate the GitHub CLI."
        case .commandFailed(let msg): return msg
        case .decoding(let msg): return "Couldn't parse gh output: \(msg)"
        }
    }
}

struct GitHubService {
    static func fetchRuns(repo: String, limit: Int = 10) async throws -> [GitHubRun] {
        let cmd = "gh run list --repo \"\(repo)\" --limit \(limit) --json databaseId,displayTitle,workflowName,headBranch,event,status,conclusion,url,createdAt,updatedAt"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", cmd]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let lower = stderr.lowercased()
            if lower.contains("command not found") || lower.contains("not found: gh") {
                throw GHError.ghNotInstalled
            }
            if lower.contains("authentication") || lower.contains("auth login") || lower.contains("not logged") {
                throw GHError.notLoggedIn
            }
            throw GHError.commandFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        do {
            return try JSONDecoder().decode([GitHubRun].self, from: data)
        } catch {
            throw GHError.decoding(String(describing: error))
        }
    }
}

// MARK: - Watcher

@MainActor
final class GitHubWatcher: ObservableObject {
    @Published var repos: [GitHubRepoConfig] {
        didSet {
            saveRepos()
            Task { await refresh() }
        }
    }
    @Published var runs: [AnnotatedRun] = []
    @Published var perRepoErrors: [UUID: String] = [:]
    @Published var isRefreshing = false
    @Published var lastUpdated: Date?
    @Published var tick: Date = Date()

    private var pollTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var lastSeenStatus: [Int: String] = [:]
    private var hasLoadedOnce = false
    private static let reposKey = "githubRepos"

    init() {
        self.repos = Self.loadRepos()
        startPolling()
    }

    var menuIcon: String {
        if runs.contains(where: { $0.run.isInFlight }) { return "gearshape.2.fill" }
        if let latest = runs.first {
            let lower = (latest.run.conclusion ?? latest.run.status).lowercased()
            if lower == "failure" { return "exclamationmark.triangle.fill" }
            if lower == "success" { return "checkmark.seal.fill" }
        }
        return "gearshape.2"
    }

    func addRepo(slug: String) {
        let trimmed = slug.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.contains("/") else { return }
        guard !repos.contains(where: { $0.slug == trimmed }) else { return }
        repos.append(GitHubRepoConfig(slug: trimmed))
    }

    func removeRepo(_ repo: GitHubRepoConfig) {
        repos.removeAll { $0.id == repo.id }
        perRepoErrors.removeValue(forKey: repo.id)
        runs.removeAll { $0.repo.id == repo.id }
    }

    func updateRepo(_ repo: GitHubRepoConfig, mutate: (inout GitHubRepoConfig) -> Void) {
        guard let idx = repos.firstIndex(where: { $0.id == repo.id }) else { return }
        var copy = repos[idx]
        mutate(&copy)
        repos[idx] = copy
        runs = runs.map { $0.repo.id == copy.id ? AnnotatedRun(repo: copy, run: $0.run) : $0 }
    }

    private static func loadRepos() -> [GitHubRepoConfig] {
        guard let data = UserDefaults.standard.data(forKey: reposKey),
              let decoded = try? JSONDecoder().decode([GitHubRepoConfig].self, from: data)
        else { return [] }
        return decoded
    }

    private func saveRepos() {
        if let data = try? JSONEncoder().encode(repos) {
            UserDefaults.standard.set(data, forKey: Self.reposKey)
        }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45 * 1_000_000_000)
                if Task.isCancelled { return }
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard !repos.isEmpty else {
            runs = []
            perRepoErrors = [:]
            updateTickerIfNeeded()
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        var collected: [AnnotatedRun] = []
        var errors: [UUID: String] = [:]

        await withTaskGroup(of: (GitHubRepoConfig, Result<[GitHubRun], Error>).self) { group in
            for repo in repos {
                group.addTask {
                    do {
                        let runs = try await GitHubService.fetchRuns(repo: repo.slug)
                        return (repo, .success(runs))
                    } catch {
                        return (repo, .failure(error))
                    }
                }
            }
            for await (repo, result) in group {
                switch result {
                case .success(let runs):
                    collected.append(contentsOf: runs.map { AnnotatedRun(repo: repo, run: $0) })
                case .failure(let err):
                    errors[repo.id] = (err as? LocalizedError)?.errorDescription ?? "\(err)"
                }
            }
        }

        collected.sort { $0.run.createdAt > $1.run.createdAt }

        if hasLoadedOnce { notifyStatusChanges(collected) }
        for r in collected { lastSeenStatus[r.run.id] = r.run.status }

        runs = collected
        perRepoErrors = errors
        lastUpdated = Date()
        hasLoadedOnce = true
        updateTickerIfNeeded()
    }

    private func updateTickerIfNeeded() {
        let need = runs.contains { $0.run.isInFlight }
        if need && tickTimer == nil {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { [weak self] in self?.tick = Date() }
            }
        } else if !need && tickTimer != nil {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    private func notifyStatusChanges(_ new: [AnnotatedRun]) {
        for ar in new {
            let prev = lastSeenStatus[ar.run.id]
            guard let prev, prev != ar.run.status else { continue }
            if ar.run.status.lowercased() == "completed" {
                let conclusion = (ar.run.conclusion ?? "").lowercased()
                let label = "\(ar.repo.displayName) · \(ar.run.workflowName ?? "workflow")"
                if conclusion == "success" {
                    notify(title: "Workflow passed", body: label, url: ar.run.url)
                } else if conclusion == "failure" {
                    notify(title: "Workflow failed", body: label, url: ar.run.url)
                }
            }
        }
    }

    private func notify(title: String, body: String, url: String?) {
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog("BuildBar: skipping notification: \(title) — \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let url { content.userInfo["url"] = url }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
