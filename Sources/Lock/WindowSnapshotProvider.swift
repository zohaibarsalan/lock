import AppKit
import ApplicationServices

enum WindowSnapshotSource: String {
  case cgWindow
  case accessibility
  case fallback
}

struct WindowSnapshot {
  let frame: NSRect
  let source: WindowSnapshotSource
}

@MainActor
protocol WindowSnapshotProviding {
  func snapshot(for app: NSRunningApplication) -> WindowSnapshot?
}

@MainActor
struct SystemWindowSnapshotProvider: WindowSnapshotProviding {
  func snapshot(for app: NSRunningApplication) -> WindowSnapshot? {
    if let frame = CGWindowBridge.primaryFrame(for: app) {
      return WindowSnapshot(frame: frame, source: .cgWindow)
    }

    if let frame = AXWindowBridge.primaryFrame(for: app) {
      return WindowSnapshot(frame: frame, source: .accessibility)
    }

    return nil
  }
}

private enum CGWindowBridge {
  static func primaryFrame(for app: NSRunningApplication) -> NSRect? {
    frames(for: app).max { lhs, rhs in
      lhs.width * lhs.height < rhs.width * rhs.height
    }
  }

  private static func frames(for app: NSRunningApplication) -> [NSRect] {
    guard
      let windowInfo = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else {
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
        frame.height > 48
      else {
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
      height > 0
    else {
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

    if screens.contains(where: {
      $0.frame.intersects(converted)
        || $0.frame.contains(NSPoint(x: converted.midX, y: converted.midY))
    }) {
      return converted
    }

    return frame
  }
}

private enum AXWindowBridge {
  static func primaryFrame(for app: NSRunningApplication) -> NSRect? {
    guard let window = primaryWindow(for: app),
      let frame = frame(for: window)
    else {
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
      let sizeValue = axValue(of: kAXSizeAttribute as CFString, on: window)
    else {
      return nil
    }

    var position = CGPoint.zero
    var size = CGSize.zero

    guard AXValueGetValue(positionValue, .cgPoint, &position),
      AXValueGetValue(sizeValue, .cgSize, &size)
    else {
      return nil
    }

    return NSRect(origin: position, size: size)
  }

  private static func elementValue(of attribute: CFString, on element: AXUIElement?) -> AXUIElement?
  {
    guard let element else {
      return nil
    }

    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success,
      let value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }

    return (value as! AXUIElement)
  }

  private static func arrayValue(of attribute: CFString, on element: AXUIElement?) -> [AXUIElement]?
  {
    guard let element else {
      return nil
    }

    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success,
      let array = value as? [AXUIElement]
    else {
      return nil
    }

    return array
  }

  private static func axValue(of attribute: CFString, on element: AXUIElement?) -> AXValue? {
    guard let element else {
      return nil
    }

    var value: CFTypeRef?
    let result = AXUIElementCopyAttributeValue(element, attribute, &value)
    guard result == .success,
      let value,
      CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }

    return (value as! AXValue)
  }
}
