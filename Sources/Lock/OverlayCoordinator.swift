import AppKit
import LocalAuthentication
import OSLog
import SwiftUI

@MainActor
final class OverlayCoordinator: NSObject, ObservableObject {
  private let lockStore: LockStore
  private let activityLog: ActivityLogStore
  private let windowSnapshotProvider: WindowSnapshotProviding
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.zohaib.lock",
    category: "LockSession"
  )

  private var lockWindows: [pid_t: LockWindow] = [:]
  private var lockedSessions: [pid_t: LockedSession] = [:]
  private var completions: [pid_t: (Bool) -> Void] = [:]
  private var reassertionTasks: [pid_t: Task<Void, Never>] = [:]
  private let lockWindowCollectionBehavior: NSWindow.CollectionBehavior = [
    .managed, .fullScreenAuxiliary,
  ]
  private let preferredLockContentSize = NSSize(width: 574, height: 560)
  private let minimumLockContentSize = NSSize(width: 532, height: 520)

  init(
    lockStore: LockStore,
    activityLog: ActivityLogStore,
    windowSnapshotProvider: WindowSnapshotProviding = SystemWindowSnapshotProvider()
  ) {
    self.lockStore = lockStore
    self.activityLog = activityLog
    self.windowSnapshotProvider = windowSnapshotProvider
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

    transitionSession(processID: processID, to: .pending, reason: "present requested")
    activateForLockPresentation()

    let initialSnapshot = overlaySnapshot(for: app)
    lockedSessions[processID] = LockedSession(
      app: app,
      state: .pending,
      lastKnownFrame: initialSnapshot.frame,
      lastFrameSource: initialSnapshot.source
    )
    completions[processID] = completion

    let window = makeLockWindow(for: app, frame: initialSnapshot.frame)
    window.lockedProcessID = processID
    lockWindows[processID] = window
    reassertLock(for: app, reason: "initial presentation")
    startReassertionLoop(processID: processID)
  }

  func reassertLock(for app: NSRunningApplication) {
    reassertLock(for: app, reason: "external event")
  }

  private func reassertLock(for app: NSRunningApplication, reason: String) {
    let processID = app.processIdentifier

    guard isPresentingLock(for: processID) else {
      return
    }

    logSessionEvent(processID: processID, app: app, event: "reassert", detail: reason)
    updateStoredFrameIfAvailable(for: processID, app: app)
    hideLockedApp(app, processID: processID, reason: reason)
    bringLockWindowToFront(processID: processID, reason: reason)
  }

  func rehideLockedAppsForSpaceChange() {
    for (_, session) in lockedSessions where !session.app.isTerminated {
      reassertLock(for: session.app, reason: "space changed")
    }
  }

  func dismissIfMatching(processID: pid_t) {
    guard isPresentingLock(for: processID) else {
      return
    }

    dismiss(processID: processID, unlocked: false)
  }

  private func makeLockWindow(for app: NSRunningApplication, frame: NSRect) -> LockWindow {
    let appName = app.localizedName ?? "Protected App"
    let contentFrame = lockContentFrame(centeredIn: frame)
    let window = LockWindow(
      contentRect: contentFrame,
      styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "\(appName) Locked"
    window.level = .normal
    window.collectionBehavior = lockWindowCollectionBehavior
    window.isExcludedFromWindowsMenu = false
    window.hidesOnDeactivate = false
    window.isMovable = true
    window.isReleasedWhenClosed = false
    window.isOpaque = true
    window.hasShadow = true
    window.backgroundColor = .windowBackgroundColor
    window.appearance = nil
    window.setContentSize(preferredLockContentSize)
    window.minSize = minimumLockContentSize
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true

    let processID = app.processIdentifier
    window.onCommandQuit = { [weak self] in
      self?.quitLockedApp(processID: processID)
    }
    window.onClose = { [weak self] in
      self?.quitLockedApp(processID: processID)
    }

    let rootView = LockOverlayView(
      appName: appName,
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
    logSessionEvent(
      processID: processID,
      app: app,
      event: "window-created",
      detail: "contentFrame=\(describe(contentFrame)) targetFrame=\(describe(frame))"
    )
    return window
  }

  private func overlaySnapshot(for app: NSRunningApplication) -> WindowSnapshot {
    if let snapshot = windowSnapshotProvider.snapshot(for: app) {
      return WindowSnapshot(frame: lockFrame(forTargetFrame: snapshot.frame), source: snapshot.source)
    }

    return WindowSnapshot(frame: fallbackPromptFrame(), source: .fallback)
  }

  private func fallbackPromptFrame() -> NSRect {
    let visibleFrame =
      NSScreen.main?.visibleFrame
      ?? NSScreen.screens.first?.visibleFrame
      ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    return compactPromptFrame(in: visibleFrame)
  }

  private func compactPromptFrame(in container: NSRect) -> NSRect {
    lockContentFrame(centeredIn: container)
  }

  private func lockContentFrame(centeredIn container: NSRect) -> NSRect {
    NSRect(
      x: container.midX - preferredLockContentSize.width / 2,
      y: container.midY - preferredLockContentSize.height / 2,
      width: preferredLockContentSize.width,
      height: preferredLockContentSize.height
    ).integral
  }

  private func lockFrame(forTargetFrame targetFrame: NSRect) -> NSRect {
    let targetFrame = targetFrame.integral

    guard let screen = screen(containing: targetFrame),
      isScreenSized(targetFrame, on: screen)
    else {
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
    let alignedWithScreen =
      abs(frame.minX - screenFrame.minX) <= tolerance
      && abs(frame.minY - screenFrame.minY) <= tolerance

    return coversScreenWidth && coversScreenHeight && alignedWithScreen
  }

  private func syncLockWindowFrame(processID: pid_t) {
    guard let lockWindow = lockWindows[processID],
      let session = lockedSessions[processID]
    else {
      return
    }

    let contentFrame = lockContentFrame(
      centeredIn: currentOverlayFrame(processID: processID, app: session.app))
    lockWindow.setFrame(
      lockWindow.frameRect(forContentRect: contentFrame), display: true, animate: false)
  }

  private func currentOverlayFrame(processID: pid_t, app: NSRunningApplication) -> NSRect {
    guard let rawSnapshot = windowSnapshotProvider.snapshot(for: app) else {
      return lockedSessions[processID]?.lastKnownFrame ?? fallbackPromptFrame().integral
    }

    let snapshot = WindowSnapshot(
      frame: lockFrame(forTargetFrame: rawSnapshot.frame),
      source: rawSnapshot.source
    )
    if var session = lockedSessions[processID] {
      session.lastKnownFrame = snapshot.frame
      session.lastFrameSource = snapshot.source
      lockedSessions[processID] = session
    }

    return snapshot.frame
  }

  private func updateStoredFrameIfAvailable(for processID: pid_t, app: NSRunningApplication) {
    guard let snapshot = windowSnapshotProvider.snapshot(for: app),
      var session = lockedSessions[processID]
    else {
      return
    }

    session.lastKnownFrame = lockFrame(forTargetFrame: snapshot.frame)
    session.lastFrameSource = snapshot.source
    lockedSessions[processID] = session
    logSessionEvent(
      processID: processID,
      app: app,
      event: "frame-updated",
      detail: "source=\(snapshot.source.rawValue) frame=\(describe(session.lastKnownFrame))"
    )
  }

  private func bringLockWindowToFront(processID: pid_t, reason: String) {
    guard let lockWindow = lockWindows[processID] else {
      return
    }

    transitionSession(processID: processID, to: .presenting, reason: reason)
    syncLockWindowFrame(processID: processID)
    activateForLockPresentation()
    NSApp.activate(ignoringOtherApps: true)
    lockWindow.orderFrontRegardless()
    lockWindow.makeKeyAndOrderFront(nil)
    logSessionEvent(
      processID: processID,
      app: lockedSessions[processID]?.app,
      event: "window-fronted",
      detail: "reason=\(reason) frame=\(describe(lockWindow.frame))"
    )
  }

  private func activateForLockPresentation() {
    if !hasVisibleMainWindow {
      NSApp.setActivationPolicy(.accessory)
    }
  }

  private func hideLockedApp(_ app: NSRunningApplication, processID: pid_t, reason: String) {
    guard isPresentingLock(for: processID), !app.isTerminated else {
      return
    }

    transitionSession(processID: processID, to: .hiding, reason: reason)
    app.hide()
    logSessionEvent(
      processID: processID,
      app: app,
      event: "app-hidden",
      detail: "reason=\(reason) hidden=\(app.isHidden)"
    )
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
      activityLog.record(
        "Touch ID Unavailable",
        detail: error?.localizedDescription ?? "Biometric authentication is not available.")
      return
    }

    let appName = lockedSessions[processID]?.app.localizedName ?? "this app"

    context.evaluatePolicy(
      .deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock \(appName)"
    ) { [weak self] success, evaluationError in
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
    activityLog.record(
      "Quit Locked App", detail: lockedSessions[processID]?.app.localizedName ?? "Protected app")
    lockedSessions[processID]?.app.terminate()
    dismiss(processID: processID, unlocked: false)
  }

  private func dismiss(processID: pid_t, unlocked: Bool) {
    reassertionTasks.removeValue(forKey: processID)?.cancel()
    transitionSession(
      processID: processID,
      to: unlocked ? .unlocked : .dismissed,
      reason: unlocked ? "unlock succeeded" : "dismissed without unlock"
    )
    let session = lockedSessions.removeValue(forKey: processID)
    let lockWindow = lockWindows.removeValue(forKey: processID)
    let completion = completions.removeValue(forKey: processID)

    lockWindow?.orderOut(nil)
    lockWindow?.close()

    if unlocked, let session {
      session.app.unhide()
      session.app.activate(options: [.activateAllWindows])
    }

    restoreAccessoryActivationIfPossible()
    completion?(unlocked)
  }

  private func startReassertionLoop(processID: pid_t) {
    reassertionTasks.removeValue(forKey: processID)?.cancel()

    reassertionTasks[processID] = Task { @MainActor [weak self] in
      let delays: [UInt64] = [80_000_000, 180_000_000, 340_000_000, 620_000_000, 1_000_000_000]

      for (attempt, delay) in delays.enumerated() {
        do {
          try await Task.sleep(nanoseconds: delay)
        } catch {
          return
        }

        guard let self,
          let session = self.lockedSessions[processID],
          !session.app.isTerminated
        else {
          return
        }

        self.reassertLock(for: session.app, reason: "reassertion loop attempt \(attempt + 1)")
      }

      self?.reassertionTasks.removeValue(forKey: processID)
    }
  }

  private func transitionSession(processID: pid_t, to state: LockSessionState, reason: String) {
    if var session = lockedSessions[processID] {
      guard session.state != state else {
        return
      }

      let previousState = session.state
      session.state = state
      lockedSessions[processID] = session
      logSessionEvent(
        processID: processID,
        app: session.app,
        event: "state",
        detail: "\(previousState.rawValue) -> \(state.rawValue), reason=\(reason)"
      )
    } else {
      logger.debug("pid=\(processID, privacy: .public) state=new -> \(state.rawValue, privacy: .public), reason=\(reason, privacy: .public)")
    }
  }

  private func logSessionEvent(
    processID: pid_t,
    app: NSRunningApplication?,
    event: String,
    detail: String
  ) {
    let appName = app?.localizedName ?? "unknown"
    let bundleIdentifier = app?.bundleIdentifier ?? "unknown"
    logger.debug(
      "event=\(event, privacy: .public) pid=\(processID, privacy: .public) app=\(appName, privacy: .public) bundle=\(bundleIdentifier, privacy: .public) \(detail, privacy: .public)"
    )
  }

  private func describe(_ frame: NSRect) -> String {
    "x=\(Int(frame.origin.x)) y=\(Int(frame.origin.y)) w=\(Int(frame.width)) h=\(Int(frame.height))"
  }

  private func restoreAccessoryActivationIfPossible() {
    restoreAccessoryActivation()

    DispatchQueue.main.async { [weak self] in
      self?.restoreAccessoryActivation()
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      self?.restoreAccessoryActivation()
    }
  }

  private func restoreAccessoryActivation() {
    guard canRestoreAccessoryActivation else {
      return
    }

    NSApp.hide(nil)
    NSApp.setActivationPolicy(.accessory)
  }

  private var canRestoreAccessoryActivation: Bool {
    lockWindows.isEmpty && !hasVisibleMainWindow
  }

  private var hasVisibleMainWindow: Bool {
    NSApp.windows.contains(where: { $0 is MainAppWindow && $0.isVisible })
  }

  private func icon(for app: NSRunningApplication) -> NSImage {
    if let url = app.bundleURL {
      let icon = NSWorkspace.shared.icon(forFile: url.path)
      icon.size = NSSize(width: 72, height: 72)
      return icon
    }

    let fallback =
      NSImage(systemSymbolName: "lock.desktopcomputer", accessibilityDescription: nil)
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
  var state: LockSessionState
  var lastKnownFrame: NSRect
  var lastFrameSource: WindowSnapshotSource
}

private enum LockSessionState: String {
  case pending
  case hiding
  case presenting
  case unlocked
  case dismissed
}

extension NSRect {
  fileprivate func intersectionOrSelf(_ other: NSRect) -> NSRect {
    let intersection = intersection(other)
    guard !intersection.isNull,
      intersection.width > 0,
      intersection.height > 0
    else {
      return self
    }

    return intersection
  }
}

final class LockWindow: NSWindow {
  var lockedProcessID: pid_t = 0
  var onCommandQuit: (() -> Void)?
  var onClose: (() -> Void)?

  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func performClose(_ sender: Any?) {
    onClose?()
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown else {
      return super.performKeyEquivalent(with: event)
    }

    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

    if modifiers == [.command], event.charactersIgnoringModifiers == "q" {
      onCommandQuit?()
      return true
    }

    if modifiers == [.command], event.charactersIgnoringModifiers == "w" {
      onClose?()
      return true
    }

    return super.performKeyEquivalent(with: event)
  }
}
