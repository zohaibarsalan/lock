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

    init() {
        let activityLog = ActivityLogStore()
        let store = LockStore(activityLog: activityLog)
        let discovery = AppDiscoveryService()
        let overlay = OverlayCoordinator(lockStore: store, activityLog: activityLog)
        let monitor = AppMonitor(lockStore: store, overlayCoordinator: overlay, activityLog: activityLog)
        let navigation = AppNavigation()
        let permissionService = PermissionService(activityLog: activityLog)
        let startupService = StartupService(activityLog: activityLog)
        let mainWindowController = MainWindowController(
            lockStore: store,
            discoveryService: discovery,
            navigation: navigation,
            permissionService: permissionService,
            startupService: startupService,
            activityLog: activityLog
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

        appDelegate.configure(mainWindowController: mainWindowController)
    }

    var body: some Scene {
        MenuBarExtra("Lock", systemImage: "lock.shield.fill") {
            Button("Show") {
                mainWindowController.show(section: .apps)
            }

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
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var mainWindowController: MainWindowController?
    private var shouldShowMainWindowWhenConfigured = false

    func configure(mainWindowController: MainWindowController) {
        self.mainWindowController = mainWindowController

        if shouldShowMainWindowWhenConfigured {
            shouldShowMainWindowWhenConfigured = false
            showMainWindow()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard !CommandLine.arguments.contains(LaunchArguments.background) else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.showMainWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func showMainWindow() {
        guard let mainWindowController else {
            shouldShowMainWindowWhenConfigured = true
            return
        }

        mainWindowController.show(section: .apps)
    }
}
