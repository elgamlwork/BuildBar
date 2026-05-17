import Foundation

enum ProjectColor: String, Codable, CaseIterable, Hashable {
    case accent, blue, green, orange, red, purple, pink, teal, yellow, indigo

    var displayName: String {
        switch self {
        case .accent: return "Default"
        default: return rawValue.capitalized
        }
    }
}

struct Project: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var color: ProjectColor

    init(id: UUID = UUID(), name: String, path: String, color: ProjectColor = .accent) {
        self.id = id
        self.name = name
        self.path = path
        self.color = color
    }

    enum CodingKeys: String, CodingKey { case id, name, path, color }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.path = try c.decode(String.self, forKey: .path)
        // Backward-compatible: old JSON without color decodes to .accent.
        self.color = (try? c.decode(ProjectColor.self, forKey: .color)) ?? .accent
    }

    static func fromPath(_ path: String) -> Project {
        let name = (path as NSString).lastPathComponent
        return Project(name: name.isEmpty ? path : name, path: path)
    }
}

struct AnnotatedBuild: Identifiable, Hashable, Codable {
    let project: Project
    let build: EASBuild
    var id: String { "\(project.id.uuidString)-\(build.id)" }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: AnnotatedBuild, rhs: AnnotatedBuild) -> Bool { lhs.id == rhs.id }
}

struct CacheSnapshot: Codable {
    let builds: [AnnotatedBuild]
    let savedAt: Date
}

struct EASBuild: Codable, Identifiable, Hashable {
    let id: String
    let status: String
    let platform: String
    let buildProfile: String?
    let createdAt: String
    let completedAt: String?
    let appVersion: String?
    let gitCommitHash: String?
    let artifacts: Artifacts?
    let project: ProjectInfo?

    struct Artifacts: Codable, Hashable {
        let buildUrl: String?
        let applicationArchiveUrl: String?
    }

    struct ProjectInfo: Codable, Hashable {
        let slug: String?
        let ownerAccount: OwnerAccount?
    }

    struct OwnerAccount: Codable, Hashable {
        let name: String?
    }

    var logsURL: String? {
        guard let account = project?.ownerAccount?.name,
              let slug = project?.slug else { return nil }
        return "https://expo.dev/accounts/\(account)/projects/\(slug)/builds/\(id)"
    }

    var isAndroid: Bool { platform.uppercased() == "ANDROID" }
    var isIOS: Bool { platform.uppercased() == "IOS" }

    var installURL: String? {
        artifacts?.buildUrl ?? artifacts?.applicationArchiveUrl
    }

    var isInFlight: Bool {
        ["IN_PROGRESS", "IN_QUEUE", "NEW", "PENDING"].contains(status)
    }

    var statusSymbol: String {
        switch status {
        case "FINISHED": return "checkmark.circle.fill"
        case "ERRORED": return "xmark.octagon.fill"
        case "CANCELED": return "minus.circle.fill"
        case "IN_PROGRESS": return "arrow.triangle.2.circlepath"
        case "IN_QUEUE", "NEW", "PENDING": return "clock.fill"
        default: return "questionmark.circle"
        }
    }

    var prettyStatus: String {
        status.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var prettyPlatform: String {
        platform == "IOS" ? "iOS" : platform.capitalized
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

    /// "5m 23s" style — used for in-flight builds.
    func elapsedDuration(now: Date = Date()) -> String {
        guard let date = createdAtDate else { return "" }
        let elapsed = Int(max(0, now.timeIntervalSince(date)))
        let hours = elapsed / 3600
        let minutes = (elapsed % 3600) / 60
        let seconds = elapsed % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}
