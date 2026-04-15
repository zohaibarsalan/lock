import AppKit
import ApplicationServices
import LocalAuthentication
import SwiftUI

@MainActor
final class OverlayCoordinator: NSObject, ObservableObject {
    private let lockStore: LockStore
    private let activityLog: ActivityLogStore

    private var sessions: [pid_t: LockSession] = [:]
    private var promptWindows: [pid_t: LockPromptWindow] = [:]
    private var completions: [pid_t: (Bool) -> Void] = [:]
    private var activeProcessID: pid_t?
    private var syncTimer: Timer?

    init(lockStore: LockStore, activityLog: ActivityLogStore) {
        self.lockStore = lockStore
        self.activityLog = activityLog
    }

    func isPresentingLock(for processID: pid_t) -> Bool {
        sessions[processID] != nil
    }

    func presentLock(for app: NSRunningApplication, identity: RunningAppIdentity, completion: @escaping (Bool) -> Void) {
        let processID = app.processIdentifier

        if sessions[processID] != nil {
            reassertLock(for: app, identity: identity, makeKey: true)
            return
        }

        let frame = lockFrame(for: app, previousFrame: nil)
        sessions[processID] = LockSession(
            id: UUID(),
            app: app,
            identity: identity,
            appName: app.localizedName ?? "Protected App",
            appIcon: icon(for: app),
            lastKnownFrame: frame,
            state: .lockedHidden
        )
        completions[processID] = completion
        activeProcessID = processID

        app.hide()
        showPrompt(for: processID, makeKey: true)
        updateSyncTimer()
    }

    func reassertLock(for app: NSRunningApplication, identity: RunningAppIdentity, makeKey: Bool = false) {
        let processID = app.processIdentifier

        guard let session = sessions[processID] else {
            return
        }

        guard session.identity == identity else {
            dismiss(processID: processID, unlocked: false)
            return
        }

        updateFrame(for: processID)
        app.hide()

        if makeKey || activeProcessID == processID {
            activeProcessID = processID
            showPrompt(for: processID, makeKey: makeKey)
        } else {
            hidePrompt(for: processID)
        }
    }

    func activeApplicationChanged(to processID: pid_t) {
        activeProcessID = processID

        for lockedProcessID in Array(sessions.keys) {
            guard let session = sessions[lockedProcessID] else {
                continue
            }

            if lockedProcessID == processID {
                updateFrame(for: lockedProcessID)
                session.app.hide()
                showPrompt(for: lockedProcessID, makeKey: true)
            } else {
                session.app.hide()
                hidePrompt(for: lockedProcessID)
            }
        }
    }

    func dismissIfMatching(processID: pid_t) {
        guard sessions[processID] != nil else {
            return
        }

        dismiss(processID: processID, unlocked: false)
    }

    private func showPrompt(for processID: pid_t, makeKey: Bool) {
        guard var session = sessions[processID] else {
            return
        }

        let window = promptWindows[processID] ?? makePromptWindow(for: session)
        promptWindows[processID] = window

        window.setFrame(session.lastKnownFrame, display: true, animate: false)
        window.level = .modalPanel
        window.orderFrontRegardless()

        session.state = .unlockPromptVisible
        sessions[processID] = session

        if makeKey {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func hidePrompt(for processID: pid_t) {
        promptWindows[processID]?.orderOut(nil)
        if var session = sessions[processID] {
            session.state = .lockedHidden
            sessions[processID] = session
        }
    }

    private func makePromptWindow(for session: LockSession) -> LockPromptWindow {
        let window = LockPromptWindow(
            contentRect: session.lastKnownFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.lockedProcessID = session.identity.processID
        window.level = .modalPanel
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.hasShadow = false
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.onCommandQuit = { [weak self] in
            self?.quitLockedApp(processID: session.identity.processID, sessionID: session.id)
        }

        window.contentView = NSHostingView(
            rootView: LockOverlayView(
                appName: session.appName,
                appIcon: session.appIcon,
                touchIDAvailable: canUseBiometrics(),
                showsControls: true,
                onUnlock: { [weak self] password in
                    self?.attemptUnlock(password: password, processID: session.identity.processID, sessionID: session.id) ?? false
                },
                onTouchID: { [weak self] in
                    self?.attemptBiometricUnlock(processID: session.identity.processID, sessionID: session.id)
                },
                onQuit: { [weak self] in
                    self?.quitLockedApp(processID: session.identity.processID, sessionID: session.id)
                }
            )
        )

        return window
    }

    private func updateFrame(for processID: pid_t) {
        guard let session = sessions[processID] else {
            return
        }

        let frame = lockFrame(for: session.app, previousFrame: session.lastKnownFrame)
        sessions[processID]?.lastKnownFrame = frame
    }

    private func lockFrame(for app: NSRunningApplication, previousFrame: NSRect?) -> NSRect {
        if let frame = CGWindowBridge.primaryFrame(for: app) {
            return frame.integral
        }

        if let frame = AXWindowBridge.primaryFrame(for: app) {
            return frame.integral
        }

        if let previousFrame {
            return previousFrame.integral
        }

        return fallbackPromptFrame().integral
    }

    private func fallbackPromptFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(visibleFrame.width * 0.42, 560)
        let height: CGFloat = 360

        return NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

    private func attemptUnlock(password: String, processID: pid_t, sessionID: UUID) -> Bool {
        guard sessions[processID]?.id == sessionID,
              lockStore.verify(password: password) else {
            return false
        }

        let appName = sessions[processID]?.appName ?? "Protected app"
        dismiss(processID: processID, unlocked: true)
        activityLog.record("Unlocked App", detail: appName)
        return true
    }

    private func attemptBiometricUnlock(processID: pid_t, sessionID: UUID) {
        guard sessions[processID]?.id == sessionID else {
            return
        }

        let context = LAContext()
        var error: NSError?

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            activityLog.record("Touch ID Unavailable", detail: error?.localizedDescription ?? "Biometric authentication is not available.")
            return
        }

        let appName = sessions[processID]?.appName ?? "this app"

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock \(appName)") { [weak self] success, evaluationError in
            DispatchQueue.main.async {
                guard let self,
                      self.sessions[processID]?.id == sessionID else {
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

    private func quitLockedApp(processID: pid_t, sessionID: UUID) {
        guard sessions[processID]?.id == sessionID else {
            return
        }

        activityLog.record("Quit Locked App", detail: sessions[processID]?.appName ?? "Protected app")
        sessions[processID]?.app.terminate()
        dismiss(processID: processID, unlocked: false)
    }

    private func dismiss(processID: pid_t, unlocked: Bool) {
        let session = sessions.removeValue(forKey: processID)
        let window = promptWindows.removeValue(forKey: processID)
        let completion = completions.removeValue(forKey: processID)

        window?.orderOut(nil)
        window?.close()

        if unlocked, let session {
            session.app.unhide()
            session.app.activate(options: [.activateAllWindows])
        }

        completion?(unlocked)
        updateSyncTimer()
    }

    private func updateSyncTimer() {
        guard !sessions.isEmpty else {
            syncTimer?.invalidate()
            syncTimer = nil
            return
        }

        guard syncTimer == nil else {
            return
        }

        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncSessions()
            }
        }
    }

    private func syncSessions() {
        for processID in Array(sessions.keys) {
            guard let session = sessions[processID],
                  !session.app.isTerminated else {
                dismiss(processID: processID, unlocked: false)
                continue
            }

            session.app.hide()

            if session.state == .unlockPromptVisible {
                updateFrame(for: processID)
                showPrompt(for: processID, makeKey: false)
            }
        }
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

private enum LockSessionState {
    case lockedHidden
    case unlockPromptVisible
}

private struct LockSession {
    let id: UUID
    let app: NSRunningApplication
    let identity: RunningAppIdentity
    let appName: String
    let appIcon: NSImage
    var lastKnownFrame: NSRect
    var state: LockSessionState
}

final class LockPromptWindow: NSWindow {
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
                  frame.width > 80,
                  frame.height > 80 else {
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
        let converted = convertQuartzFrameToAppKit(quartzFrame)
        return converted.integral
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

fileprivate enum AXWindowBridge {
    static func primaryFrame(for app: NSRunningApplication) -> NSRect? {
        guard let window = primaryWindow(for: app),
              let frame = frame(for: window) else {
            return nil
        }

        return frame
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
