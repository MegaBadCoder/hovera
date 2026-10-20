import AppKit
import MetalKit
import Carbon.HIToolbox
import ApplicationServices
import QuartzCore
import AVFoundation
import simd
import RayDeskCore
import RayDeskLocalization

private let sceneDefaultsKey = "screens.v2"
private let languageDefaultsKey = "appLanguage"

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var scene = SpatialScene(screens: SpatialScene.decode(UserDefaults.standard.data(forKey: sceneDefaultsKey), default: 2, aspect: 16.0 / 9.0))
    private let filter = OrientationFilter()
    private let hotkeys = Hotkeys()
    private var imu: GlassesIMU?
    private var slots: [ScreenSlot] = []
    private var window: NSWindow?
    private var glassesView: MTKView?
    private var frameLink: CADisplayLink?
    private var frameLinkDisplay: CGDirectDisplayID?
    private var frameLinkSize: CGSize = .zero
    private var screenChangeWork: DispatchWorkItem?
    private var lastRenderedFrame = CACurrentMediaTime()
    private var renderStalled = false
    private var renderer: Renderer?
    private var isSelectingFocus = false
    private var isCalibrating = false
    private var statusTicks = 0
    private var compassFieldPrompted = false
    private var signalToken = 0
    private var lastCorrection: (time: CFTimeInterval, travel: RotationTravel)?
    private let recorder = GlassesRecorder()
    private var isCalibratingCompass = false
    private var statusItem: NSStatusItem?
    private var statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var statusText = ""
    private var statusTimer: Timer?
    private var mouseTapLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var mouseTapState = MouseTapState.checking
    private var mouseTap: MouseTap?
    private var accessibilityTimer: Timer?
    private var warpPolicy = CursorWarpPolicy()
    private var lastCursorHit: CursorHit?
    private var lastGazeHit: GazeHit?
    private var snapNeighbor: Int?
    private let meditationAudio = MeditationAudio()
    private var cameraDebugWindow: CameraDebugWindow?
    private static let debugObserver = "camera-debug-window"
    private static let outlineObserver = "glasses-outline-window"
    private var cameraCalibrationWindow: CameraCalibrationWindow?
    private var glassesOutlineWindow: GlassesOutlineWindow?
    private lazy var cameraHead = CameraHeadTracker(
        orientation: { [filter] uptime in (filter.orientation(atUptime: uptime), filter.isReady ? filter.angularSpeed : .infinity) }
    )
    private let glassesVision = GlassesVision()
    private let watchdog = MainThreadWatchdog()
    private var glassesTrackingItem: NSMenuItem?
    private var moveMode = false
    private var moveModeItem: NSMenuItem?
    private var macScreenOff = UserDefaults.standard.bool(forKey: "macScreenOff")
    private var macOffItem: NSMenuItem?
    private var macCurtain: NSWindow?
    private var primaryVirtualIndex: Int? = {
        guard let saved = UserDefaults.standard.object(forKey: "primaryVirtualIndex") as? Int, saved >= 0 else { return nil }
        return saved
    }()
    private var primaryItem: NSMenuItem?
    private var lastRawBias: SIMD3<Double>?

    private var wallModeItem: NSMenuItem?
    private var fovSlider: NSSlider?
    private var fovValueLabel: NSTextField?
    private var verticalFOVSave: DispatchWorkItem?
    private var learningGlasses = false

    private enum MouseTapState {
        case checking
        case needsAccessibility
        case running
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let other = runningInstanceOtherThanMe() {
            log("another RayDesk instance is already running (pid \(other.processIdentifier)), exiting")
            NSApp.terminate(nil)
            return
        }
        applyStoredLanguage()
        let info = Bundle.main.infoDictionary ?? [:]
        log("BUILD id=\(info["RayDeskBuildID"] ?? "development") commit=\(info["RayDeskCommit"] ?? "unknown") source=\(info["RayDeskSource"] ?? "unknown") executable=\(Bundle.main.executablePath ?? "unknown") tracking=glasses-coreml")
        UserDefaults.standard.register(defaults: ["restoreFirmwareZero": true])
        watchdog.start()
        setupMenu()
        setupHotkeys()
        setupMouseTap()

        waitForGlasses(attempt: 0)
    }

    /// Экран очков появляется не мгновенно: после подключения и после смены режима дисплея система
    /// перечисляет его с задержкой. Поэтому запуск ждёт экран, а не завершается с первого взгляда.
    private static let glassesWaitStep = 0.5
    private static let glassesWaitAttempts = 20

    private func waitForGlasses(attempt: Int) {
        if glassesScreen()?.displayID != nil {
            if attempt > 0 { log("glasses screen appeared after \(attempt) checks") }
            start()
            return
        }
        guard attempt < Self.glassesWaitAttempts else {
            fail(t(.alertGlassesMissing))
            NSApp.terminate(nil)
            return
        }
        if attempt == 0 {
            log("glasses screen missing: waiting up to \(Double(Self.glassesWaitAttempts) * Self.glassesWaitStep) s")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.glassesWaitStep) { [weak self] in
            self?.waitForGlasses(attempt: attempt + 1)
        }
    }

    /// Перечень экранов одной строкой: видно, на каком шаге запуска пропал экран очков.
    private func screensDescription() -> String {
        NSScreen.screens.map { screen in
            let id = screen.displayID.map(String.init) ?? "-"
            return "\(screen.localizedName)[\(id) \(Int(screen.frame.width))x\(Int(screen.frame.height))]"
        }.joined(separator: " · ")
    }

    private func start() {
        useLightGlassesMode()
        log("screens after light mode: \(screensDescription())")
        slots = scene.screens.indices.map { ScreenSlot(index: $0) }
        log("screens after virtual displays: \(screensDescription())")
        saveScene()
        arrangeDisplays()
        log("screens after arrange: \(screensDescription())")

        loadCompassCalibration()
        loadGyroScale()
        cameraHead.turnWorld = { [filter] angle in filter.rotateWorldYaw(by: angle) }
        if UserDefaults.standard.bool(forKey: "glassesTracking") {
            glassesVision.start()
            cameraHead.useGlasses(glassesVision)
        }
        let restoresFirmwareZero = UserDefaults.standard.bool(forKey: "restoreFirmwareZero")
        filter.restoresFirmwareZero = restoresFirmwareZero
        // Восстановитель начинает со сдвига ноль, поэтому выученный с ним ноль к новому запуску не подходит.
        if !restoresFirmwareZero { loadGyroBias() }
        imu = GlassesIMU(filter: filter)
        cameraHead.recordsFrames = UserDefaults.standard.bool(forKey: "recordIMU")
        if UserDefaults.standard.bool(forKey: "recordIMU") {
            imu?.recorder = IMURecorder()
        }
        imu?.start()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.noteScreenParametersChanged()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            openGlassesWindowWhenReady(attempt: 0)
        }

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStatus() }
    }

    /// Открывает окно панелей. Если экран очков пропал на время смены режима дисплея, попытка
    /// повторяется: одноразовая проверка здесь давала ложное «нет дисплея» и фатальное окно.
    private func openGlassesWindowWhenReady(attempt: Int) {
        do {
            try openGlassesWindow()
            if attempt > 0 { log("glasses window opened after \(attempt) retries") }
            applyMacScreenOff()
            startCaptures()
        } catch GlassesError.screenMissing {
            guard attempt < Self.glassesWaitAttempts else {
                fail(t(.alertGlassesMissing))
                NSApp.terminate(nil)
                return
            }
            if attempt == 0 {
                log("glasses screen vanished before the window: retrying")
                log("screens at retry: \(screensDescription())")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.glassesWaitStep) { [weak self] in
                self?.openGlassesWindowWhenReady(attempt: attempt + 1)
            }
        } catch {
            fail(String(format: t(.alertMetalFailed), "\(error)"))
            NSApp.terminate(nil)
        }
    }

    /// Другой уже запущенный экземпляр приложения, если он есть: каждый создаёт свои виртуальные
    /// экраны, вместе они отбирают место у очков, экран очков выпадает и панели пропадают.
    private func runningInstanceOtherThanMe() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    }

    /// Встроенный экран ноутбука: он остаётся экраном MacBook, даже если главным сделали панель.
    private func builtInDisplayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(max(count, 1)))
        CGGetOnlineDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Границы экрана MacBook в глобальных координатах.
    private var macBounds: CGRect {
        builtInDisplayID().map { CGDisplayBounds($0) } ?? CGDisplayBounds(CGMainDisplayID())
    }

    /// ⌃⌥⇧B: гасит экран MacBook чёрной шторкой и убирает его из целей курсора.
    @objc private func toggleMacScreenOff() {
        macScreenOff.toggle()
        UserDefaults.standard.set(macScreenOff, forKey: "macScreenOff")
        macOffItem?.state = macScreenOff ? .on : .off
        applyMacScreenOff()
        updatePointerTargets(head: head)
        warpPolicy.observeGaze(target: lastCursorHit?.target, at: CACurrentMediaTime())
        log("mac screen off: \(macScreenOff)")
    }

    private func applyMacScreenOff() {
        guard macScreenOff, let id = builtInDisplayID(),
              let screen = NSScreen.screens.first(where: { $0.displayID == id }) else {
            macCurtain?.orderOut(nil)
            macCurtain = nil
            return
        }
        if macCurtain == nil {
            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            window.setFrame(screen.frame, display: true)
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isOpaque = true
            window.ignoresMouseEvents = true
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            window.orderFrontRegardless()
            macCurtain = window
        } else {
            macCurtain?.setFrame(screen.frame, display: true)
        }
        moveCursorOffMac()
    }

    /// Уводит курсор с погашенного MacBook на панель под взглядом.
    private func moveCursorOffMac() {
        guard let event = CGEvent(source: nil), macBounds.contains(event.location) else { return }
        let index = screenUnderGaze()
        guard slots.indices.contains(index) else { return }
        let bounds = slots[index].displayBounds
        CGWarpMouseCursorPosition(CGPoint(x: bounds.midX, y: bounds.midY))
        mouseTap?.noteCursorMoved(to: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    private func glassesScreen() -> NSScreen? {
        NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("SmartGlasses") || $0.localizedName.localizedCaseInsensitiveContains("RayNeo") }
    }

    private func useLightGlassesMode() {
        guard let id = glassesScreen()?.displayID, let current = CGDisplayCopyDisplayMode(id) else { return }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []).filter {
            $0.width == 1920 && $0.height == 1080 && $0.pixelWidth == 1920 && $0.pixelHeight == 1080 && $0.isUsableForDesktopGUI()
        }
        guard let target = modes.min(by: { abs($0.refreshRate - 60) < abs($1.refreshRate - 60) }) else {
            log("glasses display: no plain 1920x1080 mode")
            return
        }
        guard current.pixelWidth != target.pixelWidth || current.pixelHeight != target.pixelHeight
                || abs(current.refreshRate - target.refreshRate) > 0.5 else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, id, target, nil)
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        log(String(format: "glasses display: %dx%d pixels @%.0f Hz -> %dx%d @%.0f Hz (%d)", current.pixelWidth, current.pixelHeight,
                   current.refreshRate, target.pixelWidth, target.pixelHeight, target.refreshRate, result.rawValue))
    }

    private func arrangeDisplays() {
        guard let glassesID = glassesScreen()?.displayID else { return }
        let mainBounds = macBounds
        let glassesBounds = CGDisplayBounds(glassesID)
        let sizes = slots.map(\.displayBounds.size)
        let result = RayDeskCore.arrangeDisplays(screenYaws: scene.screens.map(\.yaw), screenSizes: sizes, main: mainBounds, glasses: glassesBounds.size)
        var origins = zip(slots, result.screens).map { (display: $0.0.displayID, origin: $0.1) }
        origins.append((display: glassesID, origin: result.glasses))
        if let mac = builtInDisplayID() { origins.append((display: mac, origin: mainBounds.origin)) }
        // macOS считает главным дисплей, который занимает точку (0,0). Поэтому сдвигаем всю
        // раскладку так, чтобы в начале координат стоял выбранный экран, а без выбора — MacBook.
        let anchor = primaryVirtualIndex.flatMap { slots.indices.contains($0) ? result.screens[$0] : nil } ?? mainBounds.origin
        for index in origins.indices {
            origins[index].origin.x -= anchor.x
            origins[index].origin.y -= anchor.y
        }
        let current = origins.map { CGDisplayBounds($0.display).origin }
        let changed = zip(current, origins.map(\.origin)).filter { $0 != $1 }
        guard !changed.isEmpty else { return }
        for (was, now) in changed {
            log(String(format: "display origin %.0f,%.0f -> %.0f,%.0f", was.x, was.y, now.x, now.y))
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for target in origins {
            CGConfigureDisplayOrigin(config, target.display, Int32(target.origin.x), Int32(target.origin.y))
        }
        let status = CGCompleteDisplayConfiguration(config, .forAppOnly)
        log("arrange displays: \(status.rawValue), main now \(CGMainDisplayID())")
    }

    /// ⌃⌥⇧P: делает главным экран под взглядом — меню, Dock и новые окна уезжают в очки.
    /// Повторное нажатие возвращает главным MacBook.
    @objc private func togglePrimaryScreen() {
        if let current = primaryVirtualIndex, slots.indices.contains(current) {
            primaryVirtualIndex = nil
        } else {
            primaryVirtualIndex = screenUnderGaze()
        }
        UserDefaults.standard.set(primaryVirtualIndex ?? -1, forKey: "primaryVirtualIndex")
        primaryItem?.state = primaryVirtualIndex == nil ? .off : .on
        arrangeDisplays()
        applyMacScreenOff()
        log("primary screen: \(primaryVirtualIndex.map { "panel \($0 + 1)" } ?? "MacBook"), main now \(CGMainDisplayID())")
    }

    private func startCaptures() {
        if !CGPreflightScreenCaptureAccess() {
            log("screen capture: not granted, requesting")
            CGRequestScreenCaptureAccess()
            fail(t(.alertScreenRecording))
            return
        }
        for slot in slots { startCapture(slot) }
    }

    private func startCapture(_ slot: ScreenSlot) {
        Task { @MainActor in
            do {
                try await slot.start()
                log("capture started: screen \(slot.index + 1)")
            } catch {
                fail(String(format: t(.alertCaptureFailed), slot.index + 1, "\(error)"))
            }
        }
    }

    @objc private func renderFrame() {
        lastRenderedFrame = CACurrentMediaTime()
        glassesView?.draw()
    }

    func applicationWillTerminate(_ notification: Notification) {
        frameLink?.invalidate()
        if recorder.isRecording {
            let done = DispatchSemaphore(value: 0)
            Task.detached { [recorder] in
                do {
                    try await recorder.stop()
                } catch {
                    log("glasses recording stop on quit failed: \(error)")
                }
                done.signal()
            }
            _ = done.wait(timeout: .now() + 2)
        }
        saveScene()
        saveGyroBias()
        saveVerticalFOV()
        for slot in slots { slot.stop() }
        imu?.stop()
        accessibilityTimer?.invalidate()
        mouseTap?.stop()
    }

    private func openGlassesWindow() throws {
        guard let screen = glassesScreen() else { throw GlassesError.screenMissing }
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.setFrame(screen.frame, display: true)
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let view = MTKView(frame: NSRect(origin: .zero, size: screen.frame.size), device: MTLCreateSystemDefaultDevice())
        let renderer = try Renderer(view: view, scene: scene, filter: filter)
        renderer.showsGrid = UserDefaults.standard.bool(forKey: "showsGrid")
        renderer.showsScreenBorders = !UserDefaults.standard.bool(forKey: "hideScreenBorders")
        if let calibration = loadSetting(ViewCalibration.self, key: "viewCalibration", name: t(.settingGrid)) {
            renderer.calibration = calibration
        }
        renderer.verticalFOV = savedVerticalFOV()
        renderer.slots = slots
        renderer.stabilizer.level = savedStabilization()
        if let savedPrediction = UserDefaults.standard.object(forKey: "predictionMs") as? Double {
            renderer.headPipeline.predictionSeconds = savedPrediction / 1000
        }
        renderer.breathingEnabled = UserDefaults.standard.bool(forKey: "meditationBreathing")
        renderer.onFrame = { [weak self] head in
            guard let self else { return }
            updatePointerTargets(head: head)
            guard self.renderer?.meditation.isActive != true else { return }
            warpPolicy.observeGaze(target: lastCursorHit?.target, at: CACurrentMediaTime())
        }
        view.delegate = renderer
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        window.contentView = view
        glassesView = view
        window.orderFrontRegardless()
        self.window = window
        self.renderer = renderer
        restartFrameLink()
        if UserDefaults.standard.bool(forKey: "wallMode"), let wallModeItem {
            toggleWallMode(wallModeItem)
        }
        if glassesTracking, !UserDefaults.standard.bool(forKey: "guidedCalibrationIntroduced") {
            UserDefaults.standard.set(true, forKey: "guidedCalibrationIntroduced")
            Task { @MainActor [weak self] in self?.startCameraCalibration() }
        }
    }

    private func restartFrameLink() {
        guard let screen = glassesScreen() else { return }
        let now = CACurrentMediaTime()
        if let frameLinkDisplay, let frameLink, frameLinkDisplay == screen.displayID, frameLinkSize == screen.frame.size {
            frameLink.add(to: .main, forMode: .common)
            return
        }
        frameLink?.invalidate()
        let link = screen.displayLink(target: self, selector: #selector(renderFrame))
        link.add(to: .main, forMode: .common)
        frameLink = link
        frameLinkDisplay = screen.displayID
        frameLinkSize = screen.frame.size
        lastRenderedFrame = now
    }

    /// Пересобирает окно, дисплейную ссылку и режим панели после того, как система
    /// изменила параметры экранов.
    ///
    /// Работа отложена на следующий проход главного цикла: уведомление приходит посреди
    /// перестроения пространств (Mission Control, смена рабочего стола), и синхронная
    /// переконфигурация дисплеев растягивает главный поток на десятки миллисекунд.
    private func noteScreenParametersChanged() {
        screenChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.screenChangeWork = nil
            self?.screenParametersSettled()
        }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func screenParametersSettled() {
        let started = CACurrentMediaTime()
        useLightGlassesMode()
        fitWindowToGlasses()
        restartFrameLink()
        let elapsed = (CACurrentMediaTime() - started) * 1000
        if elapsed > 20 {
            log(String(format: "screen parameters settled in %.0f ms", elapsed))
        }
    }

    private func fitWindowToGlasses() {
        guard let window, let screen = glassesScreen(), window.frame != screen.frame else { return }
        window.setFrame(screen.frame, display: true)
    }

    private func watchRendering() {
        guard window != nil, glassesScreen() != nil else { return }
        let silent = CACurrentMediaTime() - lastRenderedFrame
        guard silent > 1 else {
            if renderStalled { log("render resumed") }
            renderStalled = false
            return
        }
        if !renderStalled { log(String(format: "render stalled for %.1f s, restarting the display link", silent)) }
        renderStalled = true
        fitWindowToGlasses()
        restartFrameLink()
    }

    enum GlassesError: Error { case screenMissing }

    private var head: simd_quatd { renderer?.currentHead ?? simd_quatd(ix: 0, iy: 0, iz: 0, r: 1) }

    private func targetScreen() -> Int {
        scene.focus?.screen ?? RayDeskCore.gazeHit(head: head, screens: scene.screens)?.screen ?? scene.screens.count - 1
    }

    private func saveScene() {
        setFocusSelection(false)
        UserDefaults.standard.set(scene.encoded(), forKey: sceneDefaultsKey)
    }

    private func updatePointerTargets(head: simd_quatd) {
        if let focus = scene.focus {
            lastGazeHit = focus.hit(head: head, origin: renderer?.currentHeadOffset ?? .zero)
            lastCursorHit = lastGazeHit.map { CursorHit(target: .virtual($0.screen), uv: $0.uv) }
        } else {
            lastGazeHit = RayDeskCore.gazeHit(head: head, screens: scene.screens)
            var hit = RayDeskCore.cursorHit(head: head, screens: scene.screens)
            if macScreenOff, hit?.target == .mac { hit = nil }
            lastCursorHit = hit
        }
    }

    private func setFocusSelection(_ active: Bool) {
        isSelectingFocus = active
        statusItem?.button?.image = NSImage(systemSymbolName: active ? "plus.magnifyingglass" : "eyeglasses", accessibilityDescription: "RayDesk")
        statusItem?.button?.toolTip = active ? t(.focusSelectionHint) : nil
    }

    @objc private func toggleFocusZoom() {
        scene.cancelSwap()
        if isSelectingFocus || scene.focus != nil {
            setFocusSelection(false)
            scene.endFocus()
            updatePointerTargets(head: head)
            NSSound(named: "Tink")?.play()
            return
        }
        guard renderer != nil, mouseTap != nil, mouseTap?.isDraggingScreen != true,
              renderer?.meditation.isActive != true else { NSSound.beep(); return }
        if let grabbed = scene.grabbed {
            scene.toggleGrab(grabbed, head: head)
            saveScene()
            arrangeDisplays()
        }
        setFocusSelection(true)
    }

    @objc private func swapScreensByGaze() {
        guard renderer != nil, mouseTap?.isDraggingScreen != true, !isSelectingFocus,
              scene.focus == nil, renderer?.meditation.isActive != true else { NSSound.beep(); return }
        guard let target = RayDeskCore.gazeHit(head: head, screens: scene.screens)?.screen else { return }
        if let grabbed = scene.grabbed {
            scene.toggleGrab(grabbed, head: head)
            saveScene()
            arrangeDisplays()
        }
        let source = scene.swapSource
        let point = CGEvent(source: nil)?.location
        let cursorScreen = point.flatMap { screenIndex(at: $0) }
        guard scene.selectSwapTarget(target) else {
            NSSound(named: "Tink")?.play()
            return
        }
        let cursorUV: SIMD2<Double>? = point.flatMap { point in
            guard let cursorScreen else { return nil }
            let rect = bounds(of: cursorScreen)
            guard rect.width > 0, rect.height > 0 else { return nil }
            return SIMD2(Double((point.x - rect.minX) / rect.width), Double((point.y - rect.minY) / rect.height))
        }
        saveScene()
        arrangeDisplays()
        if let cursorScreen, let cursorUV {
            let restored = globalPoint(uv: cursorUV, in: bounds(of: cursorScreen))
            CGWarpMouseCursorPosition(restored)
            mouseTap?.noteCursorMoved(to: restored)
        }
        updatePointerTargets(head: head)
        NSSound(named: "Tink")?.play()
        log("swapped screens \((source ?? target) + 1) and \(target + 1)")
    }

    /// ⌃⌥Space одним нажатием берёт экран под взглядом, а вторым ставит его туда, куда смотришь:
    /// сначала нацелились и взяли, потом перевели взгляд и нажали ещё раз.
    @objc private func placeHere() {
        if let held = scene.grabbed {
            scene.place(held, head: head)
            scene.toggleGrab(held, head: head)
            saveScene()
            arrangeDisplays()
            log("screen \(held + 1) placed by gaze")
            return
        }
        let index = screenUnderGaze()
        scene.grabCentered(index, head: head)
        saveScene()
        log("screen \(index + 1) picked and centered, waiting for the target")
    }

    /// Экран под взглядом: увеличенная панель, затем пересечение луча с экранами, затем ближайший по углу.
    private func screenUnderGaze() -> Int {
        if let focus = scene.focus { return focus.screen }
        if let hit = RayDeskCore.gazeHit(head: head, screens: scene.screens) { return hit.screen }
        let gaze = head.yawPitch
        return scene.screens.indices.min {
            angularGap(scene.screens[$0], gaze) < angularGap(scene.screens[$1], gaze)
        } ?? 0
    }

    private func angularGap(_ pose: ScreenPose, _ gaze: (yaw: Double, pitch: Double)) -> Double {
        hypot(atan2(sin(pose.yaw - gaze.yaw), cos(pose.yaw - gaze.yaw)), pose.pitch - gaze.pitch)
    }

    /// Режим перемещения: стрелки двигают выбранный экран по горизонтали и вертикали, а не только
    /// тянут его ближе и дальше.
    @objc private func toggleMoveMode() {
        moveMode.toggle()
        moveModeItem?.state = moveMode ? .on : .off
        log("move mode \(moveMode ? "on" : "off")")
    }

    private var nudgeStep: Double { 1 * .pi / 180 }

    private func nudgeTargetScreen(yaw: Double = 0, pitch: Double = 0) {
        let index = scene.grabbed ?? screenUnderGaze()
        scene.nudge(index, yaw: yaw, pitch: pitch)
        saveScene()
        log(String(format: "screen %d nudged %.0f° yaw, %.0f° pitch", index + 1, scene.screens[index].yaw * 180 / .pi,
                   scene.screens[index].pitch * 180 / .pi))
    }

    private func upArrow() {
        if isCalibrating { adjustCalibration(pitch: 0.5); return }
        if moveMode { nudgeTargetScreen(pitch: nudgeStep); return }
        closer()
    }

    private func downArrow() {
        if isCalibrating { adjustCalibration(pitch: -0.5); return }
        if moveMode { nudgeTargetScreen(pitch: -nudgeStep); return }
        farther()
    }

    private func leftArrow() {
        if isCalibrating { adjustCalibration(yaw: 1); return }
        if moveMode { nudgeTargetScreen(yaw: nudgeStep) }
    }

    private func rightArrow() {
        if isCalibrating { adjustCalibration(yaw: -1); return }
        if moveMode { nudgeTargetScreen(yaw: -nudgeStep) }
    }

    @objc private func toggleGrab() {
        if let grabbed = scene.grabbed {
            scene.toggleGrab(grabbed, head: head)
            saveScene()
            arrangeDisplays()
        } else {
            scene.toggleGrab(targetScreen(), head: head)
        }
    }

    @objc private func closer() {
        scene.adjustDistance(targetScreen(), by: 1 / 1.1)
        saveScene()
    }

    @objc private func farther() {
        scene.adjustDistance(targetScreen(), by: 1.1)
        saveScene()
    }

    @objc private func tiltBack() {
        tiltTargetScreen(by: tiltStep)
    }

    @objc private func tiltForward() {
        tiltTargetScreen(by: -tiltStep)
    }

    private func tiltTargetScreen(by angle: Double) {
        let index = targetScreen()
        scene.setPose(index, tilted(scene.screens[index], by: angle))
        saveScene()
        log(String(format: "screen %d tilt %.0f°", index, scene.screens[index].tilt * 180 / .pi))
    }

    private var tiltStep: Double { 5 * .pi / 180 }

    @objc private func bigger() {
        scene.adjustWidth(targetScreen(), by: 1.1)
        saveScene()
    }

    @objc private func smaller() {
        scene.adjustWidth(targetScreen(), by: 1 / 1.1)
        saveScene()
    }

    @objc private func recalibrate() {
        filter.reset()
    }

    @objc private func addScreen() {
        guard scene.addScreen(head: head) else {
            log("add screen: already at maximum")
            return
        }
        let slot = ScreenSlot(index: slots.count)
        slots.append(slot)
        startCapture(slot)
        renderer?.slots = slots
        saveScene()
        arrangeDisplays()
    }

    @objc private func removeScreen() {
        guard scene.removeLastScreen() else {
            log("remove screen: already at minimum")
            return
        }
        let slot = slots.removeLast()
        slot.stop()
        renderer?.slots = slots
        saveScene()
        arrangeDisplays()
    }

    @objc private func markReference() {
        let yp = head.yawPitch
        let now = CACurrentMediaTime()
        let since = lastCorrection.map { now - $0.time } ?? 0
        log(String(format: "MARK yaw %.1f° pitch %.1f° since %.0f s at %.4f",
                   -yp.yaw * 180 / .pi, yp.pitch * 180 / .pi, since, Date().timeIntervalSinceReferenceDate))
        NSSound(named: "Tink")?.play()
    }
    @objc private func toggleCalibration() {
        guard let renderer else { return }
        isCalibrating.toggle()
        renderer.showsGrid = isCalibrating || UserDefaults.standard.bool(forKey: "showsGrid")
        if !isCalibrating {
            saveCalibration()
        }
        log("calibration mode \(isCalibrating ? "on" : "off")")
    }

    private func logCorrection(kind: String, yawDegrees: Double) {
        let now = CACurrentMediaTime()
        let travel = filter.travel
        let previous = lastCorrection ?? (now, travel)
        log(String(format: "CORRECTION %@ yaw %.1f° since %.0f s travel %.0f° yawTravel %.0f° temp %.1f °C at %.4f",
                   kind, yawDegrees, now - previous.time,
                   (travel.total - previous.travel.total) * 180 / .pi,
                   (travel.yaw - previous.travel.yaw) * 180 / .pi,
                   imu?.temperature ?? 0, Date().timeIntervalSinceReferenceDate))
        lastCorrection = (now, travel)
    }

    /// Показывает событие в строке меню значком и подсказкой: голосовые объявления о компасе убраны.
    ///
    /// - Parameters:
    ///   - text: что сказать в подсказке значка.
    ///   - symbol: имя значка SF Symbols.
    ///   - seconds: сколько секунд показывать, затем вернётся обычный значок.
    private func signal(_ text: String, symbol: String, seconds: TimeInterval = 8) {
        log("signal: \(text)")
        signalToken &+= 1
        let token = signalToken
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: text)
        statusItem?.button?.toolTip = text
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.signalToken == token else { return }
            let active = self.isSelectingFocus
            self.statusItem?.button?.image = NSImage(systemSymbolName: active ? "plus.magnifyingglass" : "eyeglasses",
                                                     accessibilityDescription: "RayDesk")
            self.statusItem?.button?.toolTip = active ? t(.focusSelectionHint) : nil
        }
    }

    private func loadSetting<Value: Decodable>(_ type: Value.Type, key: String, name: String) -> Value? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            UserDefaults.standard.removeObject(forKey: key)
            log("\(key): stored value unreadable, reset: \(error)")
            signal(String(format: t(.settingReset), name), symbol: "gearshape", seconds: 6)
            return nil
        }
    }

    private func saveSetting<Value: Encodable>(_ value: Value, key: String) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            log("\(key): not saved: \(error)")
            signal(t(.settingNotSaved), symbol: "exclamationmark.triangle", seconds: 8)
        }
    }

    private func loadCompassCalibration() {
        guard UserDefaults.standard.bool(forKey: "compassEnabled") else {
            log("compass: off")
            return
        }
        guard let calibration = loadSetting(MagnetometerCalibration.self, key: "magCalibration.v1", name: t(.settingCompass)) else {
            log("compass: not calibrated")
            return
        }
        filter.magnetometerCalibration = calibration
        log("compass: calibration loaded")
    }

    private func loadGyroScale() {
        guard let values = UserDefaults.standard.array(forKey: "gyroScale.v1") as? [Double], values.count == 3 else { return }
        filter.gyroScale = SIMD3(values[0], values[1], values[2])
        log(String(format: "gyro scale loaded: %.4f %.4f %.4f", values[0], values[1], values[2]))
    }

    /// Ниже этой температуры калибровка масштаба не запускается: масштаб зависит от прогрева,
    /// а пользуются очками тёплыми. Холодная калибровка — источник устаревшей поправки.
    private static let gyroScaleMinTemperature = 32.0
    private var gyroScaleWarmupTimer: Timer?

    @objc private func calibrateGyroScale() {
        guard let imu else { return }
        if imu.temperature < Self.gyroScaleMinTemperature {
            signal(String(format: t(.signalGlassesCold), imu.temperature, Self.gyroScaleMinTemperature), symbol: "thermometer.snowflake", seconds: 10)
            log(String(format: "gyro scale calibration postponed: temperature %.1f C", imu.temperature))
            gyroScaleWarmupTimer?.invalidate()
            gyroScaleWarmupTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
                guard let self, let imu = self.imu else { timer.invalidate(); return }
                if imu.temperature >= Self.gyroScaleMinTemperature {
                    timer.invalidate()
                    self.gyroScaleWarmupTimer = nil
                    self.calibrateGyroScale()
                }
            }
            return
        }
        let box = GyroScaleBox()
        signal(String(format: t(.signalGyroScaleStart), imu.temperature), symbol: "gyroscope", seconds: 10)
        log("gyro scale calibration started")
        imu.sampleSink = { [weak self] sample in
            guard let (previous, current) = box.add(sample) else { return }
            DispatchQueue.main.async { self?.gyroScaleStageChanged(from: previous, to: current) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self, weak imu] in
            guard imu?.sampleSink != nil, box.isRunning else { return }
            imu?.sampleSink = nil
            self?.signal(t(.signalGyroScaleTimeout), symbol: "gyroscope", seconds: 10)
            log("gyro scale calibration timed out")
        }
    }

    private func gyroScaleStageChanged(from previous: GyroScaleCalibration.Stage, to stage: GyroScaleCalibration.Stage) {
        switch stage {
        case .readyToTurn:
            signal(t(.signalGyroZeroMeasured), symbol: "gyroscope", seconds: 6)
        case .turning:
            break
        case .finished(let scale, let measured):
            imu?.sampleSink = nil
            let updated = SIMD3(1, scale, 1)
            filter.gyroScale = updated
            UserDefaults.standard.set([updated.x, updated.y, updated.z], forKey: "gyroScale.v1")
            log(String(format: "gyro scale calibrated: measured %.1f° for 720°, scale %.4f, stored %.4f", measured, scale, updated.y))
            signal(String(format: t(.signalGyroScaleDone), imu?.temperature ?? 0, (1 / scale - 1) * 100), symbol: "gyroscope", seconds: 8)
        case .failed(.notUpright):
            imu?.sampleSink = nil
            signal(t(.signalGyroNotUpright), symbol: "exclamationmark.triangle", seconds: 10)
            log("gyro scale calibration failed: not upright")
        case .failed(.wrongTurnCount(let measured)):
            imu?.sampleSink = nil
            signal(t(.signalGyroWrongTurnCount), symbol: "exclamationmark.triangle", seconds: 10)
            log(String(format: "gyro scale calibration failed: measured %.1f°", measured))
        case .waitingForRest:
            break
        }
    }

    private func loadGyroBias() {
        guard let values = UserDefaults.standard.array(forKey: "gyroBias.v1") as? [Double], values.count == 3 else { return }
        filter.seedGyroBias(SIMD3(values[0], values[1], values[2]))
        log(String(format: "gyro bias seeded: %.3f %.3f %.3f °/s", values[0] * 180 / .pi, values[1] * 180 / .pi, values[2] * 180 / .pi))
    }

    private func saveGyroBias() {
        let bias = filter.gyroBias
        UserDefaults.standard.set([bias.x, bias.y, bias.z], forKey: "gyroBias.v1")
    }

    @objc private func toggleCompass(_ sender: NSMenuItem) {
        let enabled = !UserDefaults.standard.bool(forKey: "compassEnabled")
        UserDefaults.standard.set(enabled, forKey: "compassEnabled")
        sender.state = enabled ? .on : .off
        if enabled {
            loadCompassCalibration()
        } else {
            filter.magnetometerCalibration = nil
            log("compass: off")
        }
    }

    @objc private func calibrateCompass() {
        guard !isCalibratingCompass, let imu else { return }
        isCalibratingCompass = true
        imu.startCompassCalibration()
        signal(t(.signalCompassStart), symbol: "location.north.circle", seconds: 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.finishCompassCalibration() }
    }

    private func promptCompassRecalibrationIfFieldChanged() {
        guard filter.compassFieldChanged else {
            compassFieldPrompted = false
            return
        }
        guard !compassFieldPrompted, !isCalibratingCompass else { return }
        compassFieldPrompted = true
        log("compass: field around the glasses differs from calibration")
        signal(t(.signalCompassFieldChanged), symbol: "location.slash", seconds: 10)
    }

    private func finishCompassCalibration() {
        isCalibratingCompass = false
        guard let fitter = imu?.finishCompassCalibration() else { return }
        do {
            let calibration = try fitter.result()
            saveSetting(calibration, key: "magCalibration.v1")
            if UserDefaults.standard.bool(forKey: "compassEnabled") {
                filter.magnetometerCalibration = calibration
            }
            log(String(format: "compass calibrated: center %.1f %.1f %.1f radius %.2f dip %.1f° samples %d",
                       calibration.center.x, calibration.center.y, calibration.center.z,
                       calibration.radius, calibration.dip * 180 / .pi, fitter.sampleCount))
            signal(t(.signalCompassDone), symbol: "location.north.circle.fill", seconds: 6)
        } catch MagnetometerCalibrationError.tooFewSamples(let count) {
            log("compass calibration failed: too few samples \(count)")
            signal(t(.signalCompassTooFewSamples), symbol: "location.slash", seconds: 8)
        } catch MagnetometerCalibrationError.insufficientCoverage(let spread) {
            log(String(format: "compass calibration failed: coverage %.4f", spread))
            signal(t(.signalCompassTooFlat), symbol: "location.slash", seconds: 8)
        } catch MagnetometerCalibrationError.noisyField(let spread) {
            log(String(format: "compass calibration failed: field spread %.3f", spread))
            signal(t(.signalCompassNoisy), symbol: "location.slash", seconds: 8)
        } catch {
            fail(String(format: t(.alertCompassCalibrationFailed), "\(error)"))
        }
    }


    @objc private func warpCursorToGaze() {
        guard let hit = lastCursorHit else { return }
        let point = globalPoint(uv: hit.uv, in: bounds(of: hit.target))
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        mouseTap?.noteCursorMoved(to: point)
        log("cursor to gaze -> \(hit.target)")
    }

    @objc private func toggleRecording() {
        Task { @MainActor in
            do {
                if recorder.isRecording {
                    try await recorder.stop()
                    log("glasses recording saved: \(recorder.fileURL?.path ?? "")")
                } else {
                    guard let glassesID = glassesScreen()?.displayID else { return }
                    let url = try await recorder.start(displayID: glassesID)
                    log("glasses recording started: \(url.path)")
                }
            } catch {
                fail(String(format: t(.alertGlassesRecordingFailed), "\(error)"))
            }
        }
    }


    private func adjustCalibration(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) {
        guard isCalibrating, let renderer else { return }
        if yaw != 0 {
            logCorrection(kind: "arrow", yawDegrees: yaw)
        }
        renderer.calibration.yaw += yaw * .pi / 180
        renderer.calibration.pitch += pitch * .pi / 180
        renderer.calibration.roll += roll * .pi / 180
        saveCalibration()
        let c = renderer.calibration
        log(String(format: "calibration yaw %.1f° pitch %.1f° roll %.1f°", c.yaw * 180 / .pi, c.pitch * 180 / .pi, c.roll * 180 / .pi))
    }

    private func saveCalibration() {
        guard let renderer else { return }
        let mount = ViewCalibration(yaw: 0, pitch: renderer.calibration.pitch, roll: renderer.calibration.roll)
        saveSetting(mount, key: "viewCalibration")
    }

    /// Ставит «вперёд» туда, куда смотрю: без запомненной точки MacBook и без маркера.
    @objc private func recenterToGaze() {
        guard let renderer else { return }
        let yaw = filter.orientation(predictAhead: 0).yawPitch.yaw
        logCorrection(kind: "recenter", yawDegrees: -renderer.currentHead.yawPitch.yaw * 180 / .pi)
        filter.alignYawToZero()
        renderer.calibration.yaw = 0
        if renderer.headOffset != nil {
            cameraHead.worldYawChanged(by: -yaw)
            if glassesTracking { cameraHead.resetReference(after: 0.3) }
        }
    }

    @MainActor @objc private func startCameraCalibration() {
        if let window = cameraCalibrationWindow { window.show(); return }
        let wasGlassesTracking = glassesTracking
        let wasRunning = cameraHead.isRunning
        if !glassesTracking { setGlassesTracking(true) }
        let present = { @MainActor [weak self] in
            guard let self else { return }
            let screen = NSScreen.screens.first { $0.displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false }
            let generation = cameraHead.beginGuidedCalibration()
            let window = CameraCalibrationWindow(session: cameraHead.captureSession, on: screen, generation: generation,
                restart: { [weak self] in self?.cameraHead.beginGuidedCalibration() ?? 0 },
                complete: { [weak self] result in
                    guard let self else { return }
                    cameraHead.applyGuidedCalibration(result)
                    if let renderer, renderer.headOffset == nil { installCameraHeadOffset(renderer) }
                    UserDefaults.standard.set(true, forKey: "wallMode")
                    wallModeItem?.state = .on
                    cameraHead.observeCalibration(nil)
                    cameraCalibrationWindow = nil
                    signal(t(.signalCalibrationDone), symbol: "checkmark.circle", seconds: 6)
                }, cancel: { [weak self] in
                    self?.cameraHead.cancelGuidedCalibration()
                    self?.cameraHead.observeCalibration(nil)
                    self?.cameraCalibrationWindow = nil
                    if !wasGlassesTracking { self?.setGlassesTracking(false) }
                    if !wasRunning { self?.cameraHead.stop() }
                })
            cameraCalibrationWindow = window
            cameraHead.observeCalibration { [weak window] observation in window?.update(observation) }
            window.show()
        }
        if cameraHead.isRunning { present(); return }
        cameraHead.start { [weak self] error in
            guard error == nil else {
                if !wasGlassesTracking { self?.setGlassesTracking(false) }
                self?.signal(t(.signalCameraUnavailableSystem), symbol: "video.slash", seconds: 10)
                return
            }
            present()
        }
    }

    /// Открывает окно обводки очков: обведённый контур ложится в форму эталоном. Форму при этом
    /// не переучивают заново — обучение включает «Выучить форму очков» в том же меню.
    @MainActor @objc private func toggleGlassesOutline(_ sender: NSMenuItem) {
        if let window = glassesOutlineWindow, window.isVisible {
            sender.state = .off
            log("glasses outline window off")
            stopGlassesLearning()
            return
        }
        let open = { [weak self] in
            guard let self else { return }
            let display: CGDirectDisplayID? = slots.isEmpty ? nil : slots[targetScreen()].displayID
            let screen = NSScreen.screens.first { $0.displayID == display }
            let window = GlassesOutlineWindow(on: screen)
            window.freezeFrame = { [weak self] generation in self?.glassesVision.freeze(generation: generation) }
            window.applyOutline = { [weak self] contour, context in self?.glassesVision.applyOutline(contour, on: context) }
            window.markCells = { [weak self] points, adding, context in
                self?.glassesVision.markCells(at: points, adding: adding, on: context) ?? 0
            }
            glassesOutlineWindow = window
            cameraHead.addObserver(Self.outlineObserver) { [weak window] observation in window?.update(observation) }
            window.show()
            sender.state = .on
            log("glasses outline window on")
        }
        guard learningGlasses else {
            signal(t(.glassesOutlineNeedsLearning), symbol: "eyeglasses", seconds: 8)
            log("glasses outline window refused: learning is off")
            return
        }
        setGlassesTracking(true)
        let begin = { @MainActor [weak self] in
            guard let self else { return }
            glassesVision.start { open() }
        }
        if cameraHead.isRunning {
            begin()
            return
        }
        cameraHead.start { [weak self] error in
            if let error {
                log("camera head tracking failed: \(error)")
                sender.state = .off
                self?.signal(t(.signalCameraUnavailablePrivacy), symbol: "video.slash", seconds: 10)
                return
            }
            log("camera head tracking on")
            begin()
        }
    }

    /// Заканчивает обучение формы, сохраняет её и закрывает окно обводки: рисовать больше некуда.
    @MainActor private func stopGlassesLearning() {
        learningGlasses = false
        glassesOutlineWindow?.close()
        glassesOutlineWindow = nil
        cameraHead.removeObserver(Self.outlineObserver)
        Task { @MainActor [weak self] in
            guard let self else { return }
            let points = await glassesVision.stopLearning() ?? 0
            log("glasses shape learned: \(points) points")
            signal(points > 0 ? t(.signalGlassesShapeLearned) : t(.signalGlassesShapeFailed), symbol: "eyeglasses", seconds: 8)
        }
    }

    @objc private func toggleCameraDebug(_ sender: NSMenuItem) {
        if let window = cameraDebugWindow, window.isVisible {
            window.close()
            cameraHead.removeObserver(Self.debugObserver)
            sender.state = .off
            log("camera debug window off")
            return
        }
        let open = { [weak self] in
            guard let self else { return }
            let display: CGDirectDisplayID? = slots.isEmpty ? nil : slots[targetScreen()].displayID
            let screen = NSScreen.screens.first { $0.displayID == display }
            let window = CameraDebugWindow(session: cameraHead.captureSession, on: screen)
            cameraDebugWindow = window
            cameraHead.addObserver(Self.debugObserver) { [weak window] observation in window?.update(observation) }
            window.show()
            sender.state = .on
            log("camera debug window on")
        }
        if cameraHead.isRunning {
            open()
            return
        }
        cameraHead.start { [weak self] error in
            if let error {
                log("camera head tracking failed: \(error)")
                self?.signal(t(.signalCameraUnavailablePrivacy), symbol: "video.slash", seconds: 10)
                return
            }
            log("camera head tracking on")
            open()
        }
    }

    /// Дуга глаз при повороте головы: глаза ходят вокруг шеи и сдвигают камеру.
    private func eyeArcEnabled() -> Bool {
        UserDefaults.standard.object(forKey: "eyeArc") as? Bool ?? true
    }

    @objc private func toggleEyeArc(_ sender: NSMenuItem) {
        let enabled = !eyeArcEnabled()
        UserDefaults.standard.set(enabled, forKey: "eyeArc")
        sender.state = enabled ? .on : .off
        log("eye arc \(enabled)")
    }

    private var wallDepthStrength: Double {
        UserDefaults.standard.object(forKey: "wallDepthStrength") as? Double ?? (glassesTracking ? 1 : 0.25)
    }

    @objc private func chooseCameraFieldOfView(_ sender: NSMenuItem) {
        guard let degrees = sender.representedObject as? Int else { return }
        UserDefaults.standard.set(Double(degrees), forKey: "cameraFieldOfView")
        sender.menu?.items.forEach { $0.state = ($0.representedObject as? Int) == degrees ? .on : .off }
        cameraHead.resetReference(after: 1, geometryChanged: true)
        signal(t(.signalCameraAngleChanged), symbol: "camera", seconds: 6)
        log("camera field of view \(degrees)°")
    }

    @objc private func chooseWallDepth(_ sender: NSMenuItem) {
        guard let percent = sender.representedObject as? Int else { return }
        UserDefaults.standard.set(Double(percent) / 100, forKey: "wallDepthStrength")
        sender.menu?.items.forEach { $0.state = ($0.representedObject as? Int) == percent ? .on : .off }
        log("wall depth strength \(percent)%")
    }

    private func installCameraHeadOffset(_ renderer: Renderer) {
        var referenceHead: simd_quatd?
        var generation = -1
        var lastOffset = SIMD3<Double>.zero
        renderer.headOffset = { [cameraHead, weak self] head in
            if cameraHead.cameraIsMoving { return lastOffset }
            if cameraHead.referenceGeneration != generation {
                generation = cameraHead.referenceGeneration
                referenceHead = head
            }
            var offset = cameraHead.neckOffset()
            offset.z *= self?.wallDepthStrength ?? 0.25
            let neck = worldOffset(fromCamera: offset, cameraYaw: cameraHead.cameraYaw ?? 0)
            let arc = self?.eyeArcEnabled() == true ? referenceHead.map { eyeArcOffset(head: head, reference: $0) } ?? .zero : .zero
            lastOffset = neck + arc
            return lastOffset
        }
    }

    @objc private func toggleWallMode(_ sender: NSMenuItem) {
        guard let renderer else { return }
        if renderer.headOffset != nil {
            renderer.headOffset = nil
            sender.state = .off
            UserDefaults.standard.set(false, forKey: "wallMode")
            log("wall mode off")
            return
        }
        UserDefaults.standard.set(true, forKey: "wallMode")
        let enable = { [weak self] in
            guard let self, let renderer = self.renderer else { return }
            cameraHead.resetReference(after: 0.3)
            installCameraHeadOffset(renderer)
            sender.state = .on
            signal(glassesTracking ? t(.signalWallModeGlasses) : t(.signalWallModeFace), symbol: "rectangle.on.rectangle", seconds: 6)
            log("wall mode on")
        }
        if cameraHead.isRunning {
            enable()
            return
        }
        cameraHead.start { [weak self] error in
            if let error {
                log("camera head tracking failed: \(error)")
                self?.signal(t(.signalCameraUnavailablePrivacy), symbol: "video.slash", seconds: 10)
                return
            }
            log("camera head tracking on")
            enable()
        }
    }

    @MainActor @objc private func toggleGlassesTracking(_ sender: NSMenuItem) {
        setGlassesTracking(sender.state != .on)
    }

    private var glassesTracking: Bool { UserDefaults.standard.bool(forKey: "glassesTracking") }

    @MainActor private func setGlassesTracking(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "glassesTracking")
        glassesTrackingItem?.state = enabled ? .on : .off
        if enabled { glassesVision.start() }
        cameraHead.useGlasses(enabled ? glassesVision : nil)
        if renderer?.headOffset != nil { cameraHead.resetReference(after: 1) }
        log("glasses tracking \(enabled ? "on" : "off")")
    }

    @MainActor @objc private func toggleGlassesLearning(_ sender: NSMenuItem) {
        if learningGlasses {
            sender.state = .off
            stopGlassesLearning()
            return
        }
        setGlassesTracking(true)
        learningGlasses = true
        sender.state = .on
        let begin = { @MainActor [weak self] in
            guard let self else { return }
            glassesVision.start {
                Task { @MainActor [weak self] in
                    guard let self, learningGlasses else { return }
                    await glassesVision.startLearning()
                    signal(t(.signalGlassesLearning), symbol: "camera", seconds: 12)
                }
            }
        }
        if cameraHead.isRunning {
            begin()
            return
        }
        cameraHead.start { [weak self] error in
            if let error {
                log("camera head tracking failed: \(error)")
                self?.learningGlasses = false
                sender.state = .off
                self?.signal(t(.signalCameraUnavailablePrivacy), symbol: "video.slash", seconds: 10)
                return
            }
            log("camera head tracking on")
            begin()
        }
    }

    @objc private func toggleFirmwareZeroRestore(_ sender: NSMenuItem) {
        let enabled = sender.state != .on
        UserDefaults.standard.set(enabled, forKey: "restoreFirmwareZero")
        filter.restoresFirmwareZero = enabled
        filter.trustNextStillness()
        sender.state = enabled ? .on : .off
        log("firmware zero restore \(enabled ? "on" : "off")")
    }

    private func logCameraHead() {
        guard cameraHead.isRunning else { return }
        let reading = cameraHead.takeReading()
        if let glasses = reading.glassesPerSecond {
            log(String(format: t(.cameraLogGlasses),
                       glasses, reading.framesPerSecond, reading.facesPerSecond, (reading.glassesScore ?? .nan) * 100,
                       (reading.headingDrift ?? .nan) * 180 / .pi, reading.headingCorrection * 180 / .pi,
                       reading.headingRate * 180 / .pi, reading.faceYawScale, reading.headingAge))
        }
        guard let position = reading.position else {
            log(String(format: t(.cameraLogNoFace), reading.framesPerSecond))
            return
        }
        let jitter = (reading.jitter ?? .zero) * 1000
        let neck = cameraHead.neckOffset() * 100
        log(String(format: t(.cameraLogNeck), neck.x, neck.y, neck.z,
                                              (reading.latency ?? .nan) * 1000, renderer?.headOffset != nil ? t(.cameraDebugCalibrated) : ""))
        log(String(format: t(.cameraLogHead),
                           position.x * 100, position.y * 100, position.z * 100, jitter.x, jitter.y, jitter.z,
                           reading.framesPerSecond, reading.facesPerSecond))
    }

    @objc private func moveWindowToGaze() {
        guard let target = lastCursorHit?.target else {
            signal(t(.signalWindowTarget), symbol: "rectangle.on.rectangle", seconds: 6)
            return
        }
        let display: CGDirectDisplayID
        switch target {
        case .virtual(let index): display = slots[index].displayID
        case .mac: display = builtInDisplayID() ?? CGMainDisplayID()
        }
        do {
            let moved = try WindowMover.moveFrontWindow(to: display)
            log(String(format: "window of %@ moved to %@ at %.0f,%.0f %.0f×%.0f", moved.app, String(describing: target),
                       moved.frame.minX, moved.frame.minY, moved.frame.width, moved.frame.height))
        } catch WindowMoveError.noAccessibility {
            signal(t(.signalWindowNoAccessibility), symbol: "rectangle.on.rectangle.slash", seconds: 10)
        } catch WindowMoveError.noFrontWindow {
            log("window move: no front window")
            signal(t(.signalWindowNoFrontWindow), symbol: "rectangle.on.rectangle.slash", seconds: 10)
        } catch {
            log("window move failed: \(error)")
            signal(t(.signalWindowNotMovable), symbol: "rectangle.on.rectangle.slash", seconds: 10)
        }
    }

    @objc private func arrangeInArc() {
        guard let renderer else { return }
        scene.arrangeInArc(head: renderer.currentHead, join: savedJoin())
        saveScene()
        arrangeDisplays()
        log("screens arranged in an arc")
    }

    private func savedJoin() -> ScreenJoin {
        UserDefaults.standard.string(forKey: "screenJoin").flatMap(ScreenJoin.init(rawValue:)) ?? .hinge
    }

    @objc private func chooseJoin(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, ScreenJoin(rawValue: raw) != nil else { return }
        UserDefaults.standard.set(raw, forKey: "screenJoin")
        sender.menu?.items.forEach { $0.state = ($0.representedObject as? String) == raw ? .on : .off }
        log("screen join \(raw)")
    }

    private func joinMenu() -> NSMenuItem {
        let item = NSMenuItem(title: t(.menuJoin), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (join, title) in [(ScreenJoin.hinge, t(.menuJoinHinge)),
                              (.gaze, t(.menuJoinGaze))] {
            let option = menuItem(title, #selector(chooseJoin(_:)))
            option.representedObject = join.rawValue
            option.state = join == savedJoin() ? .on : .off
            submenu.addItem(option)
        }
        item.submenu = submenu
        return item
    }

    @objc private func turnLeft() {
        turnTargetScreen(by: turnStep)
    }

    @objc private func turnRight() {
        turnTargetScreen(by: -turnStep)
    }

    private func turnTargetScreen(by angle: Double) {
        let index = targetScreen()
        scene.turn(index, by: angle)
        saveScene()
        log(String(format: "screen %d pan %.0f°", index + 1, scene.screens[index].pan * 180 / .pi))
    }

    private var turnStep: Double { 2 * .pi / 180 }

    @objc private func tiltAllBack() {
        scene.tiltAll(by: tiltStep)
        saveScene()
    }

    @objc private func tiltAllForward() {
        scene.tiltAll(by: -tiltStep)
        saveScene()
    }

    @objc private func gatherScreens() {
        guard let renderer else { return }
        scene.gatherInFront(head: renderer.currentHead)
        saveScene()
        arrangeDisplays()
    }
    private func meditationMenu() -> NSMenuItem {
        let item = NSMenuItem(title: t(.menuMeditation), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(menuItem(t(.menuMeditationToggle), #selector(toggleMeditation)))
        let breathing = menuItem(t(.menuBreathing), #selector(toggleBreathing(_:)))
        breathing.state = UserDefaults.standard.bool(forKey: "meditationBreathing") ? .on : .off
        submenu.addItem(breathing)
        submenu.addItem(.separator())
        submenu.addItem(NSMenuItem(title: t(.menuNeuralEffect), action: nil, keyEquivalent: ""))
        let saved = savedNeuralEffect()
        meditationAudio.neuralEffect = saved
        for (effect, title) in [(NeuralEffect.off, t(.menuNeuralEffectOff)), (.low, t(.menuNeuralEffectLow)),
                                (.medium, t(.menuNeuralEffectMedium)), (.high, t(.menuNeuralEffectHigh))] {
            let option = menuItem("   " + title, #selector(chooseNeuralEffect(_:)))
            option.representedObject = effect.rawValue
            option.state = effect == saved ? .on : .off
            submenu.addItem(option)
        }
        item.submenu = submenu
        return item
    }

    private func savedNeuralEffect() -> NeuralEffect {
        UserDefaults.standard.string(forKey: "meditationNeuralEffect").flatMap(NeuralEffect.init(rawValue:)) ?? .low
    }

    @objc private func toggleMeditation() {
        guard let renderer else { return }
        setFocusSelection(false)
        scene.endFocus()
        scene.cancelSwap()
        renderer.toggleMeditation()
        if renderer.meditation.isActive {
            do {
                try meditationAudio.start()
            } catch {
                log("meditation audio failed: \(error)")
                signal(t(.signalMeditationAudioFailed), symbol: "speaker.slash", seconds: 10)
            }
        } else {
            meditationAudio.stop()
        }
        log("meditation \(renderer.meditation.isActive ? "on" : "off")")
    }

    @objc private func toggleBreathing(_ sender: NSMenuItem) {
        let enabled = !UserDefaults.standard.bool(forKey: "meditationBreathing")
        UserDefaults.standard.set(enabled, forKey: "meditationBreathing")
        renderer?.breathingEnabled = enabled
        sender.state = enabled ? .on : .off
        log("meditation breathing \(enabled ? "on" : "off")")
    }

    @objc private func chooseNeuralEffect(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let effect = NeuralEffect(rawValue: raw) else { return }
        UserDefaults.standard.set(effect.rawValue, forKey: "meditationNeuralEffect")
        meditationAudio.neuralEffect = effect
        sender.menu?.items.forEach { item in
            guard let value = item.representedObject as? String else { return }
            item.state = value == raw ? .on : .off
        }
        log("meditation neural effect \(raw)")
    }

    private func savedStabilization() -> StabilizationLevel {
        UserDefaults.standard.string(forKey: "stabilization").flatMap(StabilizationLevel.init(rawValue:)) ?? .off
    }

    @objc private func chooseStabilization(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let level = StabilizationLevel(rawValue: raw) else { return }
        UserDefaults.standard.set(level.rawValue, forKey: "stabilization")
        renderer?.stabilizer.level = level
        sender.menu?.items.forEach { $0.state = ($0.representedObject as? String) == raw ? .on : .off }
        log("stabilization \(raw)")
    }

    @objc private func toggleGrid() {
        guard let renderer else { return }
        renderer.showsGrid.toggle()
        UserDefaults.standard.set(renderer.showsGrid, forKey: "showsGrid")
        log("grid \(renderer.showsGrid ? "on" : "off")")
    }
    @objc private func toggleScreenBorders(_ sender: NSMenuItem) {
        guard let renderer else { return }
        renderer.showsScreenBorders.toggle()
        UserDefaults.standard.set(!renderer.showsScreenBorders, forKey: "hideScreenBorders")
        sender.state = renderer.showsScreenBorders ? .on : .off
        log("screen borders \(renderer.showsScreenBorders ? "on" : "off")")
    }
    @objc private func morePrediction() { changePrediction(by: 5) }
    @objc private func lessPrediction() { changePrediction(by: -5) }
    private func changePrediction(by milliseconds: Double) {
        guard let renderer else { return }
        let value = min(80, max(0, renderer.headPipeline.predictionSeconds * 1000 + milliseconds))
        renderer.headPipeline.predictionSeconds = value / 1000
        UserDefaults.standard.set(value, forKey: "predictionMs")
        log(String(format: "prediction %.0f ms", value))
    }
    @objc private func widerFOV() { changeFOV(by: 0.5) }
    @objc private func narrowerFOV() { changeFOV(by: -0.5) }
    @objc private func fovSliderChanged(_ sender: NSSlider) {
        applyVerticalFOV(sender.doubleValue)
        scheduleVerticalFOVSave()
    }
    private func changeFOV(by delta: Double) {
        guard let renderer else { return }
        applyVerticalFOV(renderer.verticalFOV + delta)
        saveVerticalFOV()
        log(String(format: "vertical FOV %.1f°", renderer.verticalFOV))
    }
    private func applyVerticalFOV(_ value: Double) {
        guard let renderer else { return }
        renderer.verticalFOV = min(Renderer.verticalFOVRange.upperBound, max(Renderer.verticalFOVRange.lowerBound, value))
        showVerticalFOV(renderer.verticalFOV)
    }
    private func scheduleVerticalFOVSave() {
        verticalFOVSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveVerticalFOV() }
        verticalFOVSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    private func saveVerticalFOV() {
        guard let renderer else { return }
        UserDefaults.standard.set(renderer.verticalFOV, forKey: "verticalFOV")
    }
    private func savedVerticalFOV() -> Double {
        UserDefaults.standard.object(forKey: "verticalFOV") as? Double ?? Renderer.defaultVerticalFOV
    }
    private func showVerticalFOV(_ value: Double) {
        fovSlider?.doubleValue = value
        fovValueLabel?.stringValue = String(format: "%.1f°", value)
    }
    @objc private func toggleWindow() {
        guard let window else { return }
        window.isVisible ? window.orderOut(nil) : window.orderFrontRegardless()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func setupHotkeys() {
        hotkeys.register(keyCode: kVK_Space) { [weak self] in self?.placeHere() }
        hotkeys.register(keyCode: kVK_ANSI_G) { [weak self] in self?.toggleGrab() }
        hotkeys.register(keyCode: kVK_UpArrow) { [weak self] in self?.upArrow() }
        hotkeys.register(keyCode: kVK_DownArrow) { [weak self] in self?.downArrow() }
        hotkeys.register(keyCode: kVK_UpArrow, modifiers: controlKey | optionKey | shiftKey) { [weak self] in
            guard let self else { return }
            moveMode ? closer() : tiltBack()
        }
        hotkeys.register(keyCode: kVK_DownArrow, modifiers: controlKey | optionKey | shiftKey) { [weak self] in
            guard let self else { return }
            moveMode ? farther() : tiltForward()
        }
        hotkeys.register(keyCode: kVK_LeftArrow, modifiers: controlKey | optionKey | shiftKey) { [weak self] in self?.turnLeft() }
        hotkeys.register(keyCode: kVK_RightArrow, modifiers: controlKey | optionKey | shiftKey) { [weak self] in self?.turnRight() }
        hotkeys.register(keyCode: kVK_UpArrow, modifiers: controlKey | optionKey | cmdKey) { [weak self] in self?.tiltAllBack() }
        hotkeys.register(keyCode: kVK_DownArrow, modifiers: controlKey | optionKey | cmdKey) { [weak self] in self?.tiltAllForward() }
        hotkeys.register(keyCode: kVK_LeftArrow) { [weak self] in self?.leftArrow() }
        hotkeys.register(keyCode: kVK_RightArrow) { [weak self] in self?.rightArrow() }
        hotkeys.register(keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey | shiftKey) { [weak self] in self?.toggleMoveMode() }
        hotkeys.register(keyCode: kVK_ANSI_B, modifiers: controlKey | optionKey | shiftKey) { [weak self] in self?.toggleMacScreenOff() }
        hotkeys.register(keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey | shiftKey) { [weak self] in self?.togglePrimaryScreen() }
        hotkeys.register(keyCode: kVK_ANSI_Comma) { [weak self] in self?.adjustCalibration(roll: 0.5) }
        hotkeys.register(keyCode: kVK_ANSI_Period) { [weak self] in self?.adjustCalibration(roll: -0.5) }
        hotkeys.register(keyCode: kVK_ANSI_C) { [weak self] in self?.toggleCalibration() }
        hotkeys.register(keyCode: kVK_ANSI_Equal) { [weak self] in self?.bigger() }
        hotkeys.register(keyCode: kVK_ANSI_Minus) { [weak self] in self?.smaller() }
        hotkeys.register(keyCode: kVK_ANSI_H) { [weak self] in self?.toggleWindow() }
        hotkeys.register(keyCode: kVK_ANSI_Q) { [weak self] in self?.quit() }
        hotkeys.register(keyCode: kVK_ANSI_D) { [weak self] in self?.toggleGrid() }
        hotkeys.register(keyCode: kVK_ANSI_9) { [weak self] in self?.lessPrediction() }
        hotkeys.register(keyCode: kVK_ANSI_0) { [weak self] in self?.morePrediction() }
        hotkeys.register(keyCode: kVK_ANSI_M) { [weak self] in self?.markReference() }
        hotkeys.register(keyCode: kVK_ANSI_R) { [weak self] in self?.recenterToGaze() }
        hotkeys.register(keyCode: kVK_ANSI_V) { [weak self] in self?.toggleRecording() }
        hotkeys.register(keyCode: kVK_ANSI_K, modifiers: controlKey | optionKey | shiftKey) { [weak self] in
            Task { @MainActor [weak self] in self?.startCameraCalibration() }
        }
        hotkeys.register(keyCode: kVK_ANSI_K) { [weak self] in self?.calibrateCompass() }
        hotkeys.register(keyCode: kVK_ANSI_J) { [weak self] in self?.warpCursorToGaze() }
        hotkeys.register(keyCode: kVK_ANSI_RightBracket) { [weak self] in self?.widerFOV() }
        hotkeys.register(keyCode: kVK_ANSI_LeftBracket) { [weak self] in self?.narrowerFOV() }
        hotkeys.register(keyCode: kVK_ANSI_Z) { [weak self] in self?.toggleFocusZoom() }
        hotkeys.register(keyCode: kVK_ANSI_Z, modifiers: controlKey | optionKey | shiftKey) { [weak self] in self?.toggleMeditation() }
        hotkeys.register(keyCode: kVK_ANSI_S) { [weak self] in self?.swapScreensByGaze() }
        hotkeys.register(keyCode: kVK_ANSI_A) { [weak self] in self?.arrangeInArc() }
        hotkeys.register(keyCode: kVK_ANSI_G, modifiers: controlKey | optionKey | shiftKey) { [weak self] in self?.gatherScreens() }
        hotkeys.register(keyCode: kVK_ANSI_W) { [weak self] in self?.moveWindowToGaze() }
    }

    private func setupMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "RayDesk")
        item.menu = buildMenu()
        statusItem = item
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        statusLine.title = statusText.isEmpty ? t(.statusStarting) : statusText
        refreshMouseTapLine()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(submenu(t(.menuScreens)) { screens in
            screens.addItem(menuItem(t(.menuPlaceHere), #selector(placeHere)))
            screens.addItem(menuItem(t(.menuGrab), #selector(toggleGrab)))
            let macOff = menuItem(t(.menuMacScreenOff), #selector(toggleMacScreenOff))
            macOff.state = macScreenOff ? .on : .off
            macOffItem = macOff
            screens.addItem(macOff)
            let primary = menuItem(t(.menuPrimaryScreen), #selector(togglePrimaryScreen))
            primary.state = primaryVirtualIndex == nil ? .off : .on
            primaryItem = primary
            screens.addItem(primary)
            let moveItem = menuItem(t(.menuMoveMode), #selector(toggleMoveMode))
            moveItem.state = moveMode ? .on : .off
            moveModeItem = moveItem
            screens.addItem(moveItem)
            screens.addItem(menuItem(t(.menuFocusZoom), #selector(toggleFocusZoom)))
            screens.addItem(menuItem(t(.menuSwapScreen), #selector(swapScreensByGaze)))
            screens.addItem(.separator())
            screens.addItem(menuItem(t(.menuCloser), #selector(closer)))
            screens.addItem(menuItem(t(.menuFarther), #selector(farther)))
            screens.addItem(menuItem(t(.menuBigger), #selector(bigger)))
            screens.addItem(menuItem(t(.menuSmaller), #selector(smaller)))
            screens.addItem(menuItem(t(.menuTiltBack), #selector(tiltBack)))
            screens.addItem(menuItem(t(.menuTiltForward), #selector(tiltForward)))
            screens.addItem(menuItem(t(.menuTurnLeft), #selector(turnLeft)))
            screens.addItem(menuItem(t(.menuTurnRight), #selector(turnRight)))
            screens.addItem(menuItem(t(.menuTiltAllBack), #selector(tiltAllBack)))
            screens.addItem(menuItem(t(.menuTiltAllForward), #selector(tiltAllForward)))
            screens.addItem(.separator())
            screens.addItem(menuItem(t(.menuGatherScreens), #selector(gatherScreens)))
            screens.addItem(menuItem(t(.menuArrangeInArc), #selector(arrangeInArc)))
            screens.addItem(joinMenu())
            screens.addItem(.separator())
            screens.addItem(menuItem(t(.menuAddScreen), #selector(addScreen)))
            screens.addItem(menuItem(t(.menuRemoveScreen), #selector(removeScreen)))
            screens.addItem(.separator())
            screens.addItem(menuItem(t(.menuCursorToGaze), #selector(warpCursorToGaze)))
            screens.addItem(menuItem(t(.menuWindowToGaze), #selector(moveWindowToGaze)))
        })
        menu.addItem(submenu(t(.menuCentreHeading)) { center in
            center.addItem(menuItem(t(.menuRecentreWorld), #selector(recenterToGaze)))
            center.addItem(menuItem(t(.menuMarkReference), #selector(markReference)))
            center.addItem(.separator())
            let compassItem = menuItem(t(.menuCompass), #selector(toggleCompass(_:)))
            compassItem.state = UserDefaults.standard.bool(forKey: "compassEnabled") ? .on : .off
            center.addItem(compassItem)
            center.addItem(menuItem(t(.menuCalibrateCompass), #selector(calibrateCompass)))
            center.addItem(menuItem(t(.menuCalibrateGyroScale), #selector(calibrateGyroScale)))
            center.addItem(menuItem(t(.menuRecalibrateGyro), #selector(recalibrate)))
        })
        menu.addItem(submenu(t(.menuCamera)) { camera in
            let glassesItem = menuItem(t(.menuGlassesTracking), #selector(toggleGlassesTracking(_:)))
            glassesItem.state = UserDefaults.standard.bool(forKey: "glassesTracking") ? .on : .off
            glassesTrackingItem = glassesItem
            camera.addItem(glassesItem)
            let wallItem = menuItem(t(.menuWallMode), #selector(toggleWallMode(_:)))
            wallItem.state = renderer?.headOffset != nil ? .on : .off
            wallModeItem = wallItem
            camera.addItem(wallItem)
            camera.addItem(menuItem(t(.menuCameraCalibration), #selector(startCameraCalibration)))
            let learnItem = menuItem(t(.menuLearnGlassesShape), #selector(toggleGlassesLearning(_:)))
            learnItem.state = learningGlasses ? .on : .off
            camera.addItem(learnItem)
            let outlineItem = menuItem(t(.menuGlassesOutline), #selector(toggleGlassesOutline(_:)))
            outlineItem.state = glassesOutlineWindow?.isVisible == true ? .on : .off
            camera.addItem(outlineItem)
            let zeroItem = menuItem(t(.menuFirmwareZeroRestore), #selector(toggleFirmwareZeroRestore(_:)))
            zeroItem.state = UserDefaults.standard.bool(forKey: "restoreFirmwareZero") ? .on : .off
            camera.addItem(zeroItem)
            camera.addItem(.separator())
            let fieldOfView = NSMenuItem(title: t(.menuCameraFieldOfView), action: nil, keyEquivalent: "")
            let angles = NSMenu()
            let currentAngle = UserDefaults.standard.object(forKey: "cameraFieldOfView") as? Double ?? 70
            for degrees in [60, 70, 80, 90, 100, 110] {
                let option = menuItem("\(degrees)°", #selector(chooseCameraFieldOfView(_:)))
                option.representedObject = degrees
                option.state = Double(degrees) == currentAngle ? .on : .off
                angles.addItem(option)
            }
            fieldOfView.submenu = angles
            camera.addItem(fieldOfView)
            let depth = NSMenuItem(title: t(.menuWallDepth), action: nil, keyEquivalent: "")
            let strengths = NSMenu()
            for percent in [25, 50, 75, 100] {
                let option = menuItem("\(percent) %", #selector(chooseWallDepth(_:)))
                option.representedObject = percent
                option.state = Double(percent) / 100 == wallDepthStrength ? .on : .off
                strengths.addItem(option)
            }
            depth.submenu = strengths
            camera.addItem(depth)
            let eyeArc = menuItem(t(.menuEyeArc), #selector(toggleEyeArc(_:)))
            eyeArc.state = eyeArcEnabled() ? .on : .off
            camera.addItem(eyeArc)
            camera.addItem(.separator())
            let debugItem = menuItem(t(.menuCameraDebugWindow), #selector(toggleCameraDebug(_:)))
            debugItem.state = cameraDebugWindow?.isVisible == true ? .on : .off
            camera.addItem(debugItem)
        })
        menu.addItem(submenu(t(.menuPicture)) { picture in
            picture.autoenablesItems = false
            picture.addItem(menuItem(t(.menuTogglePicture), #selector(toggleWindow)))
            let bordersItem = menuItem(t(.menuScreenBorders), #selector(toggleScreenBorders(_:)))
            bordersItem.state = UserDefaults.standard.bool(forKey: "hideScreenBorders") ? .off : .on
            picture.addItem(bordersItem)
            picture.addItem(.separator())
            picture.addItem(fovControl())
            picture.addItem(menuItem(t(.menuFieldOfViewWider), #selector(widerFOV)))
            picture.addItem(menuItem(t(.menuFieldOfViewNarrower), #selector(narrowerFOV)))
            picture.addItem(menuItem(t(.menuMorePrediction), #selector(morePrediction)))
            picture.addItem(menuItem(t(.menuLessPrediction), #selector(lessPrediction)))
            let stabilization = NSMenuItem(title: t(.menuStabilization), action: nil, keyEquivalent: "")
            let levels = NSMenu()
            for (level, title) in [(StabilizationLevel.off, t(.menuStabilizationOff)), (.weak, t(.menuStabilizationWeak)),
                                   (.medium, t(.menuStabilizationMedium)), (.strong, t(.menuStabilizationStrong))] {
                let item = menuItem(title, #selector(chooseStabilization(_:)))
                item.representedObject = level.rawValue
                item.state = level == savedStabilization() ? .on : .off
                levels.addItem(item)
            }
            stabilization.submenu = levels
            picture.addItem(stabilization)
            picture.addItem(.separator())
            picture.addItem(menuItem(t(.menuHorizonGrid), #selector(toggleGrid)))
            picture.addItem(menuItem(t(.menuGridManual), #selector(toggleCalibration)))
            picture.addItem(menuItem(t(.menuRecordGlassesVideo), #selector(toggleRecording)))
        })
        menu.addItem(meditationMenu())
        menu.addItem(submenu(t(.menuSettings)) { settings in
            for language in AppLanguage.allCases {
                let option = menuItem(language.nativeName, #selector(chooseLanguage(_:)))
                option.representedObject = language.rawValue
                option.state = language == Localization.shared.language ? .on : .off
                settings.addItem(option)
            }
        })
        menu.addItem(.separator())
        menu.addItem(mouseTapLine)
        menu.addItem(.separator())
        menu.addItem(menuItem(t(.menuQuit), #selector(quit)))
        return menu
    }

    private func applyStoredLanguage() {
        guard let raw = UserDefaults.standard.string(forKey: languageDefaultsKey),
              let language = AppLanguage(rawValue: raw) else { return }
        Localization.shared.language = language
    }

    @MainActor @objc private func chooseLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let language = AppLanguage(rawValue: raw) else { return }
        Localization.shared.language = language
        UserDefaults.standard.set(language.rawValue, forKey: languageDefaultsKey)
        cameraDebugWindow?.applyLanguage()
        cameraCalibrationWindow?.applyLanguage()
        glassesOutlineWindow?.applyLanguage()
        // Меню подменяется следующим тиком: сейчас AppKit ещё показывает то, из которого выбрали язык.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            statusItem?.menu = buildMenu()
        }
        log("language \(language.rawValue)")
    }

    private func submenu(_ title: String, _ build: (NSMenu) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        build(sub)
        item.submenu = sub
        return item
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func fovControl() -> NSMenuItem {
        let saved = savedVerticalFOV()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 26))
        let title = NSTextField(labelWithString: t(.menuFieldOfView))
        title.font = .menuFont(ofSize: 0)
        title.setContentHuggingPriority(.required, for: .horizontal)
        let value = NSTextField(labelWithString: "")
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        value.alignment = .right
        let slider = NSSlider(value: saved,
                              minValue: Renderer.verticalFOVRange.lowerBound,
                              maxValue: Renderer.verticalFOVRange.upperBound,
                              target: self, action: #selector(fovSliderChanged(_:)))
        slider.isContinuous = true
        slider.setAccessibilityLabel(t(.menuFieldOfView))
        slider.controlSize = .small
        slider.altIncrementValue = 0.5
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        for view in [title, slider, value] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            title.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            slider.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 10),
            slider.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            value.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 10),
            value.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            value.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            value.widthAnchor.constraint(equalToConstant: 46)
        ])
        fovSlider = slider
        fovValueLabel = value
        showVerticalFOV(saved)
        let item = NSMenuItem()
        item.view = container
        item.isEnabled = true
        return item
    }

    private func refreshStatus() {
        statusTicks += 1
        if statusTicks % 30 == 0 { saveGyroBias() }
        promptCompassRecalibrationIfFieldChanged()
        watchRendering()
        let cameraHoldsHeading = cameraHead.isRunning && cameraHead.correctsHeading
        if filter.compassPaused != cameraHoldsHeading {
            filter.compassPaused = cameraHoldsHeading
            log(cameraHoldsHeading ? "compass paused: camera reference owns heading (including temporary tracking loss)" : "compass resumed")
        }
        logCameraHead()
        let rate = imu?.takeSampleRate() ?? 0
        let yp = head.yawPitch
        if let renderer { showVerticalFOV(renderer.verticalFOV) }
        statusText = String(format: t(.statusLine),
                                    imu?.isConnected == true ? "✓" : "✗", rate,
                                    yp.yaw * 180 / .pi, yp.pitch * 180 / .pi, scene.screens.count, renderer?.verticalFOV ?? 0,
                                    filter.magnetometerCalibration == nil ? "✗" : "✓", imu?.temperature ?? 0)
        statusLine.title = statusText
        let learned = filter.gyroBias * 180 / .pi
        let compass = String(format: t(.statusGyroBias), learned.x, learned.y, learned.z)
            + (filter.magnetometerCalibration == nil ? t(.statusCompassOff) : String(format: t(.statusCompassError), filter.compassError * 180 / .pi) + (filter.compassFieldChanged ? t(.statusFieldChanged) : ""))
        log(statusText + String(format: t(.statusDiagnostics), compass,
                                                               imu?.temperature ?? 0, (renderer?.headPipeline.predictionSeconds ?? 0) * 1000, filter.restoredFirmwareUpdates))
        let applied = filter.appliedGyroBias * 180 / .pi
        let shift = filter.firmwareZeroShift * 180 / .pi
        log(String(format: "DIAG применён ноль %.3f %.3f %.3f · сдвиг восстановителя %.3f %.3f %.3f · доворот мира %.3f °/с · компас расходится %.1f°",
                   applied.x, applied.y, applied.z, shift.x, shift.y, shift.z,
                   filter.takeWorldRotation() * 180 / .pi, filter.compassError * 180 / .pi))
        // Скачок выученного нуля — частая причина внезапного увода мира: пишем, когда он случился.
        let raw = filter.gyroBias * 180 / .pi
        if let lastRawBias, length(raw - lastRawBias) > 0.5 {
            log(String(format: "DIAG ноль прыгнул на %.2f °/с за секунду · теперь %.2f %.2f %.2f",
                       length(raw - lastRawBias), raw.x, raw.y, raw.z))
        }
        lastRawBias = raw
    }

    private func refreshMouseTapLine() {
        switch mouseTapState {
        case .checking: mouseTapLine.title = t(.mouseTapChecking)
        case .needsAccessibility: mouseTapLine.title = t(.mouseTapNeedsAccessibility)
        case .running: mouseTapLine.title = t(.mouseTapRunning)
        }
    }

    private func setupMouseTap() {
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        if trusted {
            startMouseTap()
        } else {
            mouseTapState = .needsAccessibility
            refreshMouseTapLine()
            log("accessibility: not trusted, waiting for permission")
            accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self, AXIsProcessTrusted() else { return }
                accessibilityTimer?.invalidate()
                accessibilityTimer = nil
                startMouseTap()
            }
        }
    }

    private func startMouseTap() {
        guard let tap = MouseTap(delegate: self) else {
            fail(t(.alertMouseTapFailed))
            return
        }
        mouseTap = tap
        mouseTapState = .running
        refreshMouseTapLine()
        log("mouse tap: started")
    }

    private func fail(_ message: String) {
        log("ERROR \(message)")
        statusText = t(.statusError)
        statusLine.title = statusText
        let alert = NSAlert()
        alert.messageText = "RayDesk"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        watchdog.pause()
        alert.runModal()
        watchdog.resume()
    }
}

extension AppDelegate: MouseTapDelegate {
    func consumeFocusClick(at point: CGPoint) -> Bool {
        guard isSelectingFocus else { return false }
        guard let renderer, !renderer.meditation.isActive, let index = screenIndex(at: point) else {
            NSSound.beep()
            return true
        }
        let rect = bounds(of: index)
        guard rect.width > 0, rect.height > 0 else { return true }
        let uv = SIMD2(Double((point.x - rect.minX) / rect.width), Double((point.y - rect.minY) / rect.height))
        scene.beginFocus(index, uv: uv, head: head, origin: renderer.currentHeadOffset)
        setFocusSelection(false)
        updatePointerTargets(head: head)
        NSSound(named: "Tink")?.play()
        return true
    }

    private func focusedCursorPoint(_ point: CGPoint) -> CGPoint? {
        guard let focus = scene.focus else { return nil }
        let rect = bounds(of: focus.screen)
        guard !rect.contains(point) else { return nil }
        return CGPoint(x: min(rect.maxX - 1, max(rect.minX, point.x)), y: min(rect.maxY - 1, max(rect.minY, point.y)))
    }

    func screenIndex(at point: CGPoint) -> Int? {
        slots.firstIndex { $0.displayBounds.contains(point) }
    }

    func gazeHit() -> GazeHit? { lastGazeHit }

    func cursorHit() -> CursorHit? { lastCursorHit }

    func cursorTarget(at point: CGPoint) -> CursorTarget? {
        if let index = screenIndex(at: point) { return .virtual(index) }
        if macScreenOff, macBounds.contains(point) { return nil }
        return macBounds.contains(point) ? .mac : nil
    }

    func warpTarget(cursor: CursorTarget?) -> CursorTarget? {
        guard renderer?.meditation.isActive != true, scene.focus == nil else { return nil }
        let target = warpPolicy.warpTarget(cursor: cursor, buttonsDown: false, at: CACurrentMediaTime())
        return macScreenOff && target == .mac ? nil : target
    }

    func remappedCursor(previous: CGPoint, proposed: CGPoint, delta: CGVector) -> CGPoint? {
        if scene.focus != nil { return focusedCursorPoint(proposed) }
        guard let glassesID = glassesScreen()?.displayID else { return nil }
        var preferred: Int?
        if case .virtual(let index) = lastCursorHit?.target { preferred = index }
        return RayDeskCore.remappedCursor(previous: previous, proposed: proposed, delta: delta,
                                          panels: slots.map(\.displayBounds), main: macScreenOff ? .zero : macBounds,
                                          glasses: CGDisplayBounds(glassesID), preferredPanel: preferred)
    }

    func fencedCursor(previous: CGPoint, proposed: CGPoint) -> CGPoint? {
        if scene.focus != nil { return focusedCursorPoint(proposed) }
        guard let glassesID = glassesScreen()?.displayID else { return nil }
        return RayDeskCore.fencedCursor(previous: previous, proposed: proposed,
                                        main: macBounds, glasses: CGDisplayBounds(glassesID))
    }

    func bounds(of screen: Int) -> CGRect { slots[screen].displayBounds }

    func bounds(of target: CursorTarget) -> CGRect {
        switch target {
        case .virtual(let index): slots[index].displayBounds
        case .mac: macBounds
        }
    }

    func pose(of screen: Int) -> ScreenPose { scene.screens[screen] }

    func setPose(_ screen: Int, _ pose: ScreenPose) { scene.setPose(screen, pose) }

    func dragBegan(_ screen: Int) {
        renderer?.draggingScreen = screen
        log("drag began: screen \(screen + 1)")
    }

    func snapped(_ pose: ScreenPose, screen: Int) -> ScreenPose {
        let result = RayDeskCore.snapped(pose, index: screen, among: scene.screens, threshold: 3 * .pi / 180, join: savedJoin())
        if result.neighbor != snapNeighbor {
            snapNeighbor = result.neighbor
            renderer?.snappedNeighbor = result.neighbor
            if let neighbor = result.neighbor {
                log("screen \(screen + 1) snapped to \(neighbor + 1)")
            }
        }
        return result.pose
    }

    func dragEnded() {
        snapNeighbor = nil
        renderer?.snappedNeighbor = nil
        renderer?.draggingScreen = nil
        saveScene()
        arrangeDisplays()
    }

    func scrollApplied(to screen: Int) {
        saveScene()
    }

    func cursorScreenChanged(_ screen: Int?) {
        renderer?.cursorScreen = screen
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

private let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RayDesk.log")

/// Время в логе: один форматтер на процесс.
///
/// `Date.formatted` тянет локаль лениво и может прокрутить главный цикл — вызов из кадра
/// отрисовки заходит в отрисовку повторно, и кадр растягивается.
private let logFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "H:mm:ss"
    return formatter
}()

func log(_ message: String) {
    let line = "\(logFormatter.string(from: Date())) \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: logURL)
    }
}

private final class GyroScaleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var calibration = GyroScaleCalibration(turns: 2)

    var isRunning: Bool {
        lock.withLock {
            switch calibration.stage {
            case .finished, .failed: false
            default: true
            }
        }
    }

    func add(_ sample: IMUSample) -> (GyroScaleCalibration.Stage, GyroScaleCalibration.Stage)? {
        lock.withLock {
            let previous = calibration.stage
            let current = calibration.add(gyro: sample.gyro, accel: sample.accel, dt: sample.dt)
            return previous == current ? nil : (previous, current)
        }
    }
}
