import Foundation
import SwiftUI
import UserNotifications

// MARK: - Models

struct VercelConfig: Codable, Equatable {
    var token: String
    var teamId: String?

    var hasToken: Bool { !token.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct VercelDeployment: Codable, Identifiable, Hashable {
    let uid: String
    let name: String?
    let url: String?
    let state: String
    let created: Int64
    let target: String?
    let inspectorUrl: String?
    let meta: Meta?
    let creator: Creator?

    var id: String { uid }

    struct Meta: Codable, Hashable {
        let githubCommitMessage: String?
        let githubCommitSha: String?
        let githubCommitRef: String?
    }

    struct Creator: Codable, Hashable {
        let username: String?
    }

    var createdAt: Date { Date(timeIntervalSince1970: TimeInterval(created) / 1000) }

    var isInFlight: Bool {
        ["BUILDING", "QUEUED", "INITIALIZING"].contains(state.uppercased())
    }

    var prettyState: String {
        state.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var statusSymbol: String {
        switch state.uppercased() {
        case "READY": return "checkmark.circle.fill"
        case "ERROR": return "xmark.octagon.fill"
        case "CANCELED": return "minus.circle.fill"
        case "BUILDING": return "arrow.triangle.2.circlepath"
        case "QUEUED", "INITIALIZING": return "clock.fill"
        default: return "questionmark.circle"
        }
    }

    func relativeTime(now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(createdAt)
        if elapsed < 60 { return "\(Int(elapsed))s ago" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }

    func elapsedDuration(now: Date = Date()) -> String {
        let elapsed = Int(max(0, now.timeIntervalSince(createdAt)))
        let h = elapsed / 3600, m = (elapsed % 3600) / 60, s = elapsed % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    var fullURL: String? { url.map { "https://\($0)" } }
}

// MARK: - Service

enum VercelError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case decoding(String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add a Vercel API token to start watching deployments."
        case .unauthorized: return "Vercel token is invalid or expired."
        case .http(let code, let msg): return "Vercel API error \(code): \(msg)"
        case .decoding(let msg): return "Failed to decode Vercel response: \(msg)"
        }
    }
}

struct VercelService {
    static func fetchDeployments(config: VercelConfig, limit: Int = 15) async throws -> [VercelDeployment] {
        guard config.hasToken else { throw VercelError.notConfigured }

        var components = URLComponents(string: "https://api.vercel.com/v6/deployments")!
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let team = config.teamId, !team.isEmpty {
            items.append(URLQueryItem(name: "teamId", value: team))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw VercelError.http(0, "no response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw VercelError.unauthorized
        }
        if !(200..<300 ~= http.statusCode) {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw VercelError.http(http.statusCode, msg)
        }

        struct Envelope: Codable { let deployments: [VercelDeployment] }
        do {
            return try JSONDecoder().decode(Envelope.self, from: data).deployments
        } catch {
            throw VercelError.decoding(String(describing: error))
        }
    }
}

// MARK: - Watcher

@MainActor
final class VercelWatcher: ObservableObject {
    @Published var config: VercelConfig {
        didSet {
            saveConfig()
            Task { await refresh() }
        }
    }
    @Published var deployments: [VercelDeployment] = []
    @Published var error: String?
    @Published var isRefreshing = false
    @Published var lastUpdated: Date?
    @Published var tick: Date = Date()

    private var pollTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var lastSeenState: [String: String] = [:]
    private var hasLoadedOnce = false
    private static let configKey = "vercelConfig"

    init() {
        self.config = Self.loadConfig() ?? VercelConfig(token: "")
        startPolling()
    }

    var menuIcon: String {
        if !config.hasToken { return "triangle" }
        if deployments.contains(where: { $0.isInFlight }) { return "triangle.fill" }
        if let latest = deployments.first {
            switch latest.state.uppercased() {
            case "ERROR": return "exclamationmark.triangle.fill"
            case "READY": return "triangle.fill"
            default: return "triangle"
            }
        }
        return "triangle"
    }

    private static func loadConfig() -> VercelConfig? {
        guard let data = UserDefaults.standard.data(forKey: configKey) else { return nil }
        return try? JSONDecoder().decode(VercelConfig.self, from: data)
    }

    private func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            await self?.refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                if Task.isCancelled { return }
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard config.hasToken else {
            deployments = []
            error = nil
            updateTickerIfNeeded()
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let new = try await VercelService.fetchDeployments(config: config)
            if hasLoadedOnce { notifyStateChanges(new) }
            for d in new { lastSeenState[d.uid] = d.state }
            deployments = new
            error = nil
            lastUpdated = Date()
            hasLoadedOnce = true
            updateTickerIfNeeded()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func updateTickerIfNeeded() {
        let need = deployments.contains { $0.isInFlight }
        if need && tickTimer == nil {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { [weak self] in self?.tick = Date() }
            }
        } else if !need && tickTimer != nil {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    private func notifyStateChanges(_ new: [VercelDeployment]) {
        for d in new {
            let prev = lastSeenState[d.uid]
            guard let prev, prev != d.state else { continue }
            let label = "\(d.name ?? "Vercel")\(d.target.map { " · \($0)" } ?? "")"
            let upper = d.state.uppercased()
            if upper == "READY" {
                notify(title: "Vercel deploy ready", body: label, url: d.fullURL ?? d.inspectorUrl)
            } else if upper == "ERROR" {
                notify(title: "Vercel deploy failed", body: label, url: d.inspectorUrl)
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
