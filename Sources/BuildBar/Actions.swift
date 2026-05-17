import Foundation
import AppKit

enum BuildAction {
    // MARK: - Simple helpers

    static func openURL(_ string: String?) {
        guard let s = string, let url = URL(string: s) else { return }
        NSWorkspace.shared.open(url)
    }

    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    static func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - EAS

    static func cancelBuild(projectPath: String, buildId: String) async throws {
        try await runShell("cd \"\(projectPath)\" && eas build:cancel \(buildId) --non-interactive")
    }

    // MARK: - Artifact download / install

    static func downloadArtifact(from urlString: String) async throws -> URL {
        guard let url = URL(string: urlString) else {
            throw NSError(domain: "BuildBar", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        let (tempURL, response) = try await URLSession.shared.download(from: url)
        let suggested = (response as? HTTPURLResponse)?.suggestedFilename
            ?? response.suggestedFilename
            ?? url.lastPathComponent
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        let dest = downloads.appendingPathComponent(suggested)
        if fm.fileExists(atPath: dest.path) {
            try? fm.removeItem(at: dest)
        }
        try fm.moveItem(at: tempURL, to: dest)
        return dest
    }

    static func adbInstall(apkPath: String) async throws {
        try await runShell("adb install -r \"\(apkPath)\"")
    }

    // MARK: - Git / GitHub

    static func gitRemoteURL(projectPath: String) async -> String? {
        let out = (try? await captureShell("cd \"\(projectPath)\" && git remote get-url origin")) ?? ""
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func githubCommitURL(remote: String, hash: String) -> URL? {
        var s = remote
        if s.hasPrefix("git@github.com:") {
            s = String(s.dropFirst("git@github.com:".count))
        } else if let range = s.range(of: "github.com/") {
            s = String(s[range.upperBound...])
        } else {
            return nil
        }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        return URL(string: "https://github.com/\(s)/commit/\(hash)")
    }

    static func showAlert(title: String, message: String? = nil, style: NSAlert.Style = .warning) {
        let run = {
            let alert = NSAlert()
            alert.messageText = title
            if let message { alert.informativeText = message }
            alert.alertStyle = style
            alert.runModal()
        }
        if Thread.isMainThread {
            run()
        } else {
            DispatchQueue.main.async { run() }
        }
    }

    // MARK: - Shell

    @discardableResult
    private static func runShell(_ cmd: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", cmd]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let errStr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "command failed"
            throw NSError(
                domain: "BuildBar",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: errStr.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
        return String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    private static func captureShell(_ cmd: String) async throws -> String {
        try await runShell(cmd)
    }
}
