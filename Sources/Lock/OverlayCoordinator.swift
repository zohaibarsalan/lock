import AppKit
import ApplicationServices
import LocalAuthentication
import SwiftUI

@MainActor
final class OverlayCoordinator: NSObject, ObservableObject {
    private let lockStore: LockStore
    private let activityLog: ActivityLogStore

    private var lockWindows: [pid_t: [String: LockOverlayPanel]] = [:]
    private var lockedSessions: [pid_t: LockedSession] = [:]
    private var completions: [pid_t: (Bool) -> Void] = [:]
    private var syncTimer: Timer?
    private var activeProcessID: pid_t?
    private var focusedUnlockProcessID: pid_t?
    private var focusedUnlockUntil: Date?

    init(lockStore: LockStore, activityLog: ActivityLogStore) {
        self.lockStore = lockStore
        self.activityLog = activityLog
    }

    func isPresentingLock(for processID: pid_t) -> Bool {
        lockedSessions[processID] != nil
    }

    func presentLock(for app: NSRunningApplication, identity: RunningAppIdentity, completion: @escaping (Bool) -> Void) {
        let processID = app.processIdentifier

        if isPresentingLock(for: processID) {
            reassertLock(for: app, identity: identity, makeKey: true)
            return
        }

        let initialTargets = shieldTargets(for: app, previousTargets: [])
        let session = LockedSession(
            id: UUID(),
            app: app,
            identity: identity,
            appName: app.localizedName ?? "Protected App",
            appIcon: icon(for: app),
            lastTargets: initialTargets
        )
        lockedSessions[processID] = session
        completions[processID] = completion
        app.hide()
        markUnlockFocused(processID: processID)
        syncShieldWindows(processID: processID, makeKey: true)
        updateSyncTimer()
    }

    func reassertLock(for app: NSRunningApplication, identity: RunningAppIdentity, makeKey: Bool = false) {
        let processID = app.processIdentifier

        guard let session = lockedSessions[processID] else {
            return
        }

        guard session.identity == identity else {
            dismiss(processID: processID, unlocked: false)
            return
        }

        refreshStoredTargets(processID: processID)
        app.hide()
        if makeKey {
            markUnlockFocused(processID: processID)
        }
        syncShieldWindows(processID: processID, makeKey: makeKey)
    }

    func activeApplicationChanged(to processID: pid_t) {
        if let focusedUnlockProcessID,
           focusedUnlockProcessID != processID,
           focusedUnlockUntil.map({ $0 > Date() }) == true,
           lockedSessions[focusedUnlockProcessID] != nil {
            bringLockWindowsToFront(processID: focusedUnlockProcessID, makeKey: true)
            return
        }

        activeProcessID = processID

        for lockedProcessID in Array(lockedSessions.keys) {
            if lockedProcessID == processID {
                refreshStoredTargets(processID: lockedProcessID)
                lockedSessions[lockedProcessID]?.app.hide()
                markUnlockFocused(processID: lockedProcessID)
                syncShieldWindows(processID: lockedProcessID, makeKey: true)
            } else {
                lockedSessions[lockedProcessID]?.app.hide()
                sendLockWindowsBehindActiveApp(processID: lockedProcessID)
            }
        }
    }

    func dismissIfMatching(processID: pid_t) {
        guard isPresentingLock(for: processID) else {
            return
        }

        dismiss(processID: processID, unlocked: false)
    }

    private func syncShieldWindows(processID: pid_t, makeKey: Bool) {
        guard let session = lockedSessions[processID] else {
            return
        }

        let targets = session.lastTargets
        let targetIDs = Set(targets.map(\.id))
        let interactiveID = targets.first?.id
        var windows = lockWindows[processID] ?? [:]

        for (id, window) in windows where !targetIDs.contains(id) {
            window.orderOut(nil)
            window.close()
            windows.removeValue(forKey: id)
        }

        for target in targets {
            let isInteractive = target.id == interactiveID

            if let window = windows[target.id] {
                window.setFrame(target.frame, display: true, animate: false)
                if window.isInteractiveShield != isInteractive {
                    configure(window: window, session: session, isInteractive: isInteractive)
                }
            } else {
                let window = makeLockWindow(for: session, target: target, isInteractive: isInteractive)
                windows[target.id] = window
            }
        }

        lockWindows[processID] = windows
        if activeProcessID == nil || activeProcessID == processID || makeKey {
            bringLockWindowsToFront(processID: processID, makeKey: makeKey)
        } else {
            sendLockWindowsBehindActiveApp(processID: processID)
        }
    }

    private func makeLockWindow(for session: LockedSession, target: ShieldTarget, isInteractive: Bool) -> LockOverlayPanel {
        let window = LockOverlayPanel(
            contentRect: target.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.lockedProcessID = session.identity.processID
        window.shieldID = target.id
        window.level = isInteractive ? .modalPanel : .floating
        window.collectionBehavior = [.managed, .fullScreenAuxiliary, .moveToActiveSpace]
        window.isExcludedFromWindowsMenu = false
        window.hidesOnDeactivate = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.hasShadow = false
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        configure(window: window, session: session, isInteractive: isInteractive)
        return window
    }

    private func configure(window: LockOverlayPanel, session: LockedSession, isInteractive: Bool) {
        let processID = session.identity.processID
        let sessionID = session.id
        window.isInteractiveShield = isInteractive
        window.level = isInteractive ? .modalPanel : .floating
        window.onCommandQuit = { [weak self] in
            self?.quitLockedApp(processID: processID, sessionID: sessionID)
        }

        let rootView = LockOverlayView(
            appName: session.appName,
            appIcon: session.appIcon,
            touchIDAvailable: canUseBiometrics(),
            showsControls: isInteractive,
            onUnlock: { [weak self] password in
                self?.attemptUnlock(password: password, processID: processID, sessionID: sessionID) ?? false
            },
            onTouchID: { [weak self] in
                self?.attemptBiometricUnlock(processID: processID, sessionID: sessionID)
            },
            onQuit: { [weak self] in
                self?.quitLockedApp(processID: processID, sessionID: sessionID)
            }
        )

        window.contentView = NSHostingView(rootView: rootView)
    }

    private func refreshStoredTargets(processID: pid_t) {
        guard let session = lockedSessions[processID] else {
            return
        }

        let updatedTargets = shieldTargets(for: session.app, previousTargets: session.lastTargets)
        lockedSessions[processID]?.lastTargets = updatedTargets
    }

    private func shieldTargets(for app: NSRunningApplication, previousTargets: [ShieldTarget]) -> [ShieldTarget] {
        let snapshots = AXWindowBridge.snapshots(for: app)
        let visibleFrames = snapshots.map(\.frame).filter { $0.width > 24 && $0.height > 24 }
        let preferredFrame = AXWindowBridge.primarySnapshot(for: app)?.frame ?? visibleFrames.first
        var targets = visibleFrames.enumerated().map { index, frame in
            ShieldTarget(id: "window-\(index)", frame: frame.integral)
        }

        if targets.isEmpty, !previousTargets.isEmpty {
            return previousTargets
        }

        if targets.isEmpty {
            let screen = screen(containing: preferredFrame) ?? NSScreen.main ?? NSScreen.screens.first
            if let screen {
                let size = NSSize(width: min(screen.visibleFrame.width * 0.42, 520), height: 340)
                let frame = NSRect(
                    x: screen.visibleFrame.midX - size.width / 2,
                    y: screen.visibleFrame.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                )
                targets.append(ShieldTarget(id: "fallback-auth", frame: frame.integral))
            } else {
                targets.append(ShieldTarget(id: "fallback-auth", frame: NSRect(x: 480, y: 280, width: 520, height: 340)))
            }
        }

        if let preferredFrame {
            targets.sort { lhs, rhs in
                if lhs.frame.intersects(preferredFrame) != rhs.frame.intersects(preferredFrame) {
                    return lhs.frame.intersects(preferredFrame)
                }
                return lhs.frame.width * lhs.frame.height > rhs.frame.width * rhs.frame.height
            }
        } else {
            targets.sort { lhs, rhs in
                lhs.frame.width * lhs.frame.height > rhs.frame.width * rhs.frame.height
            }
        }

        return targets
    }

    private func screen(containing frame: NSRect?) -> NSScreen? {
        guard let frame else {
            return nil
        }

        let center = NSPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { NSMouseInRect(center, $0.frame, false) }
            ?? NSScreen.screens.first { $0.frame.intersects(frame) }
    }

    private func bringLockWindowsToFront(processID: pid_t, makeKey: Bool) {
        guard let windows = lockWindows[processID], !windows.isEmpty else {
            return
        }

        let orderedWindows = windows.values.sorted { lhs, rhs in
            if lhs.isInteractiveShield != rhs.isInteractiveShield {
                return lhs.isInteractiveShield
            }
            return lhs.shieldID < rhs.shieldID
        }

        for window in orderedWindows {
            window.orderFrontRegardless()
        }

        if makeKey, let keyWindow = orderedWindows.first(where: \.isInteractiveShield) {
            markUnlockFocused(processID: processID)
            NSApp.activate(ignoringOtherApps: true)
            keyWindow.makeKeyAndOrderFront(nil)
        }
    }

    private func sendLockWindowsBehindActiveApp(processID: pid_t) {
        if focusedUnlockProcessID == processID,
           focusedUnlockUntil.map({ $0 > Date() }) == true {
            return
        }

        lockWindows[processID]?.values.forEach { window in
            window.orderBack(nil)
        }
    }

    private func markUnlockFocused(processID: pid_t) {
        focusedUnlockProcessID = processID
        focusedUnlockUntil = Date().addingTimeInterval(2.0)
    }

    private func attemptUnlock(password: String, processID: pid_t, sessionID: UUID) -> Bool {
        guard lockedSessions[processID]?.id == sessionID,
              lockStore.verify(password: password) else {
            return false
        }

        let appName = lockedSessions[processID]?.appName ?? "Protected app"
        dismiss(processID: processID, unlocked: true)
        activityLog.record("Unlocked App", detail: appName)
        return true
    }

    private func attemptBiometricUnlock(processID: pid_t, sessionID: UUID) {
        let context = LAContext()
        var error: NSError?

        guard lockedSessions[processID]?.id == sessionID else {
            return
        }

        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            activityLog.record("Touch ID Unavailable", detail: error?.localizedDescription ?? "Biometric authentication is not available.")
            return
        }

        let appName = lockedSessions[processID]?.appName ?? "this app"

        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock \(appName)") { [weak self] success, evaluationError in
            DispatchQueue.main.async {
                guard let self,
                      self.lockedSessions[processID]?.id == sessionID else {
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
        guard lockedSessions[processID]?.id == sessionID else {
            return
        }

        activityLog.record("Quit Locked App", detail: lockedSessions[processID]?.appName ?? "Protected app")
        lockedSessions[processID]?.app.terminate()
        dismiss(processID: processID, unlocked: false)
    }

    private func dismiss(processID: pid_t, unlocked: Bool) {
        let session = lockedSessions.removeValue(forKey: processID)
        let windows = lockWindows.removeValue(forKey: processID)
        let completion = completions.removeValue(forKey: processID)

        if focusedUnlockProcessID == processID {
            focusedUnlockProcessID = nil
            focusedUnlockUntil = nil
        }

        windows?.values.forEach { window in
            window.orderOut(nil)
            window.close()
        }

        if unlocked, let session {
            session.app.unhide()
            session.app.activate(options: [.activateAllWindows])
        }

        completion?(unlocked)
        updateSyncTimer()
    }

    private func updateSyncTimer() {
        guard !lockedSessions.isEmpty else {
            syncTimer?.invalidate()
            syncTimer = nil
            return
        }

        guard syncTimer == nil else {
            return
        }

        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.syncLockedSessions()
            }
        }
    }

    private func syncLockedSessions() {
        for processID in Array(lockedSessions.keys) {
            guard let session = lockedSessions[processID],
                  !session.app.isTerminated else {
                dismiss(processID: processID, unlocked: false)
                continue
            }

            refreshStoredTargets(processID: processID)
            session.app.hide()
            syncShieldWindows(processID: processID, makeKey: false)
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

private struct LockedSession {
    let id: UUID
    let app: NSRunningApplication
    let identity: RunningAppIdentity
    let appName: String
    let appIcon: NSImage
    var lastTargets: [ShieldTarget]
}

private struct ShieldTarget {
    let id: String
    let frame: NSRect
}

private struct AXWindowSnapshot {
    let frame: NSRect
}

final class LockOverlayPanel: NSWindow {
    var lockedProcessID: pid_t = 0
    var shieldID = ""
    var isInteractiveShield = false
    var onCommandQuit: (() -> Void)?

    override var canBecomeKey: Bool { isInteractiveShield }
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
    static func primarySnapshot(for app: NSRunningApplication) -> AXWindowSnapshot? {
        guard let window = primaryWindow(for: app),
              let frame = frame(for: window) else {
            return nil
        }

        return AXWindowSnapshot(frame: frame)
    }

    static func snapshots(for app: NSRunningApplication) -> [AXWindowSnapshot] {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let windows = arrayValue(of: kAXWindowsAttribute as CFString, on: appElement) else {
            return primarySnapshot(for: app).map { [$0] } ?? []
        }

        return windows.compactMap { window in
            if boolValue(of: kAXMinimizedAttribute as CFString, on: window) == true {
                return nil
            }

            guard let frame = frame(for: window) else {
                return nil
            }

            return AXWindowSnapshot(frame: frame)
        }
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

    private static func boolValue(of attribute: CFString, on element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success,
              let value,
              CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return nil
        }

        return CFBooleanGetValue((value as! CFBoolean))
    }
}
