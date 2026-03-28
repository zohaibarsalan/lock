import ApplicationServices
import AppKit
import Foundation

@MainActor
final class PermissionService: ObservableObject {
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var screenRecordingGranted = false

    private let activityLog: ActivityLogStore
    private var observers: [NSObjectProtocol] = []

    init(activityLog: ActivityLogStore) {
        self.activityLog = activityLog
        observeApplicationLifecycle()
        refreshStatuses()
    }

    func refreshStatuses() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        activityLog.record("Requested Accessibility", detail: "Opened the system prompt for Accessibility access.")
        scheduleRefreshes()
    }

    func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        activityLog.record("Requested Screen Recording", detail: "Opened the system prompt for Screen Recording access.")
        scheduleRefreshes()
    }

    func openAccessibilitySettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openScreenRecordingSettings() {
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func openSystemSettings(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            return
        }

        NSWorkspace.shared.open(url)
        scheduleRefreshes()
    }

    private func observeApplicationLifecycle() {
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshStatuses()
                }
            }
        )
    }

    private func scheduleRefreshes() {
        for delay in [0.5, 1.5, 3.0] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refreshStatuses()
            }
        }
    }
}
