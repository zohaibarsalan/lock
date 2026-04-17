import Foundation

enum StartupServiceError: LocalizedError {
    case unsupportedExecutable

    var errorDescription: String? {
        switch self {
        case .unsupportedExecutable:
            "Launch at login works after you run the packaged app bundle."
        }
    }
}

@MainActor
final class StartupService: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published var lastErrorMessage = ""

    private let launchAgentLabel = "com.zohaib.lock"
    private let activityLog: ActivityLogStore

    init(activityLog: ActivityLogStore) {
        self.activityLog = activityLog
        refresh()
    }

    func refresh() {
        isEnabled = FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try installLaunchAgent()
                activityLog.record("Enabled Launch at Login", detail: "Lock will open automatically the next time you sign in.")
            } else {
                try removeLaunchAgent()
                activityLog.record("Disabled Launch at Login", detail: "Lock will no longer open automatically at sign in.")
            }

            lastErrorMessage = ""
            refresh()
        } catch {
            lastErrorMessage = error.localizedDescription
            activityLog.record("Launch at Login Error", detail: error.localizedDescription)
            refresh()
        }
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    private func installLaunchAgent() throws {
        let fileManager = FileManager.default
        let parentDirectory = launchAgentURL.deletingLastPathComponent()

        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)

        let programArguments = try startupProgramArguments()
        let plist: [String: Any] = [
            "Label": launchAgentLabel,
            "ProgramArguments": programArguments,
            "RunAtLoad": true,
            "KeepAlive": false
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentURL, options: .atomic)
    }

    private func removeLaunchAgent() throws {
        guard FileManager.default.fileExists(atPath: launchAgentURL.path) else {
            return
        }

        try FileManager.default.removeItem(at: launchAgentURL)
    }

    private func startupProgramArguments() throws -> [String] {
        let bundlePath = Bundle.main.bundlePath

        if bundlePath.hasSuffix(".app") {
            return ["/usr/bin/open", "-gj", bundlePath, "--args", LaunchArguments.background]
        }

        guard let executablePath = Bundle.main.executablePath else {
            throw StartupServiceError.unsupportedExecutable
        }

        return [executablePath, LaunchArguments.background]
    }
}
