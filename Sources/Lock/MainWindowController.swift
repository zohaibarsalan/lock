import AppKit
import SwiftUI

@MainActor
final class MainWindowController: NSObject, ObservableObject, NSWindowDelegate {
    private let lockStore: LockStore
    private let discoveryService: AppDiscoveryService
    private let navigation: AppNavigation
    private let permissionService: PermissionService
    private let startupService: StartupService
    private let activityLog: ActivityLogStore

    private var window: MainAppWindow?

    init(
        lockStore: LockStore,
        discoveryService: AppDiscoveryService,
        navigation: AppNavigation,
        permissionService: PermissionService,
        startupService: StartupService,
        activityLog: ActivityLogStore
    ) {
        self.lockStore = lockStore
        self.discoveryService = discoveryService
        self.navigation = navigation
        self.permissionService = permissionService
        self.startupService = startupService
        self.activityLog = activityLog
    }

    func show(section: SidebarSection) {
        navigation.selectedSection = section
        discoveryService.refreshIfNeeded()
        permissionService.refreshStatuses()
        startupService.refresh()
        activateForWindowPresentation()

        if let window {
            window.orderFrontRegardless()
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = ContentView()
            .environmentObject(lockStore)
            .environmentObject(discoveryService)
            .environmentObject(navigation)
            .environmentObject(permissionService)
            .environmentObject(startupService)
            .environmentObject(activityLog)

        let window = MainAppWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSHostingView(rootView: contentView)
        window.delegate = self
        window.center()
        window.minSize = NSSize(width: 880, height: 580)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("LockMainWindow")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1)
        window.isOpaque = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func activateForWindowPresentation() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class MainAppWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers == [.command], event.charactersIgnoringModifiers == "w" {
            performClose(nil)
            return true
        }

        if modifiers == [.command], event.charactersIgnoringModifiers == "q" {
            NSApplication.shared.terminate(nil)
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}
