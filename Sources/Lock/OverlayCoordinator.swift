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
    private let lockPanelCollectionBehavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]

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
            reassertLock(for: app)
            return
        }

        let initialFrame = overlayFrame(for: app)
        lockedSessions[processID] = LockedSession(app: app, lastKnownFrame: initialFrame)
        completions[processID] = completion

        let window = makeLockWindow(for: app, frame: initialFrame)
        window.lockedProcessID = processID
        lockWindows[processID] = window
        hideLockedApp(app, processID: processID)
        bringLockWindowToFront(processID: processID)
    }

    func reassertLock(for app: NSRunningApplication) {
        let processID = app.processIdentifier

        guard isPresentingLock(for: processID) else {
            return
        }

        updateStoredFrameIfAvailable(for: processID, app: app)
        hideLockedApp(app, processID: processID)
        bringLockWindowToFront(processID: processID)
    }

    func rehideLockedAppsForSpaceChange() {
        for (processID, session) in lockedSessions where !session.app.isTerminated {
            hideLockedApp(session.app, processID: processID)
        }
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
        window.level = .modalPanel
        window.collectionBehavior = lockPanelCollectionBehavior
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
        if let frame = CGWindowBridge.primaryFrame(for: app) {
            return lockFrame(forTargetFrame: frame)
        }

        if let snapshot = AXWindowBridge.snapshot(for: app) {
            return lockFrame(forTargetFrame: snapshot.frame)
        }

        return fallbackPromptFrame()
    }

    private func fallbackPromptFrame() -> NSRect {
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return compactPromptFrame(in: visibleFrame)
    }

    private func compactPromptFrame(in container: NSRect) -> NSRect {
        let width = min(max(container.width * 0.34, 320), min(460, container.width))
        let height = min(max(container.height * 0.30, 240), min(340, container.height))

        return NSRect(
            x: container.midX - width / 2,
            y: container.midY - height / 2,
            width: width,
            height: height
        ).integral
    }

    private func lockFrame(forTargetFrame targetFrame: NSRect) -> NSRect {
        let targetFrame = targetFrame.integral

        guard let screen = screen(containing: targetFrame),
              isScreenSized(targetFrame, on: screen) else {
            return targetFrame
        }

        return compactPromptFrame(in: screen.visibleFrame.intersectionOrSelf(targetFrame))
    }

    private func screen(containing frame: NSRect) -> NSScreen? {
        let midpoint = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(midpoint) }
            ?? NSScreen.screens.first { $0.frame.intersects(frame) }
            ?? NSScreen.main
    }

    private func isScreenSized(_ frame: NSRect, on screen: NSScreen) -> Bool {
        let tolerance: CGFloat = 8
        let screenFrame = screen.frame
        let coversScreenWidth = frame.width >= screenFrame.width - tolerance
        let coversScreenHeight = frame.height >= screenFrame.height - tolerance
        let alignedWithScreen = abs(frame.minX - screenFrame.minX) <= tolerance
            && abs(frame.minY - screenFrame.minY) <= tolerance

        return coversScreenWidth && coversScreenHeight && alignedWithScreen
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
        if let frame = CGWindowBridge.primaryFrame(for: app) {
            let frame = lockFrame(forTargetFrame: frame)
            if var session = lockedSessions[processID] {
                session.lastKnownFrame = frame
                lockedSessions[processID] = session
            }
            return frame
        }

        if let snapshot = AXWindowBridge.snapshot(for: app) {
            let frame = lockFrame(forTargetFrame: snapshot.frame)
            if var session = lockedSessions[processID] {
                session.lastKnownFrame = frame
                lockedSessions[processID] = session
            }
            return frame
        }

        return lockedSessions[processID]?.lastKnownFrame ?? fallbackPromptFrame().integral
    }

    private func updateStoredFrameIfAvailable(for processID: pid_t, app: NSRunningApplication) {
        if let frame = CGWindowBridge.primaryFrame(for: app),
           var session = lockedSessions[processID] {
            session.lastKnownFrame = lockFrame(forTargetFrame: frame)
            lockedSessions[processID] = session
            return
        }

        guard let snapshot = AXWindowBridge.snapshot(for: app),
              var session = lockedSessions[processID] else {
            return
        }

        session.lastKnownFrame = lockFrame(forTargetFrame: snapshot.frame)
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

    private func hideLockedApp(_ app: NSRunningApplication, processID: pid_t) {
        guard isPresentingLock(for: processID), !app.isTerminated else {
            return
        }

        app.hide()

        for delay in [0.08, 0.25, 0.6] as [TimeInterval] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak app] in
                guard let self,
                      let app,
                      self.isPresentingLock(for: processID),
                      !app.isTerminated,
                      !app.isHidden else {
                    return
                }

                app.hide()
            }
        }
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

private extension NSRect {
    func intersectionOrSelf(_ other: NSRect) -> NSRect {
        let intersection = intersection(other)
        guard !intersection.isNull,
              intersection.width > 0,
              intersection.height > 0 else {
            return self
        }

        return intersection
    }
}

fileprivate enum CGWindowBridge {
    static func primaryFrame(for app: NSRunningApplication) -> NSRect? {
        frames(for: app).max { lhs, rhs in
            lhs.width * lhs.height < rhs.width * rhs.height
        }
    }

    private static func frames(for app: NSRunningApplication) -> [NSRect] {
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return windowInfo.compactMap { info -> NSRect? in
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == app.processIdentifier,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double,
                  alpha > 0.01,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = appKitFrame(from: bounds),
                  frame.width > 48,
                  frame.height > 48 else {
                return nil
            }

            return frame
        }
    }

    private static func appKitFrame(from bounds: [String: Any]) -> NSRect? {
        guard let x = number(bounds["X"]),
              let y = number(bounds["Y"]),
              let width = number(bounds["Width"]),
              let height = number(bounds["Height"]),
              width > 0,
              height > 0 else {
            return nil
        }

        let quartzFrame = NSRect(x: x, y: y, width: width, height: height)
        return convertQuartzFrameToAppKit(quartzFrame).integral
    }

    private static func number(_ value: Any?) -> CGFloat? {
        switch value {
        case let number as NSNumber:
            CGFloat(truncating: number)
        case let value as CGFloat:
            value
        case let value as Double:
            CGFloat(value)
        case let value as Int:
            CGFloat(value)
        default:
            nil
        }
    }

    private static func convertQuartzFrameToAppKit(_ frame: NSRect) -> NSRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return frame
        }

        let desktopMaxY = screens.map(\.frame.maxY).max() ?? 0
        let converted = NSRect(
            x: frame.minX,
            y: desktopMaxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )

        if screens.contains(where: { $0.frame.intersects(converted) || $0.frame.contains(NSPoint(x: converted.midX, y: converted.midY)) }) {
            return converted
        }

        return frame
    }
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
