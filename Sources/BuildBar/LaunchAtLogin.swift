import Foundation
import ServiceManagement
import AppKit

enum LaunchAtLogin {
    /// Whether the app is in a real `.app` bundle (required for SMAppService).
    static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    static var isEnabled: Bool {
        guard isBundled else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        guard isBundled else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = enabled ? "Couldn't enable Launch at Login" : "Couldn't disable Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}
