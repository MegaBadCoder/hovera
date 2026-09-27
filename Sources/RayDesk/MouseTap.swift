import AppKit
import RayDeskCore

protocol MouseTapDelegate: AnyObject {
    func screenIndex(at point: CGPoint) -> Int?
    func gazeHit() -> GazeHit?
    func cursorHit() -> CursorHit?
    func cursorTarget(at point: CGPoint) -> CursorTarget?
    func warpTarget(cursor: CursorTarget?) -> CursorTarget?
    func remappedCursor(previous: CGPoint, proposed: CGPoint, delta: CGVector) -> CGPoint?
    func bounds(of screen: Int) -> CGRect
    func bounds(of target: CursorTarget) -> CGRect
    func pose(of screen: Int) -> ScreenPose
    func setPose(_ screen: Int, _ pose: ScreenPose)
    func dragBegan(_ screen: Int)
    func dragEnded()
    func scrollApplied(to screen: Int)
    func cursorScreenChanged(_ screen: Int?)
}

final class MouseTap {
    private weak var delegate: MouseTapDelegate?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var draggingScreen: Int?
    private var lastLocation: CGPoint?

    init?(delegate: MouseTapDelegate) {
        self.delegate = delegate
        self.eventTap = nil
        self.runLoopSource = nil
        self.draggingScreen = nil

        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDown.rawValue) |
            (1 << CGEventType.otherMouseUp.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<MouseTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return nil }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        if draggingScreen != nil {
            CGAssociateMouseAndMouseCursorPosition(1)
            draggingScreen = nil
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard let delegate else { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        let hotkey = flags.contains(.maskControl) && flags.contains(.maskAlternate)

        switch type {
        case .leftMouseDown:
            if hotkey, let target = dragTarget(event: event, delegate: delegate) {
                draggingScreen = target
                CGAssociateMouseAndMouseCursorPosition(0)
                delegate.dragBegan(target)
                return nil
            }
        case .leftMouseDragged:
            updateCursorScreen(event: event, delegate: delegate)
            lastLocation = event.location
            if let target = draggingScreen {
                applyDrag(target: target, event: event, delegate: delegate)
                return nil
            }
        case .leftMouseUp:
            if draggingScreen != nil {
                CGAssociateMouseAndMouseCursorPosition(1)
                draggingScreen = nil
                delegate.dragEnded()
                return nil
            }
        case .rightMouseDragged, .otherMouseDragged:
            updateCursorScreen(event: event, delegate: delegate)
        case .scrollWheel:
            if hotkey, let target = dragTarget(event: event, delegate: delegate) {
                let delta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
                delegate.setPose(target, scrolled(delegate.pose(of: target), by: delta))
                delegate.scrollApplied(to: target)
                return nil
            }
        case .mouseMoved:
            guard draggingScreen == nil else { break }
            let previous = lastLocation ?? event.location
            let delta = CGVector(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
            if let remapped = delegate.remappedCursor(previous: previous, proposed: event.location, delta: delta) {
                move(event, to: remapped)
            }
            warp(event: event, delegate: delegate)
            delegate.cursorScreenChanged(delegate.screenIndex(at: event.location))
            lastLocation = event.location
            return Unmanaged.passUnretained(event)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    private func dragTarget(event: CGEvent, delegate: MouseTapDelegate) -> Int? {
        delegate.screenIndex(at: event.location) ?? delegate.gazeHit()?.screen
    }

    private func applyDrag(target: Int, event: CGEvent, delegate: MouseTapDelegate) {
        let dx = event.getDoubleValueField(.mouseEventDeltaX)
        let dy = event.getDoubleValueField(.mouseEventDeltaY)
        let width = delegate.bounds(of: target).width
        let pose = dragged(delegate.pose(of: target), byPoints: CGVector(dx: dx, dy: dy), displayPointWidth: Double(width))
        delegate.setPose(target, pose)
    }

    private func updateCursorScreen(event: CGEvent, delegate: MouseTapDelegate) {
        delegate.cursorScreenChanged(delegate.screenIndex(at: event.location))
    }

    private func warp(event: CGEvent, delegate: MouseTapDelegate) {
        guard let target = delegate.warpTarget(cursor: delegate.cursorTarget(at: event.location)),
              let hit = delegate.cursorHit(), hit.target == target
        else { return }
        move(event, to: globalPoint(uv: hit.uv, in: delegate.bounds(of: target)))
        log("mouse warp -> \(target)")
    }

    private func move(_ event: CGEvent, to point: CGPoint) {
        event.location = point
        CGWarpMouseCursorPosition(point)
        // без этого macOS ещё ~0,25 с после варпа игнорирует движение мыши
        CGAssociateMouseAndMouseCursorPosition(1)
    }
}
