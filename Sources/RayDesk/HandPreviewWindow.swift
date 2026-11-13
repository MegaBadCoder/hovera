import AppKit
import Vision
import simd

/// Окно превью камеры очков с наложенным скелетом кистей.
final class HandPreviewWindow: NSWindow, NSWindowDelegate {
    private let canvas = HandCanvas()
    private var lastStatus = ""

    /// Что сделать, когда окно закрыли: превью не живёт без камеры.
    var onClose: (() -> Void)?

    /// Заголовок обновляется по данным камеры: частота, число рук.
    func update(frame: HandCamera.Frame, framesPerSecond: Double) {
        canvas.frameImage = frame.image
        canvas.hands = frame.hands
        canvas.needsDisplay = true
        let status = String(format: "Камера очков · %.0f к/с · рук: %d · %d×%d",
                            framesPerSecond, frame.hands.count, frame.width, frame.height)
        if status != lastStatus {
            lastStatus = status
            title = status
        }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 405),
                   styleMask: [.titled, .closable, .resizable],
                   backing: .buffered, defer: false)
        title = "Камера очков"
        contentView = canvas
        isReleasedWhenClosed = false
        delegate = self
        center()
    }
}

private final class HandCanvas: NSView {
    var frameImage: CGImage?
    var hands: [HandCamera.Hand] = []

    private static let connections: [(VNHumanHandPoseObservation.JointName, VNHumanHandPoseObservation.JointName)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
    ]

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let frameImage else { return }
        let imageSize = NSSize(width: frameImage.width, height: frameImage.height)
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = NSPoint(x: (bounds.width - drawSize.width) / 2, y: (bounds.height - drawSize.height) / 2)
        NSImage(cgImage: frameImage, size: imageSize).draw(in: NSRect(origin: origin, size: drawSize))

        NSColor.systemGreen.setStroke()
        NSColor.systemRed.setFill()
        for hand in hands {
            for (from, to) in Self.connections {
                guard let a = hand.joints[from], let b = hand.joints[to] else { continue }
                let path = NSBezierPath()
                path.lineWidth = 2
                path.move(to: point(a, origin: origin, size: drawSize))
                path.line(to: point(b, origin: origin, size: drawSize))
                path.stroke()
            }
            for joint in hand.joints.values {
                let center = point(joint, origin: origin, size: drawSize)
                NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)).fill()
            }
        }
    }

    private func point(_ value: SIMD2<Double>, origin: NSPoint, size: NSSize) -> NSPoint {
        NSPoint(x: origin.x + value.x * size.width, y: origin.y + value.y * size.height)
    }
}
