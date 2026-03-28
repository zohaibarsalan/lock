import AppKit
import Foundation

@MainActor
final class AppDiscoveryService: ObservableObject {
    @Published private(set) var installedApps: [InstalledApp] = []
    @Published private(set) var isRefreshing = false

    private var iconCache: [String: NSImage] = [:]
    private var hasLoaded = false

    func refreshIfNeeded() {
        guard !hasLoaded else {
            return
        }

        refresh()
    }

    func refresh() {
        guard !isRefreshing else {
            return
        }

        isRefreshing = true

        Task.detached(priority: .utility) {
            let scanned = InstalledAppScanner.scan()
            await MainActor.run {
                self.installedApps = scanned
                self.isRefreshing = false
                self.hasLoaded = true
            }
        }
    }

    func icon(for app: InstalledApp) -> NSImage {
        if let cached = iconCache[app.path] {
            return cached
        }

        let icon = NSWorkspace.shared.icon(forFile: app.path)
        icon.size = NSSize(width: 40, height: 40)
        iconCache[app.path] = icon
        return icon
    }
}

enum InstalledAppScanner {
    static func scan() -> [InstalledApp] {
        let roots = applicationRoots()
        let fileManager = FileManager.default
        var appsByBundleID: [String: InstalledApp] = [:]

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isApplicationKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "app" else {
                    continue
                }

                guard let bundle = Bundle(url: url),
                      let bundleIdentifier = bundle.bundleIdentifier else {
                    continue
                }

                let displayName =
                    (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent

                let installedApp = InstalledApp(
                    bundleIdentifier: bundleIdentifier,
                    displayName: displayName,
                    path: url.path
                )

                if appsByBundleID[bundleIdentifier] == nil {
                    appsByBundleID[bundleIdentifier] = installedApp
                }
            }
        }

        return appsByBundleID.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private static func applicationRoots() -> [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser

        return [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            home.appendingPathComponent("Applications"),
            home.appendingPathComponent("Downloads")
        ]
    }
}
