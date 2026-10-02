import AppKit
import AVFoundation
import QuartzCore

final class CameraDebugWindow {
    private let window: NSWindow
    private let preview: AVCaptureVideoPreviewLayer
    private let boxLayer = CAShapeLayer()
    private let pointsLayer = CAShapeLayer()
    private let glassesLayer = CAShapeLayer()
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
        for layer in [boxLayer, pointsLayer, glassesLayer] {
            layer.isGeometryFlipped = true
            layer.frame = view.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.fillColor = nil
            view.layer?.addSublayer(layer)
        }
        boxLayer.lineWidth = 3
        pointsLayer.fillColor = NSColor.systemYellow.cgColor
        glassesLayer.fillColor = NSColor.systemTeal.cgColor
        textLayer.frame = NSRect(x: 12, y: 12, width: size.width - 24, height: 118)
        textLayer.isWrapped = true
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
        let glassesDots = CGMutablePath()
        for point in observation.glassesPoints {
            let p = preview.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: point.x, y: 1 - point.y))
            glassesDots.addEllipse(in: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3))
        }
        glassesLayer.path = glassesDots
        guard let face = observation.face else {
            boxLayer.path = nil
            pointsLayer.path = nil
            textLayer.string = observation.glassesNote ?? "лицо не найдено"
            return
        }
        let rect = preview.layerRectConverted(fromMetadataOutputRect: CGRect(x: face.minX, y: 1 - face.maxY, width: face.width, height: face.height))
        boxLayer.path = CGPath(rect: rect, transform: nil)
        boxLayer.strokeColor = switch observation.verdict {
        case .accepted: NSColor.systemGreen.cgColor
        case .learning: NSColor.systemYellow.cgColor
        default: NSColor.systemRed.cgColor
        }
        let dots = CGMutablePath()
        for point in observation.landmarks {
            let p = preview.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: point.x, y: 1 - point.y))
            let radius = observation.glassesNote == nil ? 2.0 : 1.0
            dots.addEllipse(in: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius))
        }
        pointsLayer.path = dots
        if observation.headingOnly {
            textLayer.string = observation.glassesNote
            return
        }
        let neck = observation.neckOffset * 100
        let degree = 180 / Double.pi
        textLayer.string = String(format: " шея: x %+.1f  y %+.1f  z %+.1f см\n от камеры: поворот %+.0f°  наклон %+.0f°  рамка %.3f%@",
                                  neck.x, neck.y, neck.z, observation.turn.x * degree, observation.turn.y * degree, face.width,
                                  verdictText(observation.verdict)) + (observation.glassesNote.map { "\n " + $0 } ?? "")
    }

    private func verdictText(_ verdict: CameraFrameVerdict) -> String {
        switch verdict {
        case .accepted, .noFace: ""
        case .learning: "  · смотрите в камеру, запоминаю"
        case .cropped: "  · лицо обрезано краем кадра"
        case .turned: "  · голова отвёрнута от камеры"
        case .tilted: "  · голова сильно наклонена"
        case .fast: "  · быстрый поворот"
        }
    }
}
