import SwiftUI

@main
struct LockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var lockStore: LockStore
    @StateObject private var discoveryService: AppDiscoveryService
    @StateObject private var overlayCoordinator: OverlayCoordinator
    @StateObject private var appMonitor: AppMonitor
    @StateObject private var navigation: AppNavigation
    @StateObject private var permissionService: PermissionService
    @StateObject private var startupService: StartupService
    @StateObject private var activityLog: ActivityLogStore
    @StateObject private var mainWindowController: MainWindowController
    @StateObject private var adminAuthService: AdminAuthService

    init() {
        let activityLog = ActivityLogStore()
        let store = LockStore(activityLog: activityLog)
        let discovery = AppDiscoveryService()
        let overlay = OverlayCoordinator(lockStore: store, activityLog: activityLog)
        let monitor = AppMonitor(lockStore: store, overlayCoordinator: overlay, activityLog: activityLog)
        let navigation = AppNavigation()
        let permissionService = PermissionService(activityLog: activityLog)
        let startupService = StartupService(activityLog: activityLog)
        let adminAuthService = AdminAuthService(activityLog: activityLog)
        let mainWindowController = MainWindowController(
            lockStore: store,
            discoveryService: discovery,
            navigation: navigation,
            permissionService: permissionService,
            startupService: startupService,
            activityLog: activityLog,
            adminAuthService: adminAuthService
        )

        _lockStore = StateObject(wrappedValue: store)
        _discoveryService = StateObject(wrappedValue: discovery)
        _overlayCoordinator = StateObject(wrappedValue: overlay)
        _appMonitor = StateObject(wrappedValue: monitor)
        _navigation = StateObject(wrappedValue: navigation)
        _permissionService = StateObject(wrappedValue: permissionService)
        _startupService = StateObject(wrappedValue: startupService)
        _activityLog = StateObject(wrappedValue: activityLog)
        _mainWindowController = StateObject(wrappedValue: mainWindowController)
        _adminAuthService = StateObject(wrappedValue: adminAuthService)
    }

    var body: some Scene {
        MenuBarExtra("Lock", systemImage: "lock.shield.fill") {
            Button("Show") {
                mainWindowController.show(section: .apps)
            }

            Divider()

            Button(lockCurrentAppTitle) {
                appMonitor.lockLastActiveApplication()
            }
            .disabled(!appMonitor.canLockLastActiveApplication)

            Divider()

            Button("Settings...") {
                mainWindowController.show(section: .settings)
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Check Permissions...") {
                mainWindowController.show(section: .settings)
            }

            Button("Logs...") {
                mainWindowController.show(section: .logs)
            }

            Divider()

            Button("Quit Lock") {
                quitLock()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .menuBarExtraStyle(.menu)
    }

    private var lockCurrentAppTitle: String {
        if let appName = appMonitor.lastActiveApplicationName {
            "Lock \(appName)"
        } else {
            "Lock Current App"
        }
    }

    private func quitLock() {
        guard lockStore.hasPassword else {
            NSApplication.shared.terminate(nil)
            return
        }

        adminAuthService.authorize(reason: "Quit Lock") { success in
            if success {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
