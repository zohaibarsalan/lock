import AppKit
import ApplicationServices
import LocalAuthentication
import SwiftUI

@MainActor
final class OverlayCoordinator: NSObject, ObservableObject {
    private let lockStore: LockStore
    private let activityLog: ActivityLogStore

    private var lockWindows: [pid_t: LockOverlayPanel] = [:]
    private var lockedSessions: [pid_t: LockedSession] = [:]
    private var completions: [pid_t: (Bool) -> Void] = [:]

    init(lockStore: LockStore, activityLog: ActivityLogStore) {
        self.lockStore = lockStore
        self.activityLog = activityLog
    }

    func isPresentingLock(for processID: pid_t) -> Bool {
        lockedSessions[processID] != nil
    }

    func presentLock(for app: NSRunningApplication, completion: @escaping (Bool) -> Void) {
        let processID = app.processIdentifier

        if isPresentingLock(for: processID) {
            bringLockWindowToFront(processID: processID)
            return
        }

        let initialFrame = overlayFrame(for: app)
        lockedSessions[processID] = LockedSession(app: app, lastKnownFrame: initialFrame)
        completions[processID] = completion
        app.hide()

        let window = makeLockWindow(for: app, frame: initialFrame)
        window.lockedProcessID = processID
        lockWindows[processID] = window
        bringLockWindowToFront(processID: processID)
    }

    func reassertLock(for app: NSRunningApplication) {
        let processID = app.processIdentifier

        guard isPresentingLock(for: processID) else {
            return
        }

        updateStoredFrameIfAvailable(for: processID, app: app)
        app.hide()
        bringLockWindowToFront(processID: processID)
    }

    func dismissIfMatching(processID: pid_t) {
        guard isPresentingLock(for: processID) else {
            return
        }

        dismiss(processID: processID, unlocked: false)
    }

    private func makeLockWindow(for app: NSRunningApplication, frame: NSRect) -> LockOverlayPanel {
        let window = LockOverlayPanel(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        window.isExcludedFromWindowsMenu = true
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)

        let processID = app.processIdentifier
        window.onCommandQuit = { [weak self] in
            self?.quitLockedApp(processID: processID)
        }

        let rootView = LockOverlayView(
            appName: app.localizedName ?? "Protected App",
            appIcon: icon(for: app),
            touchIDAvailable: canUseBiometrics(),
            onUnlock: { [weak self] password in
                self?.attemptUnlock(password: password, processID: processID) ?? false
            },
            onTouchID: { [weak self] in
                self?.attemptBiometricUnlock(processID: processID)
            },
            onQuit: { [weak self] in
                self?.quitLockedApp(processID: processID)
            }
        )

        window.contentView = NSHostingView(rootView: rootView)
        return window
    }

    private func overlayFrame(for app: NSRunningApplication) -> NSRect {
        if let snapshot = AXWindowBridge.snapshot(for: app) {
            return snapshot.frame.integral
        }

        let fallbackFrame = primaryScreenFrame()
        return fallbackFrame.integral
    }

    private func primaryScreenFrame() -> NSRect {
        NSScreen.main?.frame
            ?? NSScreen.screens.first?.frame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func syncLockWindowFrame(processID: pid_t) {
        guard let lockWindow = lockWindows[processID],
              let session = lockedSessions[processID] else {
            return
        }

        let frame = currentOverlayFrame(processID: processID, app: session.app)
        lockWindow.setFrame(frame, display: true, animate: false)
    }

    private func currentOverlayFrame(processID: pid_t, app: NSRunningApplication) -> NSRect {
        if let snapshot = AXWindowBridge.snapshot(for: app) {
            let frame = snapshot.frame.integral
            if var session = lockedSessions[processID] {
                session.lastKnownFrame = frame
                lockedSessions[processID] = session
            }
            return frame
        }

        return lockedSessions[processID]?.lastKnownFrame ?? primaryScreenFrame().integral
    }

    private func updateStoredFrameIfAvailable(for processID: pid_t, app: NSRunningApplication) {
        guard let snapshot = AXWindowBridge.snapshot(for: app),
              var session = lockedSessions[processID] else {
            return
        }

        session.lastKnownFrame = snapshot.frame.integral
        lockedSessions[processID] = session
    }

    private func bringLockWindowToFront(processID: pid_t) {
        guard let lockWindow = lockWindows[processID] else {
            return
        }

        syncLockWindowFrame(processID: processID)
        NSApp.activate(ignoringOtherApps: true)
        lockWindow.orderFrontRegardless()
        lockWindow.makeKeyAndOrderFront(nil)
    }

    private func attemptUnlock(password: String, processID: pid_t) -> Bool {
        guard lockStore.verify(password: password) else {
            return false
        }

        let appName = lockedSessions[processID]?.app.localizedName ?? "Protected app"
        dismiss(processID: processID, unlocked: true)
        activityLog.record("Unlocked App", detail: appName)
        return true
    }

    private func attemptBiometricUnlock(processID: pid_t) {
        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            activityLog.record("Touch ID Unavailable", detail: error?.localizedDescription ?? "Biometric authentication is not available.")
            return
        }

        let appName = lockedSessions[processID]?.app.localizedName ?? "this app"

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock \(appName)") { [weak self] success, evaluationError in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                if success {
                    self.activityLog.record("Unlocked with Touch ID", detail: appName)
                    self.dismiss(processID: processID, unlocked: true)
                } else if let evaluationError {
                    self.activityLog.record("Touch ID Failed", detail: evaluationError.localizedDescription)
                }
            }
        }
    }

    private func quitLockedApp(processID: pid_t) {
        activityLog.record("Quit Locked App", detail: lockedSessions[processID]?.app.localizedName ?? "Protected app")
        lockedSessions[processID]?.app.terminate()
        dismiss(processID: processID, unlocked: false)
    }

    private func dismiss(processID: pid_t, unlocked: Bool) {
        let session = lockedSessions.removeValue(forKey: processID)
        let lockWindow = lockWindows.removeValue(forKey: processID)
        let completion = completions.removeValue(forKey: processID)

        lockWindow?.orderOut(nil)
        lockWindow?.close()

        if unlocked, let session {
            session.app.unhide()
            session.app.activate(options: [.activateAllWindows])
        }

        completion?(unlocked)
    }

    private func icon(for app: NSRunningApplication) -> NSImage {
        if let url = app.bundleURL {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 72, height: 72)
            return icon
        }

        let fallback = NSImage(systemSymbolName: "lock.desktopcomputer", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 72, height: 72))
        fallback.size = NSSize(width: 72, height: 72)
        return fallback
    }

    private func canUseBiometrics() -> Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }
}

private struct LockedSession {
    let app: NSRunningApplication
    var lastKnownFrame: NSRect
}

private struct AXWindowSnapshot {
    let frame: NSRect
}

final class LockOverlayPanel: NSPanel {
    var lockedProcessID: pid_t = 0
    var onCommandQuit: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers == [.command], event.charactersIgnoringModifiers == "q" {
            onCommandQuit?()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }
}

fileprivate enum AXWindowBridge {
    static func snapshot(for app: NSRunningApplication) -> AXWindowSnapshot? {
        guard let window = primaryWindow(for: app),
              let frame = frame(for: window) else {
            return nil
        }

        return AXWindowSnapshot(frame: frame)
    }

    private static func primaryWindow(for app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        if let focusedWindow = elementValue(of: kAXFocusedWindowAttribute as CFString, on: appElement) {
            return focusedWindow
        }

        if let mainWindow = elementValue(of: kAXMainWindowAttribute as CFString, on: appElement) {
            return mainWindow
        }

        guard let values = arrayValue(of: kAXWindowsAttribute as CFString, on: appElement) else {
            return nil
        }

        return values.first
    }

    private static func frame(for window: AXUIElement) -> NSRect? {
        guard let positionValue = axValue(of: kAXPositionAttribute as CFString, on: window),
              let sizeValue = axValue(of: kAXSizeAttribute as CFString, on: window) else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }

        return NSRect(origin: position, size: size)
    }

    private static func elementValue(of attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private static func arrayValue(of attribute: CFString, on element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let array = value as? [AXUIElement] else {
            return nil
        }

        return array
    }

    private static func axValue(of attribute: CFString, on element: AXUIElement) -> AXValue? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        return (value as! AXValue)
    }
}
