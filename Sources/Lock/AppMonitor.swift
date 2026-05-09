@preconcurrency import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class AppMonitor: ObservableObject {
    private let workspace = NSWorkspace.shared
    private let notificationCenter = NSWorkspace.shared.notificationCenter
    private let lockStore: LockStore
    private let overlayCoordinator: OverlayCoordinator
    private let activityLog: ActivityLogStore
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.zohaib.lock",
        category: "AppMonitor"
    )

    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var unlockedProcessIDs = Set<pid_t>()
    private var pendingProcessIDs = Set<pid_t>()
    private var protectedBundleIdentifiers = Set<String>()
    private var hadPassword = false

    init(lockStore: LockStore, overlayCoordinator: OverlayCoordinator, activityLog: ActivityLogStore) {
        self.lockStore = lockStore
        self.overlayCoordinator = overlayCoordinator
        self.activityLog = activityLog
        self.protectedBundleIdentifiers = Set(lockStore.protectedApps.map(\.bundleIdentifier))
        self.hadPassword = lockStore.hasPassword
        start()
        observeLockConfiguration()
    }

    private func start() {
        observers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }

                MainActor.assumeIsolated {
                    self?.evaluate(app, delay: 0.15, source: "didLaunch")
                }
            }
        )

        observers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }

                MainActor.assumeIsolated {
                    self?.evaluate(app, delay: 0, source: "didActivate")
                }
            }
        )

        observers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didUnhideApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }

                MainActor.assumeIsolated {
                    self?.evaluate(app, delay: 0, source: "didUnhide")
                }
            }
        )

        observers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                    return
                }

                MainActor.assumeIsolated {
                    self?.logMonitorEvent("didTerminate", app: app)
                    self?.handleTermination(app: app)
                }
            }
        )

        observers.append(
            notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleActiveSpaceChange()
                }
            }
        )

        for app in workspace.runningApplications {
            evaluate(app, delay: 0, source: "startup")
        }

        scheduleInitialSweep()
    }

    private func observeLockConfiguration() {
        lockStore.$protectedApps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] apps in
                self?.logger.debug("protected-apps changed count=\(apps.count, privacy: .public)")
                self?.handleProtectedAppsChange(apps)
            }
            .store(in: &cancellables)

        lockStore.$hasPassword
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasPassword in
                self?.logger.debug("password-state changed hasPassword=\(hasPassword, privacy: .public)")
                self?.handlePasswordStateChange(hasPassword)
            }
            .store(in: &cancellables)
    }

    private func handleProtectedAppsChange(_ apps: [ProtectedApp]) {
        let updatedBundleIdentifiers = Set(apps.map(\.bundleIdentifier))
        let newlyProtected = updatedBundleIdentifiers.subtracting(protectedBundleIdentifiers)

        if !newlyProtected.isEmpty {
            unlockedProcessIDs = unlockedProcessIDs.filter { pid in
                guard let app = workspace.runningApplications.first(where: { $0.processIdentifier == pid }),
                      let bundleIdentifier = app.bundleIdentifier else {
                    return false
                }

                return !newlyProtected.contains(bundleIdentifier)
            }
        }

        protectedBundleIdentifiers = updatedBundleIdentifiers
        evaluateRunningApplications()
    }

    private func handlePasswordStateChange(_ hasPassword: Bool) {
        defer { hadPassword = hasPassword }

        guard hasPassword else {
            return
        }

        if !hadPassword {
            unlockedProcessIDs.removeAll()
        }

        evaluateRunningApplications()
    }

    private func evaluateRunningApplications() {
        for app in workspace.runningApplications {
            evaluate(app, delay: 0, source: "runningSweep")
        }
    }

    private func scheduleInitialSweep() {
        for delay in [0.35, 1.0] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.evaluateFrontmostApplication()
                self?.evaluateRunningApplications()
            }
        }
    }

    private func evaluateFrontmostApplication() {
        guard let app = workspace.frontmostApplication else {
            return
        }

        evaluate(app, delay: 0, source: "frontmost")
    }

    private func handleActiveSpaceChange() {
        logger.debug("active-space changed")
        overlayCoordinator.rehideLockedAppsForSpaceChange()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.evaluateFrontmostApplication()
        }
    }

    private func evaluate(_ app: NSRunningApplication, delay: TimeInterval, source: String) {
        guard lockStore.hasPassword else {
            return
        }

        guard let bundleIdentifier = app.bundleIdentifier,
              lockStore.isProtected(bundleIdentifier) else {
            return
        }

        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            logMonitorEvent("skip", app: app, detail: "self")
            return
        }

        let pid = app.processIdentifier

        if overlayCoordinator.isPresentingLock(for: pid) {
            logMonitorEvent("reassert-existing", app: app, detail: "source=\(source)")
            overlayCoordinator.reassertLock(for: app)
            return
        }

        guard !unlockedProcessIDs.contains(pid),
              !pendingProcessIDs.contains(pid) else {
            logMonitorEvent(
                "skip",
                app: app,
                detail: "source=\(source) unlocked=\(unlockedProcessIDs.contains(pid)) pending=\(pendingProcessIDs.contains(pid))"
            )
            return
        }

        pendingProcessIDs.insert(pid)
        logMonitorEvent("pending", app: app, detail: "source=\(source) delay=\(delay)")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else {
                return
            }

            self.pendingProcessIDs.remove(pid)

            guard !self.unlockedProcessIDs.contains(pid),
                  !app.isTerminated else {
                self.logMonitorEvent(
                    "pending-cancelled",
                    app: app,
                    detail: "unlocked=\(self.unlockedProcessIDs.contains(pid)) terminated=\(app.isTerminated)"
                )
                return
            }

            self.logMonitorEvent("present-lock", app: app, detail: "source=\(source)")
            self.activityLog.record("App Locked", detail: app.localizedName ?? bundleIdentifier)
            self.overlayCoordinator.presentLock(for: app) { unlocked in
                if unlocked {
                    self.unlockedProcessIDs.insert(pid)
                    self.logMonitorEvent("marked-unlocked", app: app)
                }
            }
        }
    }

    private func handleTermination(app: NSRunningApplication) {
        let pid = app.processIdentifier
        unlockedProcessIDs.remove(pid)
        pendingProcessIDs.remove(pid)
        overlayCoordinator.dismissIfMatching(processID: pid)
    }

    private func logMonitorEvent(_ event: String, app: NSRunningApplication, detail: String = "") {
        logger.debug(
            "event=\(event, privacy: .public) pid=\(app.processIdentifier, privacy: .public) app=\(app.localizedName ?? "unknown", privacy: .public) bundle=\(app.bundleIdentifier ?? "unknown", privacy: .public) \(detail, privacy: .public)"
        )
    }
}
