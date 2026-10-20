import AppKit
import AVFoundation
import QuartzCore
import RayDeskCore
import RayDeskLocalization

final class CameraDebugWindow {
    private let window: NSWindow
    private let preview: AVCaptureVideoPreviewLayer
    private let boxLayer = CAShapeLayer()
    private let pointsLayer = CAShapeLayer()
    private let glassesLayer = CAShapeLayer()
    private let motionLayer = CAShapeLayer()
    private let motionBoxLayer = CAShapeLayer()
    private let textLayer = CATextLayer()

    init(session: AVCaptureSession, on screen: NSScreen?) {
        let size = NSSize(width: 960, height: 600)
        let area = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: size)
        let frame = NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height)
        window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = t(.cameraDebugTitle)
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
        for layer in [boxLayer, pointsLayer, glassesLayer, motionLayer, motionBoxLayer] {
            layer.isGeometryFlipped = true
            layer.frame = view.bounds
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
            layer.fillColor = nil
            view.layer?.addSublayer(layer)
        }
        boxLayer.lineWidth = 3
        pointsLayer.fillColor = NSColor.systemYellow.cgColor
        glassesLayer.fillColor = NSColor.systemTeal.cgColor
        motionLayer.fillColor = NSColor.systemOrange.cgColor
        motionLayer.strokeColor = NSColor.systemOrange.cgColor
        motionLayer.lineWidth = 2
        motionBoxLayer.strokeColor = NSColor.systemRed.withAlphaComponent(0.8).cgColor
        motionBoxLayer.lineWidth = 1.5
        motionBoxLayer.lineDashPattern = [4, 3]
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

    func applyLanguage() {
        window.title = t(.cameraDebugTitle)
    }

    func update(_ observation: CameraObservation) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        updateMotion(observation)
        let glassesDots = CGMutablePath()
        for point in observation.glassesPoints {
            let p = preview.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: point.x, y: 1 - point.y))
            glassesDots.addEllipse(in: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3))
        }
        glassesLayer.path = glassesDots
        guard let face = observation.face else {
            boxLayer.path = nil
            pointsLayer.path = nil
            textLayer.string = (observation.glassesNote ?? t(.cameraNoteNoFace)) + motionText(observation)
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
        let neck = observation.neckOffset * 100
        let degree = 180 / Double.pi
        textLayer.string = String(format: t(.cameraDebugReadings),
                                          neck.x, neck.y, neck.z, observation.turn.x * degree, observation.turn.y * degree, face.width,
                                          verdictText(observation.verdict)) + (observation.glassesNote.map { "\n " + $0 } ?? "") + motionText(observation)
    }

    /// Рисует область сравнения фона: точки, которые реально участвуют в сравнении, и найденный сдвиг.
    private func updateMotion(_ observation: CameraObservation) {
        guard observation.motionEnabled else {
            motionLayer.path = nil
            motionBoxLayer.path = nil
            return
        }
        let path = CGMutablePath()
        let step = 8
        let margin = CameraMotionDetector.search + 1
        let width = CameraMotionDetector.width, height = CameraMotionDetector.height
        let excluded = observation.motionExclusion.map { rect in
            MotionRegion(minX: Int((rect.minX * Double(width)).rounded()),
                         minY: Int(((1 - rect.maxY) * Double(height)).rounded()),
                         maxX: Int((rect.maxX * Double(width)).rounded()),
                         maxY: Int(((1 - rect.minY) * Double(height)).rounded()))
        }
        for y in stride(from: margin, to: height - margin, by: step) {
            for x in stride(from: margin, to: width - margin, by: step) {
                if let excluded, x >= excluded.minX, x < excluded.maxX, y >= excluded.minY, y < excluded.maxY { continue }
                let point = preview.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: Double(x) / Double(width),
                                                                                        y: 1 - Double(y) / Double(height)))
                path.addEllipse(in: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2))
            }
        }
        let center = preview.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: 0.5, y: 0.5))
        let scale = preview.bounds.width / Double(width) * 5
        let tip = CGPoint(x: center.x + Double(observation.motionShift.x) * scale,
                          y: center.y - Double(observation.motionShift.y) * scale)
        path.move(to: center)
        path.addLine(to: tip)
        motionLayer.path = path
        motionBoxLayer.path = observation.motionExclusion.map { CGPath(rect: preview.layerRectConverted(fromMetadataOutputRect: $0), transform: nil) }
    }

    /// Строка о движении фона для текстового слоя окна отладки.
    private func motionText(_ observation: CameraObservation) -> String {
        guard observation.motionEnabled else { return "" }
        let state = observation.motionMoving ? t(.cameraMotionDebugMoving) : t(.cameraMotionDebugStill)
        return "\n" + String(format: t(.cameraMotionDebug), observation.motionShift.x, observation.motionShift.y,
                             observation.motionImprovement, state)
    }

    private func verdictText(_ verdict: CameraFrameVerdict) -> String {
        switch verdict {
        case .accepted, .noFace: ""
        case .learning: t(.cameraDebugVerdictLearning)
        case .turned: t(.cameraDebugVerdictTurned)
        case .tilted: t(.cameraDebugVerdictTilted)
        case .fast: t(.cameraDebugVerdictFast)
        }
    }
}
