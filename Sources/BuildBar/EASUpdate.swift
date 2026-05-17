import Foundation
import SwiftUI

struct EASUpdateGroup: Codable, Identifiable, Hashable {
    let id: String
    let group: String?
    let message: String?
    let runtimeVersion: String?
    let branch: String?
    let branchName: String?
    let createdAt: String?

    var displayBranch: String? { branch ?? branchName }

    var createdAtDate: Date? {
        guard let s = createdAt else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    var relativeTime: String {
        guard let date = createdAtDate else { return "" }
        let elapsed = Date().timeIntervalSince(date)
        if elapsed < 60 { return "\(Int(elapsed))s ago" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600))h ago" }
        return "\(Int(elapsed / 86400))d ago"
    }
}

struct EASUpdateService {
    static func fetchUpdates(projectPath: String, limit: Int = 10) async throws -> [EASUpdateGroup] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-l", "-c",
            "cd \"\(projectPath)\" && eas update:list --json --non-interactive --limit=\(limit)"
        ]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "command failed"
            throw NSError(
                domain: "EASUpdate",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: msg.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let json = extractJSONArray(from: raw) ?? raw
        guard let jsonData = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([EASUpdateGroup].self, from: jsonData)) ?? []
    }

    private static func extractJSONArray(from text: String) -> String? {
        guard let s = text.firstIndex(of: "["), let e = text.lastIndex(of: "]") else { return nil }
        return String(text[s...e])
    }
}

@MainActor
final class UpdatesLoader: ObservableObject {
    @Published var updates: [EASUpdateGroup] = []
    @Published var error: String?
    @Published var loading = false

    func load(projectPath: String) {
        loading = true
        error = nil
        Task {
            do {
                let result = try await EASUpdateService.fetchUpdates(projectPath: projectPath)
                await MainActor.run {
                    self.updates = result
                    self.loading = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    self.loading = false
                }
            }
        }
    }
}

struct EASUpdatesView: View {
    let projectName: String
    let projectPath: String
    @StateObject private var loader = UpdatesLoader()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Latest updates · \(projectName)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if loader.loading {
                    ProgressView().controlSize(.small)
                }
            }
            Divider()
            if let err = loader.error {
                Text(err).font(.caption).foregroundColor(.orange).lineLimit(3)
            } else if loader.updates.isEmpty && !loader.loading {
                Text("No updates published.").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(loader.updates.prefix(8)) { update in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let branch = update.displayBranch {
                                Text(branch)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.accentColor)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.15)))
                            }
                            if let runtime = update.runtimeVersion {
                                Text("runtime \(runtime)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text(update.relativeTime).font(.system(size: 10)).foregroundColor(.secondary)
                        }
                        if let msg = update.message, !msg.isEmpty {
                            Text(msg).font(.system(size: 11)).lineLimit(2)
                        }
                    }
                    .padding(.vertical, 3)
                    Divider()
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { loader.load(projectPath: projectPath) }
    }
}
