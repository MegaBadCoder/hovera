import AppKit
import AVFoundation
import RayDeskCore
import RayDeskLocalization

@MainActor
final class CameraCalibrationWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let preview: AVCaptureVideoPreviewLayer
    private let guide = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let cameraView = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let stepLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let applyButton = NSButton(title: "", target: nil, action: nil)
    private let cancelButton = NSButton(title: "", target: nil, action: nil)
    private let retryButton = NSButton(title: "", target: nil, action: nil)
    private var model = GuidedCameraCalibration()
    private var expectedGeneration: Int
    private var started = ProcessInfo.processInfo.systemUptime
    private var lastFrame = ProcessInfo.processInfo.systemUptime
    private var timer: Timer?
    private var finished = false
    private var lastDiagnostic = ""
    private var lastDiagnosticTime = -Double.infinity
    private let restart: () -> Int
    private let complete: (GuidedCameraCalibration.Result) -> Void
    private let cancel: () -> Void

    init(session: AVCaptureSession, on screen: NSScreen?, generation: Int,
         restart: @escaping () -> Int, complete: @escaping (GuidedCameraCalibration.Result) -> Void,
         cancel: @escaping () -> Void) {
        self.expectedGeneration = generation
        self.restart = restart; self.complete = complete; self.cancel = cancel
        let size = NSSize(width: 840, height: 650)
        let area = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: size)
        window = NSWindow(contentRect: NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                              width: size.width, height: size.height),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init()
        window.title = t(.calibrationWindowTitle)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = content
        stepLabel.textColor = .secondaryLabelColor
        stepLabel.font = .systemFont(ofSize: 13, weight: .medium)
        stepLabel.frame = NSRect(x: 28, y: 601, width: 780, height: 20)
        titleLabel.font = .systemFont(ofSize: 25, weight: .semibold)
        titleLabel.frame = NSRect(x: 28, y: 558, width: 784, height: 34)
        cameraView.frame = NSRect(x: 28, y: 158, width: 784, height: 384)
        cameraView.wantsLayer = true
        cameraView.layer?.backgroundColor = NSColor.black.cgColor
        cameraView.layer?.cornerRadius = 16
        cameraView.layer?.masksToBounds = true
        preview.frame = cameraView.bounds
        preview.videoGravity = .resizeAspect
        cameraView.layer?.addSublayer(preview)
        for shape in [guide, outline] {
            shape.frame = cameraView.bounds
            shape.isGeometryFlipped = true
            shape.fillColor = nil
            shape.lineWidth = 2
            cameraView.layer?.addSublayer(shape)
        }
        guide.strokeColor = NSColor.white.withAlphaComponent(0.65).cgColor
        guide.lineDashPattern = [8, 6]
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: 278, y: 42, width: 228, height: 270))
        path.move(to: CGPoint(x: 320, y: 315))
        path.addQuadCurve(to: CGPoint(x: 230, y: 370), control: CGPoint(x: 258, y: 323))
        path.move(to: CGPoint(x: 464, y: 315))
        path.addQuadCurve(to: CGPoint(x: 554, y: 370), control: CGPoint(x: 526, y: 323))
        // Очки внутри контура — ориентир, а не требование точного совмещения.
        path.addRoundedRect(in: CGRect(x: 309, y: 145, width: 75, height: 44), cornerWidth: 12, cornerHeight: 12)
        path.addRoundedRect(in: CGRect(x: 400, y: 145, width: 75, height: 44), cornerWidth: 12, cornerHeight: 12)
        path.move(to: CGPoint(x: 384, y: 159)); path.addLine(to: CGPoint(x: 400, y: 159))
        guide.path = path
        cameraView.setAccessibilityLabel(t(.calibrationPreviewLabel))
        hintLabel.font = .systemFont(ofSize: 15)
        hintLabel.frame = NSRect(x: 28, y: 102, width: 784, height: 44)
        progress.isIndeterminate = false
        progress.minValue = 0; progress.maxValue = 1
        progress.style = .bar
        progress.frame = NSRect(x: 28, y: 86, width: 784, height: 8)
        progress.setAccessibilityLabel(t(.calibrationSteadinessLabel))
        cancelButton.title = t(.calibrationCancel)
        cancelButton.target = self; cancelButton.action = #selector(closeWindow)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.frame = NSRect(x: 28, y: 23, width: 100, height: 32)
        retryButton.title = t(.calibrationRetry)
        retryButton.target = self; retryButton.action = #selector(retryCalibration)
        retryButton.frame = NSRect(x: 137, y: 23, width: 145, height: 32)
        applyButton.title = t(.calibrationApply)
        applyButton.target = self; applyButton.action = #selector(applyCalibration)
        applyButton.frame = NSRect(x: 672, y: 23, width: 140, height: 32)
        applyButton.keyEquivalent = "\r"
        applyButton.isEnabled = false
        for view in [stepLabel, titleLabel, cameraView, hintLabel, progress, cancelButton, retryButton, applyButton] { content.addSubview(view) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.model.checkTimeout(at: ProcessInfo.processInfo.systemUptime)
                if ProcessInfo.processInfo.systemUptime - self.lastFrame > 0.5 {
                    self.model.interrupt()
                }
                self.render()
            }
        }
    }
    func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func applyLanguage() {
        window.title = t(.calibrationWindowTitle)
        titleLabel.stringValue = t(.calibrationTitleInitial)
        hintLabel.stringValue = t(.calibrationHintInitial)
        stepLabel.stringValue = t(.calibrationStepCentre)
        cancelButton.title = t(.calibrationCancel)
        retryButton.title = t(.calibrationRetry)
        applyButton.title = t(.calibrationApply)
        cameraView.setAccessibilityLabel(t(.calibrationPreviewLabel))
        progress.setAccessibilityLabel(t(.calibrationSteadinessLabel))
        render()
    }
    func update(_ observation: CameraObservation) {
        guard !finished else { return }
        lastFrame = ProcessInfo.processInfo.systemUptime
        guard observation.referenceGeneration == expectedGeneration else {
            model.invalidate(.calibrationCameraSettingsChanged)
            render(); return
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let face = observation.face {
            let rect = preview.layerRectConverted(fromMetadataOutputRect: CGRect(x: face.minX, y: 1 - face.maxY, width: face.width, height: face.height))
            outline.path = CGPath(roundedRect: rect, cornerWidth: 16, cornerHeight: 16, transform: nil)
        } else { outline.path = nil }
        CATransaction.commit()
        if let sample = observation.calibrationSample, sample.time >= started { model.update(sample) }
        else {
            model.checkTimeout(at: ProcessInfo.processInfo.systemUptime)
            model.interrupt(.hintFaceNotRecognised)
        }
        render()
    }
    private func render() {
        let diagnostic = "stage \(model.stage) · \(t(model.hint))"
        let now = ProcessInfo.processInfo.systemUptime
        if diagnostic != lastDiagnostic && now - lastDiagnosticTime >= 1 {
            log("camera calibration: \(diagnostic)")
            lastDiagnostic = diagnostic; lastDiagnosticTime = now
        }
        let titles: [UIString] = [.calibrationTitleSitStill, .calibrationTitleTurnLeft, .calibrationTitleReturnToCentre,
                                  .calibrationTitleTurnRight, .calibrationTitleReturnToStart, .calibrationTitleReady,
                                  .calibrationTitleTryAgain]
        let steps: [UIString] = [.calibrationStepCentre, .calibrationStepTurnLeft, .calibrationStepCheckCentre,
                                 .calibrationStepTurnRight, .calibrationStepCheckReturn, .calibrationStepCheckPassed,
                                 .calibrationStepNotApplied]
        titleLabel.stringValue = model.stage == .position ? t(.calibrationLookAndHold) : t(titles[model.stage.rawValue])
        stepLabel.stringValue = model.stage == .complete ? t(.calibrationCentreRemembered) : t(steps[model.stage.rawValue])
        hintLabel.stringValue = t(model.hint)
        progress.doubleValue = model.progress
        applyButton.isEnabled = model.result != nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        outline.strokeColor = (model.progress > 0 || model.stage == .complete ? NSColor.systemGreen : .systemOrange).cgColor
        guide.isHidden = model.stage == .left || model.stage == .right
        CATransaction.commit()
    }
    @objc private func retryCalibration() {
        expectedGeneration = restart(); started = ProcessInfo.processInfo.systemUptime
        model = GuidedCameraCalibration(); render()
    }
    @objc private func applyCalibration() {
        guard let result = model.result else { return }
        finished = true; timer?.invalidate(); complete(result); window.close()
    }
    @objc private func closeWindow() { window.close() }
    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        if !finished { finished = true; cancel() }
    }
}
