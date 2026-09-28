import AppKit
import ApplicationServices
import RayDeskCore

enum WindowMoveError: Error {
    case noAccessibility
    case noFrontWindow
    case unreadableFrame
    case rejected(AXError)
}

enum WindowMover {
    static func moveFrontWindow(to target: CGDirectDisplayID) throws -> (app: String, frame: CGRect) {
        guard AXIsProcessTrusted() else { throw WindowMoveError.noAccessibility }
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier,
              let window = focusedWindow(of: app.processIdentifier)
        else { throw WindowMoveError.noFrontWindow }
        guard let position: CGPoint = value(of: window, kAXPositionAttribute, .cgPoint),
              let size: CGSize = value(of: window, kAXSizeAttribute, .cgSize)
        else { throw WindowMoveError.unreadableFrame }

        let current = CGRect(origin: position, size: size)
        let frame = movedWindowFrame(current, from: usableArea(of: display(containing: current)), to: usableArea(of: target))
        try set(window, kAXPositionAttribute, frame.origin, .cgPoint)
        try set(window, kAXSizeAttribute, frame.size, .cgSize)
        try set(window, kAXPositionAttribute, frame.origin, .cgPoint)
        return (app.localizedName ?? app.bundleIdentifier ?? "?", frame)
    }

    private static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attribute as CFString, &window) == .success, let window {
                return (window as! AXUIElement)
            }
        }
        return nil
    }

    private static func display(containing frame: CGRect) -> CGDirectDisplayID {
        var display = CGMainDisplayID()
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(CGPoint(x: frame.midX, y: frame.midY), 1, &display, &count)
        return count > 0 ? display : CGMainDisplayID()
    }

    private static func usableArea(of display: CGDirectDisplayID) -> CGRect {
        let bounds = CGDisplayBounds(display)
        guard let screen = NSScreen.screens.first(where: { $0.displayID == display }) else { return bounds }
        let frame = screen.frame
        let visible = screen.visibleFrame
        return CGRect(x: bounds.minX + (visible.minX - frame.minX),
                      y: bounds.minY + (frame.maxY - visible.maxY),
                      width: visible.width, height: visible.height)
    }

    private static func value<T>(of element: AXUIElement, _ attribute: String, _ type: AXValueType) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success, let raw,
              CFGetTypeID(raw) == AXValueGetTypeID()
        else { return nil }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AXValueGetValue(raw as! AXValue, type, pointer) else { return nil }
        return pointer.pointee
    }

    private static func set(_ element: AXUIElement, _ attribute: String, _ point: CGPoint, _ type: AXValueType) throws {
        var point = point
        try set(element, attribute, AXValueCreate(type, &point))
    }

    private static func set(_ element: AXUIElement, _ attribute: String, _ size: CGSize, _ type: AXValueType) throws {
        var size = size
        try set(element, attribute, AXValueCreate(type, &size))
    }

    private static func set(_ element: AXUIElement, _ attribute: String, _ wrapped: AXValue?) throws {
        guard let wrapped else { throw WindowMoveError.unreadableFrame }
        let status = AXUIElementSetAttributeValue(element, attribute as CFString, wrapped)
        guard status == .success else { throw WindowMoveError.rejected(status) }
    }
}
