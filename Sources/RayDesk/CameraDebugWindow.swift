import AppKit
import AVFoundation
import QuartzCore

final class CameraDebugWindow {
    private let window: NSWindow
    private let preview: AVCaptureVideoPreviewLayer
    private let boxLayer = CAShapeLayer()
    private let pointsLayer = CAShapeLayer()
    private let textLayer = CATextLayer()

    init(session: AVCaptureSession, on screen: NSScreen?) {
        let size = NSSize(width: 960, height: 600)
        let area = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let frame = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "RayDesk — камера"
        window.isReleasedWhenClosed = false
        window.level = .floating
        let view = NSView(frame: NSRect(origin: .zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspect
        preview.frame = view.bounds
        preview.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(preview)
        for layer in [boxLayer, pointsLayer] {
            layer.isGeometryFlipped = true
            layer.frame = view.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.fillColor = nil
            view.layer?.addSublayer(layer)
        }
        boxLayer.lineWidth = 3
        pointsLayer.fillColor = NSColor.systemYellow.cgColor
        textLayer.frame = NSRect(x: 12, y: 12, width: size.width - 24, height: 70)
        textLayer.autoresizingMask = [.layerWidthSizable]
        textLayer.fontSize = 18
        textLayer.foregroundColor = NSColor.white.cgColor
        textLayer.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        textLayer.contentsScale = 2
        view.layer?.addSublayer(textLayer)
        window.contentView = view
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        window.orderFrontRegardless()
    }

    func close() {
        window.orderOut(nil)
    }

    func update(_ observation: CameraObservation) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let face = observation.face else {
            boxLayer.path = nil
            pointsLayer.path = nil
            textLayer.string = "лицо не найдено"
            return
        }
        let rect = preview.layerRectConverted(fromMetadataOutputRect: CGRect(x: face.minX, y: 1 - face.maxY, width: face.width, height: face.height))
        boxLayer.path = CGPath(rect: rect, transform: nil)
        boxLayer.strokeColor = (observation.accepted ? NSColor.systemGreen : NSColor.systemRed).cgColor
        let dots = CGMutablePath()
        for point in observation.landmarks {
            let p = preview.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: point.x, y: 1 - point.y))
            dots.addEllipse(in: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
        }
        pointsLayer.path = dots
        let neck = observation.neckOffset * 100
        let degree = 180 / Double.pi
        textLayer.string = String(format: " шея: x %+.1f  y %+.1f  z %+.1f см\n поворот головы: %+.0f°  наклон %+.0f°  рамка %.3f%@",
                                  neck.x, neck.y, neck.z, observation.turn.x * degree, observation.turn.y * degree, face.width,
                                  observation.accepted ? "" : "  · кадр отброшен")
    }
}
