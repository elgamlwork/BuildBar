import SwiftUI
import AppKit
import UserNotifications

@main
struct BuildBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var watcher = BuildWatcher()
    @StateObject private var vercel = VercelWatcher()
    @StateObject private var github = GitHubWatcher()

    var body: some Scene {
        MenuBarExtra {
            BuildMenuView(watcher: watcher, vercel: vercel, github: github)
        } label: {
            Image(systemName: watcher.menuIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Only request notifications if we're running inside a real .app bundle.
        // The raw `swift run` binary has no bundle identifier and UNUserNotificationCenter aborts.
        if Bundle.main.bundleIdentifier != nil {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    // Show banners even when the menu bar dropdown is open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Click a notification → open the build URL.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
