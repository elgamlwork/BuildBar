import Foundation

enum EASError: LocalizedError {
    case noProjectFolder
    case commandFailed(String)
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .noProjectFolder:
            return "Pick your Expo project folder from the menu to start watching builds."
        case .commandFailed(let msg):
            return msg
        case .decodingFailed(let msg):
            return "Couldn't parse eas output: \(msg)"
        }
    }
}

struct EASService {
    static func fetchBuilds(projectPath: String, limit: Int = 10) async throws -> [EASBuild] {
        guard !projectPath.isEmpty else { throw EASError.noProjectFolder }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-l", "-c",
            "cd \"\(projectPath)\" && eas build:list --json --non-interactive --limit=\(limit)"
        ]

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()
        process.waitUntilExit()

        let data = out.fileHandleForReading.readDataToEndOfFile()

        if process.terminationStatus != 0 {
            let errStr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown error"
            throw EASError.commandFailed(errStr.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // eas may print human-readable lines before JSON; find the JSON array.
        let raw = String(data: data, encoding: .utf8) ?? ""
        let jsonString = extractJSONArray(from: raw) ?? raw
        let jsonData = jsonString.data(using: .utf8) ?? data

        do {
            return try JSONDecoder().decode([EASBuild].self, from: jsonData)
        } catch {
            throw EASError.decodingFailed(String(describing: error))
        }
    }

    private static func extractJSONArray(from text: String) -> String? {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]") else { return nil }
        return String(text[start...end])
    }
}
