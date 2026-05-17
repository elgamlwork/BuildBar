import Foundation
import SwiftUI
import UserNotifications

@MainActor
final class BuildWatcher: ObservableObject {
    @Published var builds: [AnnotatedBuild] = []
    @Published var perProjectErrors: [UUID: String] = [:]
    @Published var isRefreshing = false
    @Published var lastUpdated: Date?
    @Published var tick: Date = Date()
    @Published var hasAuthError: Bool = false
    @Published var projects: [Project] {
        didSet {
            saveProjects()
            Task { await refresh() }
        }
    }
    @Published var isPaused: Bool {
        didSet {
            UserDefaults.standard.set(isPaused, forKey: Self.pausedKey)
            restartPolling()
        }
    }
    @Published var pollIntervalSeconds: Int {
        didSet {
            UserDefaults.standard.set(pollIntervalSeconds, forKey: Self.intervalKey)
            restartPolling()
        }
    }

    private var pollTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var lastSeenStatus: [String: String] = [:]
    private var consecutiveFailures: Int = 0
    private var hasLoadedOnce = false

    private static let projectsKey = "projects"
    private static let legacyKey = "projectPath"
    private static let pausedKey = "isPaused"
    private static let intervalKey = "pollIntervalSeconds"
    static let intervalOptions: [Int] = [15, 30, 60, 300]

    init() {
        let ud = UserDefaults.standard
        self.projects = Self.loadProjects()
        self.isPaused = ud.bool(forKey: Self.pausedKey)
        let savedInterval = ud.integer(forKey: Self.intervalKey)
        self.pollIntervalSeconds = Self.intervalOptions.contains(savedInterval) ? savedInterval : 30
        if let snapshot = Self.loadCache() {
            self.builds = snapshot.builds
            self.lastUpdated = snapshot.savedAt
            for ab in snapshot.builds { lastSeenStatus[ab.build.id] = ab.build.status }
        }
        startPolling()
    }

    var menuIcon: String {
        if hasAuthError { return "person.crop.circle.badge.exclamationmark" }
        if builds.contains(where: { $0.build.isInFlight }) { return "hammer.fill" }
        if let latest = builds.first {
            switch latest.build.status {
            case "ERRORED": return "exclamationmark.triangle.fill"
            case "FINISHED": return "checkmark.seal.fill"
            default: return "hammer"
            }
        }
        return "hammer"
    }

    var hasAnyError: Bool { !perProjectErrors.isEmpty }

    /// Effective polling delay including exponential backoff after consecutive failures.
    var effectiveIntervalSeconds: Int {
        let multiplier = min(1 << min(consecutiveFailures, 4), 16) // 1, 2, 4, 8, 16
        return pollIntervalSeconds * multiplier
    }

    // MARK: - Project management

    func addProject(path: String) {
        guard !projects.contains(where: { $0.path == path }) else { return }
        projects.append(.fromPath(path))
    }

    func removeProject(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        perProjectErrors.removeValue(forKey: project.id)
        builds.removeAll { $0.project.id == project.id }
        saveCache()
    }

    func updateProject(_ project: Project, mutate: (inout Project) -> Void) {
        guard let idx = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var copy = projects[idx]
        mutate(&copy)
        projects[idx] = copy
        // Refresh annotated builds so chips re-render with the new name/color.
        builds = builds.map { ab in
            ab.project.id == copy.id ? AnnotatedBuild(project: copy, build: ab.build) : ab
        }
    }

    private static func loadProjects() -> [Project] {
        let ud = UserDefaults.standard
        if let data = ud.data(forKey: projectsKey),
           let decoded = try? JSONDecoder().decode([Project].self, from: data) {
            return decoded
        }
        if let legacy = ud.string(forKey: legacyKey), !legacy.isEmpty {
            let migrated = [Project.fromPath(legacy)]
            if let data = try? JSONEncoder().encode(migrated) {
                ud.set(data, forKey: projectsKey)
            }
            ud.removeObject(forKey: legacyKey)
            return migrated
        }
        return []
    }

    private func saveProjects() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        UserDefaults.standard.set(data, forKey: Self.projectsKey)
    }

    // MARK: - Disk cache

    private static func cacheURL() -> URL? {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = appSupport.appendingPathComponent("BuildBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.json")
    }

    private static func loadCache() -> CacheSnapshot? {
        guard let url = cacheURL(), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CacheSnapshot.self, from: data)
    }

    private func saveCache() {
        guard let url = Self.cacheURL() else { return }
        let snapshot = CacheSnapshot(builds: builds, savedAt: lastUpdated ?? Date())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Polling

    func startPolling() { restartPolling() }

    private func restartPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                guard let self else { return }
                let delay = self.isPaused ? 60 : self.effectiveIntervalSeconds
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                if Task.isCancelled { return }
                if !self.isPaused { await self.refresh() }
            }
        }
    }

    func refresh() async {
        guard !projects.isEmpty else {
            builds = []
            perProjectErrors = [:]
            hasAuthError = false
            updateTickerIfNeeded()
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        let snapshot = projects
        var collected: [AnnotatedBuild] = []
        var errors: [UUID: String] = [:]
        var successCount = 0

        await withTaskGroup(of: (Project, Result<[EASBuild], Error>).self) { group in
            for project in snapshot {
                group.addTask {
                    do {
                        let builds = try await EASService.fetchBuilds(projectPath: project.path)
                        return (project, .success(builds))
                    } catch {
                        return (project, .failure(error))
                    }
                }
            }
            for await (project, result) in group {
                switch result {
                case .success(let builds):
                    successCount += 1
                    collected.append(contentsOf: builds.map { AnnotatedBuild(project: project, build: $0) })
                case .failure(let err):
                    errors[project.id] = (err as? LocalizedError)?.errorDescription ?? "\(err)"
                }
            }
        }

        collected.sort { $0.build.createdAt > $1.build.createdAt }

        if hasLoadedOnce { notifyStatusChanges(collected) }
        for ab in collected { lastSeenStatus[ab.build.id] = ab.build.status }

        // Backoff: only when every project failed.
        if successCount == 0 && !errors.isEmpty {
            consecutiveFailures = min(consecutiveFailures + 1, 6)
        } else {
            consecutiveFailures = 0
        }

        // Auth-error detection from any project's error message.
        hasAuthError = errors.values.contains(where: Self.looksLikeAuthError)

        self.builds = collected
        self.perProjectErrors = errors
        self.lastUpdated = Date()
        self.hasLoadedOnce = true

        saveCache()
        updateTickerIfNeeded()
    }

    private static func looksLikeAuthError(_ msg: String) -> Bool {
        let lower = msg.lowercased()
        return lower.contains("not logged in")
            || lower.contains("please log in")
            || lower.contains("eas login")
            || lower.contains("unauthorized")
            || lower.contains("authentication")
    }

    // MARK: - Tick timer (for live elapsed-time on in-flight builds)

    private func updateTickerIfNeeded() {
        let needTicker = builds.contains { $0.build.isInFlight }
        if needTicker && tickTimer == nil {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick = Date() }
            }
        } else if !needTicker && tickTimer != nil {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    // MARK: - Notifications

    private func notifyStatusChanges(_ newBuilds: [AnnotatedBuild]) {
        for ab in newBuilds {
            let prev = lastSeenStatus[ab.build.id]
            guard let prev, prev != ab.build.status else { continue }
            let label = "\(ab.project.name) · \(ab.build.prettyPlatform)\(ab.build.buildProfile.map { " · \($0)" } ?? "")"
            if ab.build.status == "FINISHED" {
                notify(title: "Build finished", body: "\(label) is ready to install", url: ab.build.installURL)
            } else if ab.build.status == "ERRORED" {
                notify(title: "Build failed", body: "\(label) errored", url: ab.build.installURL)
            }
        }
    }

    private func notify(title: String, body: String, url: String?) {
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog("BuildBar: skipping notification (run via run.sh): \(title) — \(body)")
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
