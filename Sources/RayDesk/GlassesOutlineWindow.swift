import AppKit
import RayDeskCore
import RayDeskLocalization
import simd

/// Окно ручной обводки очков: кадр камеры, сетка выученной формы и перо для контура.
///
/// Кадр рисуется тем же уменьшенным изображением, по которому считает трекер, поэтому контур
/// и точки формы ложатся ровно туда, где их видно. Обводка идёт в форму, пока включено обучение.
final class GlassesOutlineWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let content = FlippedView()
    private let view: GlassesOutlineView
    private let titleLabel = NSTextField(labelWithString: "")
    private let stepLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let freezeButton = NSButton(title: "", target: nil, action: nil)
    private let penButton = NSButton(title: "", target: nil, action: nil)
    private let undoButton = NSButton(title: "", target: nil, action: nil)
    private let applyButton = NSButton(title: "", target: nil, action: nil)
    private let clearButton = NSButton(title: "", target: nil, action: nil)
    private var contour: [CGPoint] = []
    private var drawn: [(point: CGPoint, glasses: Bool)] = []
    private var frozen: GlassesFrameContext?
    private var generation: Int?
    private var live = true
    private var pen = true
    private var currentGeneration = 0
    private var lastMessage = ""

    /// Как окно просит приложение применить обводку: возвращает число точек формы или `nil`.
    var applyOutline: (([SIMD2<Double>], GlassesFrameContext) -> Int?)?
    /// Как окно просит приложение отметить клетки под точками.
    var markCells: (([CGPoint], Bool, GlassesFrameContext) -> Int)?
    /// Как окно берёт кадр для рисования: `nil`, если обучение выключено, лица нет или камера перенастроена.
    var freezeFrame: ((Int) -> GlassesFrameContext?)?

    init(on screen: NSScreen?) {
        let size = NSSize(width: 1000, height: 760)
        let area = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: size)
        window = NSWindow(contentRect: NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2,
                                              width: size.width, height: size.height),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        view = GlassesOutlineView()
        super.init()
        window.title = t(.glassesOutlineTitle)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.minSize = NSSize(width: 800, height: 620)
        window.contentView = content
        view.frame = NSRect(x: 24, y: 158, width: size.width - 48, height: size.height - 158 - 168)
        view.autoresizingMask = [.width, .height]
        view.controller = self
        content.addSubview(view)
        titleLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        stepLabel.textColor = .secondaryLabelColor
        stepLabel.font = .systemFont(ofSize: 12, weight: .medium)
        messageLabel.font = .systemFont(ofSize: 12)
        messageLabel.textColor = .secondaryLabelColor
        statusLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        for (item, y, height) in [(titleLabel, 16.0, 26.0), (stepLabel, 44.0, 18.0), (statusLabel, 66.0, 18.0), (messageLabel, 88.0, 56.0)] {
            item.frame = NSRect(x: 24, y: y, width: size.width - 48, height: height)
            item.autoresizingMask = [.width]
            content.addSubview(item)
        }
        let buttons: [(NSButton, Selector, CGFloat, CGFloat)] = [
            (freezeButton, #selector(toggleFreeze), 0, 150), (penButton, #selector(togglePen), 162, 150),
            (undoButton, #selector(undoPoint), 324, 130), (applyButton, #selector(applyContour), 466, 160),
            (clearButton, #selector(clearContour), 638, 150),
        ]
        for (button, action, offset, width) in buttons {
            button.target = self
            button.action = action
            button.frame = NSRect(x: 24 + offset, y: 26, width: width, height: 32)
            button.autoresizingMask = []
            content.addSubview(button)
        }
        applyButton.keyEquivalent = "\r"
        applyLanguage()
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window.close() }

    func applyLanguage() {
        window.title = t(.glassesOutlineTitle)
        titleLabel.stringValue = t(.glassesOutlineTitle)
        stepLabel.stringValue = t(.glassesOutlineStep)
        freezeButton.title = t(live ? .glassesOutlineFreeze : .glassesOutlineResume)
        penButton.title = t(pen ? .glassesOutlinePenOn : .glassesOutlinePenOff)
        undoButton.title = t(.glassesOutlineUndo)
        applyButton.title = t(.glassesOutlineApply)
        clearButton.title = t(.glassesOutlineClear)
        messageLabel.stringValue = t(live ? .glassesOutlineHintLive : .glassesOutlineHintFrozen)
        lastMessage = messageLabel.stringValue
    }

    /// Кадр камеры: точки формы двигаются вместе с головой, пока кадр не заморожен.
    func update(_ observation: CameraObservation) {
        guard live, generation == nil || generation == observation.referenceGeneration else { return }
        currentGeneration = observation.referenceGeneration
        view.showLive(observation.frameImage)
        if view.apply(grid: observation.gridPoints, kept: observation.shapePoints) { view.needsDisplay = true }
        let message = observation.face == nil ? t(.glassesOutlineHintEmpty) : t(.glassesOutlineLegend)
        if message != lastMessage {
            lastMessage = message
            messageLabel.stringValue = message
        }
        statusLabel.stringValue = String(format: t(.glassesOutlineStatus), observation.learnedFrames, observation.shapePoints)
    }

    @objc private func togglePen() {
        pen = !pen
        view.setPen(pen)
        penButton.title = t(pen ? .glassesOutlinePenOn : .glassesOutlinePenOff)
    }

    @objc private func toggleFreeze() {
        if live {
            guard let context = freezeFrame?(currentGeneration) else {
                lastMessage = t(.glassesOutlineHintEmpty)
                messageLabel.stringValue = lastMessage
                return
            }
            frozen = context
            generation = context.generation
            live = false
            view.setFrozen(context)
        } else {
            live = true
            frozen = nil
            generation = nil
            view.setFrozen(nil)
        }
        contour = []
        drawn = []
        view.setContour(contour)
        view.setDrawn(drawn)
        view.setPen(pen)
        freezeButton.title = t(live ? .glassesOutlineFreeze : .glassesOutlineResume)
        lastMessage = t(live ? .glassesOutlineHintLive : .glassesOutlineHintFrozen)
        messageLabel.stringValue = lastMessage
    }

    @objc private func undoPoint() {
        guard !contour.isEmpty else { return }
        contour.removeLast()
        view.setContour(contour)
    }

    @objc private func applyContour() {
        guard contour.count >= 3, let context = frozen, let applyOutline else { return }
        let points = contour.map { SIMD2(Double($0.x), Double($0.y)) }
        guard let count = applyOutline(points, context) else { return }
        drawn.append(contentsOf: contour.map { ($0, true) })
        contour = []
        view.setContour(contour)
        view.setDrawn(drawn)
        lastMessage = String(format: t(.glassesOutlineHintApplied), count)
        messageLabel.stringValue = lastMessage
    }

    @objc private func clearContour() {
        contour = []
        drawn = []
        view.setContour(contour)
        view.setDrawn(drawn)
    }

    @MainActor fileprivate func clicked(at point: CGPoint, shift: Bool) {
        guard !live, let context = frozen else { return }
        if pen {
            contour.append(point)
            view.setContour(contour)
        } else {
            _ = markCells?([point], !shift, context)
            drawn.append((point, !shift))
            view.setDrawn(drawn)
        }
    }

    fileprivate func rightClicked() { undoPoint() }
}

/// Вид с перевёрнутыми координатами: рисование и мышь считают y сверху вниз, как на экране.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Кадр камеры с сеткой формы и пером: клик ставит точку контура или отмечает клетку.
private final class GlassesOutlineView: NSView {
    weak var controller: GlassesOutlineWindow?
    private var image: CGImage?
    private var grid: [CGPoint] = []
    private var kept: [CGPoint] = []
    private var contour: [CGPoint] = []
    private var drawn: [(point: CGPoint, glasses: Bool)] = []
    private var pen = true
    private var drawnAt: CGPoint?
    private var markedKeys: Set<Int> = []
    private var liveWidth: Int?
    private var liveFrame = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    func setPen(_ on: Bool) {
        pen = on
        needsDisplay = true
    }

    func showLive(_ frame: RGBAImage?) {
        guard let frame else { return }
        liveFrame += 1
        guard liveWidth != frame.width || liveFrame % 3 == 0, let fresh = Self.makeImage(frame) else { return }
        liveWidth = frame.width
        image = fresh
        needsDisplay = true
    }

    func setFrozen(_ context: GlassesFrameContext?) {
        image = context.flatMap { Self.makeImage($0.image) }
        liveWidth = nil
        grid = []
        kept = []
        markedKeys = []
        drawnAt = nil
        needsDisplay = true
    }

    func setContour(_ points: [CGPoint]) {
        contour = points
        needsDisplay = true
    }

    func setDrawn(_ points: [(point: CGPoint, glasses: Bool)]) {
        drawn = points
        needsDisplay = true
    }

    @discardableResult
    func apply(grid: [CGPoint], kept: [CGPoint]) -> Bool {
        var moved = drawnAt == nil
        if let previous = drawnAt, let next = grid.first {
            moved = hypot(next.x - previous.x, next.y - previous.y) > 0.001
        }
        guard moved || self.grid.count != grid.count else { return false }
        self.grid = grid
        self.kept = kept
        drawnAt = grid.first
        markedKeys = Set(kept.map { Self.key($0) })
        return true
    }

    static func makeImage(_ image: RGBAImage) -> CGImage? {
        var bytes = image.pixels
        let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        return bytes.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: bitmap)
            else { return nil }
            return context.makeImage()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let picture = contentRect()
        if let image {
            context.saveGState()
            context.interpolationQuality = .high
            context.draw(image, in: picture)
            context.restoreGState()
        }
        let cell = min(picture.width, picture.height) / 120
        drawCells(in: picture, cell: cell)
        if contour.count >= 2 {
            let path = NSBezierPath()
            path.lineWidth = 2
            path.move(to: viewPoint(contour[0], picture))
            for point in contour.dropFirst() { path.line(to: viewPoint(point, picture)) }
            NSColor.systemGreen.setStroke()
            path.stroke()
        }
        for point in contour { dot(viewPoint(point, picture), radius: 3.5, color: .systemGreen) }
        for entry in drawn { dot(viewPoint(entry.point, picture), radius: 3, color: entry.glasses ? .systemBlue : .systemOrange) }
    }

    private func drawCells(in picture: NSRect, cell: CGFloat) {
        guard !grid.isEmpty else { return }
        let half = max(cell * 0.3, 0.6)
        let bare = NSBezierPath()
        let marked = NSBezierPath()
        let touched = NSBezierPath()
        for point in grid {
            let at = viewPoint(point, picture)
            guard picture.insetBy(dx: -4, dy: -4).contains(at) else { continue }
            let path = markedKeys.contains(Self.key(point)) ? marked : bare
            path.move(to: CGPoint(x: at.x - half, y: at.y))
            path.line(to: CGPoint(x: at.x + half, y: at.y))
        }
        for entry in drawn {
            let at = viewPoint(entry.point, picture)
            let length = max(cell * 3, 6)
            touched.move(to: CGPoint(x: at.x - length, y: at.y))
            touched.line(to: CGPoint(x: at.x + length, y: at.y))
        }
        NSColor.systemTeal.withAlphaComponent(0.45).setStroke()
        bare.stroke()
        NSColor.systemTeal.withAlphaComponent(0.9).setStroke()
        marked.stroke()
        NSColor.systemBlue.withAlphaComponent(0.9).setStroke()
        touched.stroke()
    }

    private func dot(_ at: CGPoint, radius: CGFloat, color: NSColor) {
        let path = NSBezierPath(ovalIn: CGRect(x: at.x - radius, y: at.y - radius, width: radius * 2, height: radius * 2))
        color.setFill()
        path.fill()
    }

    private func viewPoint(_ point: CGPoint, _ picture: NSRect) -> CGPoint {
        CGPoint(x: picture.minX + point.x * picture.width, y: picture.minY + (1 - point.y) * picture.height)
    }

    private static func key(_ point: CGPoint) -> Int {
        Int((point.x * 1000).rounded()) &* 4096 &+ Int((point.y * 1000).rounded())
    }

    private func contentRect() -> NSRect {
        let width = CGFloat(image?.width ?? 320)
        let height = CGFloat(image?.height ?? 180)
        let fit = min(bounds.width / width, bounds.height / height)
        let size = CGSize(width: width * fit, height: height * fit)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    override func mouseDown(with event: NSEvent) {
        let at = convert(event.locationInWindow, from: nil)
        let picture = contentRect()
        guard picture.contains(at) else { return }
        let point = CGPoint(x: (at.x - picture.minX) / picture.width, y: 1 - (at.y - picture.minY) / picture.height)
        controller?.clicked(at: point, shift: event.modifierFlags.contains(.shift))
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        controller?.rightClicked()
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 {
            controller?.rightClicked()
            needsDisplay = true
        } else {
            super.keyDown(with: event)
        }
    }
}
