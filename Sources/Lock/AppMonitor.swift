@preconcurrency import AppKit
import Combine
import Foundation

@MainActor
final class AppMonitor: ObservableObject {
    private let workspace = NSWorkspace.shared
    private let notificationCenter = NSWorkspace.shared.notificationCenter
    private let lockStore: LockStore
    private let overlayCoordinator: OverlayCoordinator
    private let activityLog: ActivityLogStore

    private var observers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private var unlockedIdentities = Set<RunningAppIdentity>()
    private var pendingProcessIDs = Set<pid_t>()
    private var protectedBundleIdentifiers = Set<String>()
    private var hadPassword = false
    private var lastActiveApplication: NSRunningApplication?

    @Published private(set) var lastActiveApplicationName: String?
    @Published private(set) var canLockLastActiveApplication = false

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
                    self?.evaluate(app, delay: 0.15)
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
                    if app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                        self?.overlayCoordinator.activeApplicationChanged(to: app.processIdentifier)
                    }
                    self?.rememberLastActiveApplication(app)
                    self?.evaluate(app, delay: 0)
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
                    self?.evaluate(app, delay: 0)
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
                    self?.handleTermination(app: app)
                }
            }
        )

        scheduleInitialSweep()
    }

    private func observeLockConfiguration() {
        lockStore.$protectedApps
            .receive(on: DispatchQueue.main)
            .sink { [weak self] apps in
                self?.handleProtectedAppsChange(apps)
            }
            .store(in: &cancellables)

        lockStore.$hasPassword
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasPassword in
                self?.handlePasswordStateChange(hasPassword)
            }
            .store(in: &cancellables)
    }

    private func handleProtectedAppsChange(_ apps: [ProtectedApp]) {
        let updatedBundleIdentifiers = Set(apps.map(\.bundleIdentifier))
        let newlyProtected = updatedBundleIdentifiers.subtracting(protectedBundleIdentifiers)

        if !newlyProtected.isEmpty {
            unlockedIdentities = unlockedIdentities.filter { unlockedIdentity in
                guard let app = workspace.runningApplications.first(where: { $0.processIdentifier == unlockedIdentity.processID }),
                      identity(for: app) == unlockedIdentity else {
                    return false
                }

                return !newlyProtected.contains(unlockedIdentity.bundleIdentifier)
            }
        }

        protectedBundleIdentifiers = updatedBundleIdentifiers
        refreshLastActiveApplicationState()
        evaluateRunningApplications()
    }

    private func handlePasswordStateChange(_ hasPassword: Bool) {
        defer { hadPassword = hasPassword }

        guard hasPassword else {
            return
        }

        if !hadPassword {
            unlockedIdentities.removeAll()
        }

        refreshLastActiveApplicationState()
        evaluateRunningApplications()
    }

    @discardableResult
    func lockLastActiveApplication() -> Bool {
        guard let app = lastActiveApplication else {
            activityLog.record("Lock Current App Failed", detail: "No recent app to lock.")
            return false
        }

        return forceLock(app, reason: "App Locked Manually")
    }

    private func evaluateRunningApplications() {
        evaluateFrontmostApplication()
    }

    private func scheduleInitialSweep() {
        for delay in [0.35, 1.0] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.evaluateFrontmostApplication()
            }
        }
    }

    private func evaluateFrontmostApplication() {
        guard let app = workspace.frontmostApplication else {
            return
        }

        evaluate(app, delay: 0)
    }

    private func evaluate(_ app: NSRunningApplication, delay: TimeInterval) {
        guard lockStore.hasPassword else {
            return
        }

        guard let bundleIdentifier = app.bundleIdentifier,
              lockStore.isProtected(bundleIdentifier) else {
            return
        }

        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        let pid = app.processIdentifier
        let processIdentity = RunningAppIdentity(
            processID: pid,
            bundleIdentifier: bundleIdentifier,
            launchDate: app.launchDate
        )

        if overlayCoordinator.isPresentingLock(for: pid) {
            overlayCoordinator.reassertLock(for: app, identity: processIdentity)
            return
        }

        guard !unlockedIdentities.contains(processIdentity),
              !pendingProcessIDs.contains(pid) else {
            return
        }

        pendingProcessIDs.insert(pid)

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else {
                return
            }

            self.pendingProcessIDs.remove(pid)

            guard !app.isTerminated,
                  let currentIdentity = self.identity(for: app),
                  currentIdentity == processIdentity,
                  self.workspace.frontmostApplication?.processIdentifier == pid,
                  self.lockStore.hasPassword,
                  self.lockStore.isProtected(bundleIdentifier),
                  !self.unlockedIdentities.contains(processIdentity) else {
                return
            }

            self.activityLog.record("App Locked", detail: app.localizedName ?? bundleIdentifier)
            self.overlayCoordinator.presentLock(for: app, identity: processIdentity) { unlocked in
                if unlocked {
                    self.unlockedIdentities.insert(processIdentity)
                }
            }
        }
    }

    private func handleTermination(app: NSRunningApplication) {
        let pid = app.processIdentifier
        unlockedIdentities = unlockedIdentities.filter { $0.processID != pid }
        pendingProcessIDs.remove(pid)
        overlayCoordinator.dismissIfMatching(processID: pid)
        if lastActiveApplication?.processIdentifier == pid {
            lastActiveApplication = nil
            refreshLastActiveApplicationState()
        }
    }

    private func forceLock(_ app: NSRunningApplication, reason: String) -> Bool {
        guard lockStore.hasPassword,
              let identity = identity(for: app),
              lockStore.isProtected(identity.bundleIdentifier),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !app.isTerminated else {
            activityLog.record("Lock Current App Failed", detail: app.localizedName ?? "The selected app is not protected.")
            refreshLastActiveApplicationState()
            return false
        }

        pendingProcessIDs.remove(identity.processID)
        unlockedIdentities.remove(identity)

        if overlayCoordinator.isPresentingLock(for: identity.processID) {
            overlayCoordinator.reassertLock(for: app, identity: identity, makeKey: true)
            return true
        }

        activityLog.record(reason, detail: app.localizedName ?? identity.bundleIdentifier)
        overlayCoordinator.presentLock(for: app, identity: identity) { [weak self] unlocked in
            guard let self else {
                return
            }

            if unlocked {
                self.unlockedIdentities.insert(identity)
                self.refreshLastActiveApplicationState()
            }
        }
        refreshLastActiveApplicationState()
        return true
    }

    private func rememberLastActiveApplication(_ app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.bundleIdentifier != nil,
              !app.isTerminated else {
            return
        }

        lastActiveApplication = app
        refreshLastActiveApplicationState()
    }

    private func refreshLastActiveApplicationState() {
        guard let app = lastActiveApplication,
              !app.isTerminated,
              let bundleIdentifier = app.bundleIdentifier else {
            lastActiveApplicationName = nil
            canLockLastActiveApplication = false
            return
        }

        lastActiveApplicationName = app.localizedName ?? bundleIdentifier
        canLockLastActiveApplication = lockStore.hasPassword && lockStore.isProtected(bundleIdentifier)
    }

    private func identity(for app: NSRunningApplication) -> RunningAppIdentity? {
        guard let bundleIdentifier = app.bundleIdentifier else {
            return nil
        }

        return RunningAppIdentity(
            processID: app.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            launchDate: app.launchDate
        )
    }
}
