import AppKit
import MetalKit
import Carbon.HIToolbox
import ApplicationServices
import QuartzCore
import AVFoundation
import simd
import RayDeskCore

private let sceneDefaultsKey = "screens.v2"

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var scene = SpatialScene(screens: SpatialScene.decode(UserDefaults.standard.data(forKey: sceneDefaultsKey), default: 2, aspect: 16.0 / 9.0))
    private let filter = OrientationFilter()
    private let hotkeys = Hotkeys()
    private var imu: GlassesIMU?
    private var slots: [ScreenSlot] = []
    private var window: NSWindow?
    private var glassesView: MTKView?
    private var frameLink: CADisplayLink?
    private var lastRenderedFrame = CACurrentMediaTime()
    private var renderStalled = false
    private var renderer: Renderer?
    private var isCalibrating = false
    private var statusTicks = 0
    private var compassFieldPrompted = false
    private var lastCorrection: (time: CFTimeInterval, travel: RotationTravel)?
    private let recorder = GlassesRecorder()
    private let speech = AVSpeechSynthesizer()
    private var isCalibratingCompass = false
    private var statusItem: NSStatusItem?
    private var statusLine = NSMenuItem(title: "Запуск…", action: nil, keyEquivalent: "")
    private var statusTimer: Timer?
    private var mouseTapLine = NSMenuItem(title: "Перетаскивание мышью: проверка разрешений…", action: nil, keyEquivalent: "")
    private var mouseTap: MouseTap?
    private var accessibilityTimer: Timer?
    private var warpPolicy = CursorWarpPolicy()
    private var lastCursorHit: CursorHit?
    private var macAnchor: MacAnchor?
    private var macAimTimeout: DispatchWorkItem?
    private var lastGazeHit: GazeHit?
    private var snapNeighbor: Int?
    private let meditationAudio = MeditationAudio()
    private var cameraDebugWindow: CameraDebugWindow?
    private lazy var cameraHead = CameraHeadTracker { [filter] uptime in (filter.orientation(atUptime: uptime), filter.angularSpeed) }
    private let glassesVision = GlassesVision()
    private let watchdog = MainThreadWatchdog()
    private var glassesTrackingItem: NSMenuItem?
    private var learningGlasses = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        watchdog.start()
        setupMenu()
        setupHotkeys()
        setupMouseTap()

        guard glassesScreen()?.displayID != nil else {
            fail("Очки не найдены среди дисплеев. Подключите RayNeo и перезапустите.")
            return
        }

        useLightGlassesMode()
        slots = scene.screens.indices.map { ScreenSlot(index: $0) }
        saveScene()
        arrangeDisplays()

        loadCompassCalibration()
        loadGyroBias()
        loadGyroScale()
        loadMacAnchor()
        cameraHead.turnWorld = { [filter] angle in filter.rotateWorldYaw(by: angle) }
        if UserDefaults.standard.bool(forKey: "glassesTracking") {
            glassesVision.start()
            cameraHead.useGlasses(glassesVision)
        }
        filter.restoresFirmwareZero = UserDefaults.standard.bool(forKey: "restoreFirmwareZero")
        imu = GlassesIMU(filter: filter)
        if UserDefaults.standard.bool(forKey: "recordIMU") {
            imu?.recorder = IMURecorder()
        }
        imu?.start()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.fitWindowToGlasses()
            self?.restartFrameLink()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            do {
                try openGlassesWindow()
            } catch {
                fail("Metal: \(error)")
                return
            }
            startCaptures()
        }

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStatus() }
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
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let glassesBounds = CGDisplayBounds(glassesID)
        let sizes = slots.map(\.displayBounds.size)
        let result = RayDeskCore.arrangeDisplays(screenYaws: scene.screens.map(\.yaw), screenSizes: sizes, main: mainBounds, glasses: glassesBounds.size)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        for (slot, origin) in zip(slots, result.screens) {
            CGConfigureDisplayOrigin(config, slot.virtualScreen.displayID, Int32(origin.x), Int32(origin.y))
        }
        CGConfigureDisplayOrigin(config, glassesID, Int32(result.glasses.x), Int32(result.glasses.y))
        let status = CGCompleteDisplayConfiguration(config, .forAppOnly)
        log("arrange displays: \(status.rawValue)")
    }

    private func startCaptures() {
        if !CGPreflightScreenCaptureAccess() {
            log("screen capture: not granted, requesting")
            CGRequestScreenCaptureAccess()
            fail("Нужно разрешение на запись экрана.\n\nСистемные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука → включите RayDesk, затем перезапустите RayDesk.\n\nПока в очках будет серый прямоугольник вместо экрана.")
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
                fail("Захват экрана \(slot.index + 1) не запустился: \(error)")
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
        if let calibration = loadSetting(ViewCalibration.self, key: "viewCalibration", name: "Настройка сетки") {
            renderer.calibration = calibration
        }
        if let savedFOV = UserDefaults.standard.object(forKey: "verticalFOV") as? Double {
            renderer.verticalFOV = savedFOV
        }
        renderer.slots = slots
        renderer.macAnchor = macAnchor
        renderer.stabilizer.level = savedStabilization()
        if let savedPrediction = UserDefaults.standard.object(forKey: "predictionMs") as? Double {
            renderer.headPipeline.predictionSeconds = savedPrediction / 1000
        }
        renderer.breathingEnabled = UserDefaults.standard.bool(forKey: "meditationBreathing")
        renderer.onFrame = { [weak self] head in
            guard let self else { return }
            lastGazeHit = RayDeskCore.gazeHit(head: head, screens: scene.screens)
            lastCursorHit = RayDeskCore.cursorHit(head: head, screens: scene.screens, mac: macAnchor)
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
    }

    private func restartFrameLink() {
        guard let screen = glassesScreen() else { return }
        frameLink?.invalidate()
        let link = screen.displayLink(target: self, selector: #selector(renderFrame))
        link.add(to: .main, forMode: .common)
        frameLink = link
        lastRenderedFrame = CACurrentMediaTime()
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

    private func fitWindowToGlasses() {
        guard let window, let screen = glassesScreen(), window.frame != screen.frame else { return }
        window.setFrame(screen.frame, display: true)
    }

    enum GlassesError: Error { case screenMissing }

    private var head: simd_quatd { renderer?.currentHead ?? simd_quatd(ix: 0, iy: 0, iz: 0, r: 1) }

    private func targetScreen() -> Int {
        RayDeskCore.gazeHit(head: head, screens: scene.screens)?.screen ?? scene.screens.count - 1
    }

    private func saveScene() {
        UserDefaults.standard.set(scene.encoded(), forKey: sceneDefaultsKey)
    }

    @objc private func placeHere() {
        scene.place(targetScreen(), head: head)
        saveScene()
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

    private func say(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        speech.speak(utterance)
        log("say: \(text)")
    }

    private func loadSetting<Value: Decodable>(_ type: Value.Type, key: String, name: String) -> Value? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            UserDefaults.standard.removeObject(forKey: key)
            log("\(key): stored value unreadable, reset: \(error)")
            say("\(name) сброшена, настройте заново.")
            return nil
        }
    }

    private func saveSetting<Value: Encodable>(_ value: Value, key: String) {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            log("\(key): not saved: \(error)")
            say("Не удалось сохранить настройку.")
        }
    }

    private func loadCompassCalibration() {
        guard UserDefaults.standard.bool(forKey: "compassEnabled") else {
            log("compass: off")
            return
        }
        guard let calibration = loadSetting(MagnetometerCalibration.self, key: "magCalibration.v1", name: "Калибровка компаса") else {
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

    @objc private func calibrateGyroScale() {
        guard let imu else { return }
        let box = GyroScaleBox()
        say("Калибровка масштаба гироскопа. Поставьте очки на стол как на голове, дужками вниз, прижмите дужку к краю ноутбука и не трогайте.")
        log("gyro scale calibration started")
        imu.sampleSink = { [weak self] sample in
            guard let (previous, current) = box.add(sample) else { return }
            DispatchQueue.main.async { self?.gyroScaleStageChanged(from: previous, to: current) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self, weak imu] in
            guard imu?.sampleSink != nil, box.isRunning else { return }
            imu?.sampleSink = nil
            self?.say("Калибровка гироскопа прервана: время вышло.")
            log("gyro scale calibration timed out")
        }
    }

    private func gyroScaleStageChanged(from previous: GyroScaleCalibration.Stage, to stage: GyroScaleCalibration.Stage) {
        switch stage {
        case .readyToTurn:
            say("Ноль измерен. Медленно поверните очки на два полных оборота и прижмите дужку к тому же краю. Потом не трогайте.")
        case .turning:
            break
        case .finished(let scale, let measured):
            imu?.sampleSink = nil
            let updated = SIMD3(1, scale, 1)
            filter.gyroScale = updated
            UserDefaults.standard.set([updated.x, updated.y, updated.z], forKey: "gyroScale.v1")
            log(String(format: "gyro scale calibrated: measured %.1f° for 720°, scale %.4f, stored %.4f", measured, scale, updated.y))
            say(String(format: "Готово. Гироскоп ошибался на %.1f процента, поправка сохранена.", (1 / scale - 1) * 100))
        case .failed(.notUpright):
            imu?.sampleSink = nil
            say("Не получилось: очки лежат не так, как на голове. Поставьте их на дужки и начните заново.")
            log("gyro scale calibration failed: not upright")
        case .failed(.wrongTurnCount(let measured)):
            imu?.sampleSink = nil
            say("Не получилось: насчитал не два оборота. Начните заново.")
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
        say("Калибровка компаса. Двадцать пять секунд медленно поворачивайте голову во все стороны: влево, вправо, вверх, вниз и к плечам.")
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
        say("Магнитное поле у очков изменилось, например от наушников. Чтобы экраны держались точнее, откалибруйте компас: Control Option K.")
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
            say("Компас откалиброван.")
        } catch MagnetometerCalibrationError.tooFewSamples(let count) {
            log("compass calibration failed: too few samples \(count)")
            say("Не получилось: от очков пришло мало данных компаса. Попробуйте ещё раз.")
        } catch MagnetometerCalibrationError.insufficientCoverage(let spread) {
            log(String(format: "compass calibration failed: coverage %.4f", spread))
            say("Не получилось: мало поворотов. Повторите и крутите головой шире, особенно наклоны к плечам.")
        } catch MagnetometerCalibrationError.noisyField(let spread) {
            log(String(format: "compass calibration failed: field spread %.3f", spread))
            say("Не получилось: поле сильно искажено. Отодвиньтесь от магнитов и колонок и повторите.")
        } catch {
            fail("Калибровка компаса: \(error)")
        }
    }


    private func loadMacAnchor() {
        macAnchor = loadSetting(MacAnchor.self, key: "macAnchor.v1", name: "Позиция экрана Mac")
    }

    @objc private func captureMacAnchor() {
        guard let renderer else { return }
        let main = CGDisplayBounds(CGMainDisplayID())
        let anchor = MacAnchor.captured(head: renderer.currentHead, aspect: main.width / main.height)
        macAnchor = anchor
        renderer.macAnchor = anchor
        saveSetting(anchor, key: "macAnchor.v1")
        log(String(format: "mac anchor: yaw %.1f° pitch %.1f°", anchor.pose.yaw * 180 / .pi, anchor.pose.pitch * 180 / .pi))
        NSSound(named: "Tink")?.play()
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
                fail("Запись видео очков: \(error)")
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

    @objc private func recenterWorld() {
        guard let renderer, let anchor = macAnchor else {
            recenterToGaze()
            return
        }
        guard renderer.aimingAtMac else {
            renderer.aimingAtMac = true
            macAimTimeout?.cancel()
            let timeout = DispatchWorkItem { [weak self] in self?.renderer?.aimingAtMac = false }
            macAimTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
            NSSound(named: "Pop")?.play()
            return
        }
        macAimTimeout?.cancel()
        renderer.aimingAtMac = false
        let filterYaw = filter.orientation(predictAhead: 0).yawPitch.yaw
        let renderedYaw = renderer.currentHead.yawPitch.yaw
        let target = remainder(anchor.pose.yaw - (renderedYaw - renderer.calibration.yaw - filterYaw), 2 * .pi)
        logCorrection(kind: "recenter-mac", yawDegrees: remainder(anchor.pose.yaw - renderedYaw, 2 * .pi) * 180 / .pi)
        filter.alignYaw(to: target)
        renderer.calibration.yaw = 0
        if renderer.headOffset != nil {
            cameraHead.worldYawChanged(by: target - filterYaw)
            if glassesTracking { cameraHead.resetReference(after: 0.3) }
        }
        NSSound(named: "Tink")?.play()
    }

    @objc private func recenterToGaze() {
        guard let renderer else { return }
        macAimTimeout?.cancel()
        renderer.aimingAtMac = false
        let yaw = filter.orientation(predictAhead: 0).yawPitch.yaw
        logCorrection(kind: "recenter", yawDegrees: -renderer.currentHead.yawPitch.yaw * 180 / .pi)
        filter.alignYawToZero()
        renderer.calibration.yaw = 0
        if renderer.headOffset != nil {
            cameraHead.worldYawChanged(by: -yaw)
            if glassesTracking { cameraHead.resetReference(after: 0.3) }
        }
    }

    @objc private func toggleCameraDebug(_ sender: NSMenuItem) {
        if let window = cameraDebugWindow, window.isVisible {
            window.close()
            cameraHead.observe(nil)
            sender.state = .off
            log("camera debug window off")
            return
        }
        let open = { [weak self] in
            guard let self else { return }
            let display: CGDirectDisplayID? = slots.isEmpty ? nil : slots[targetScreen()].virtualScreen.displayID
            let screen = NSScreen.screens.first { $0.displayID == display }
            let window = CameraDebugWindow(session: cameraHead.captureSession, on: screen)
            cameraDebugWindow = window
            cameraHead.observe { [weak window] observation in window?.update(observation) }
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
                self?.say("Камера недоступна. Разрешите RayDesk доступ к камере в настройках конфиденциальности.")
                return
            }
            log("camera head tracking on")
            open()
        }
    }

    private var wallDepthStrength: Double {
        UserDefaults.standard.object(forKey: "wallDepthStrength") as? Double ?? (glassesTracking ? 1 : 0.25)
    }

    @objc private func chooseCameraFieldOfView(_ sender: NSMenuItem) {
        guard let degrees = sender.representedObject as? Int else { return }
        UserDefaults.standard.set(Double(degrees), forKey: "cameraFieldOfView")
        sender.menu?.items.forEach { $0.state = ($0.representedObject as? Int) == degrees ? .on : .off }
        cameraHead.resetReference(after: 0.3)
        log("camera field of view \(degrees)°")
    }

    @objc private func chooseWallDepth(_ sender: NSMenuItem) {
        guard let percent = sender.representedObject as? Int else { return }
        UserDefaults.standard.set(Double(percent) / 100, forKey: "wallDepthStrength")
        sender.menu?.items.forEach { $0.state = ($0.representedObject as? Int) == percent ? .on : .off }
        log("wall depth strength \(percent)%")
    }

    @objc private func toggleWallMode(_ sender: NSMenuItem) {
        guard let renderer else { return }
        if renderer.headOffset != nil {
            renderer.headOffset = nil
            sender.state = .off
            log("wall mode off")
            return
        }
        let enable = { [weak self] in
            guard let self, let renderer = self.renderer else { return }
            cameraHead.resetReference(after: glassesTracking ? 1 : 4)
            var referenceHead: simd_quatd?
            var generation = -1
            renderer.headOffset = { [cameraHead, weak self] head in
                if cameraHead.referenceGeneration != generation {
                    generation = cameraHead.referenceGeneration
                    referenceHead = head
                }
                var offset = cameraHead.neckOffset()
                offset.z *= self?.wallDepthStrength ?? 0.25
                let neck = worldOffset(fromCamera: offset, cameraYaw: cameraHead.cameraYaw ?? 0)
                guard let referenceHead else { return neck }
                return neck + eyeArcOffset(head: head, reference: referenceHead)
            }
            sender.state = .on
            say(glassesTracking ? "Калибровка камерой включена. Посидите спокойно секунду, я запомню положение головы."
                : "Дополнительная калибровка камерой включена. Сядьте удобно и посмотрите в камеру ноутбука, через пару секунд я запомню, где она.")
            log("wall mode on")
        }
        if cameraHead.isRunning {
            enable()
            return
        }
        cameraHead.start { [weak self] error in
            if let error {
                log("camera head tracking failed: \(error)")
                self?.say("Камера недоступна. Разрешите RayDesk доступ к камере в настройках конфиденциальности.")
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
            learningGlasses = false
            sender.state = .off
            Task { @MainActor [weak self] in
                guard let self else { return }
                let points = await glassesVision.stopLearning() ?? 0
                log("glasses shape learned: \(points) points")
                say(points > 0 ? "Форма очков запомнена." : "Форма очков не набралась. Проверьте, что лицо видно в камеру, и попробуйте ещё раз.")
            }
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
                    say("Смотрите в камеру ноутбука и секунд двадцать медленно крутите головой влево, вправо, вверх и вниз. Руки держите подальше от лица. Потом выберите этот пункт ещё раз.")
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
                self?.say("Камера недоступна. Разрешите RayDesk доступ к камере в настройках конфиденциальности.")
                return
            }
            log("camera head tracking on")
            begin()
        }
    }

    @objc private func toggleCameraHead(_ sender: NSMenuItem) {
        if cameraHead.isRunning || sender.state == .on {
            cameraHead.stop()
            renderer?.headOffset = nil
            sender.state = .off
            log("camera head tracking off")
            return
        }
        sender.state = .on
        cameraHead.start { [weak self] error in
            guard let error else {
                log("camera head tracking on")
                return
            }
            sender.state = .off
            log("camera head tracking failed: \(error)")
            self?.say("Камера недоступна. Разрешите RayDesk доступ к камере в настройках конфиденциальности.")
        }
    }

    @objc private func guidedCameraMeasurement() {
        let steps: [(phase: String, seconds: Double, prompt: String)] = [
            ("rest", 12, "Замер по шагам. Смотрите прямо на средний экран и не двигайтесь."),
            ("turn-left", 8, "Поверните голову к левому монитору и замрите."),
            ("rest", 6, "Снова прямо."),
            ("turn-right", 8, "Поверните голову к правому монитору и замрите."),
            ("rest", 6, "Снова прямо."),
            ("lean-in", 8, "Наклонитесь к экрану, не поворачивая головы."),
            ("rest", 6, "Вернитесь."),
            ("lean-back", 8, "Отклонитесь назад."),
            ("rest", 6, "Вернитесь."),
            ("shift-left", 8, "Сдвиньтесь всем телом влево, смотрите прямо."),
            ("rest", 6, "Вернитесь."),
            ("shift-right", 8, "Сдвиньтесь всем телом вправо, смотрите прямо."),
            ("rest", 6, "Вернитесь."),
        ]
        let run = { [weak self] in
            guard let self else { return }
            var start = 0.0
            for step in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + start) { [weak self] in
                    self?.cameraHead.phase = step.phase
                    self?.say(step.prompt)
                    log("CAMERA phase \(step.phase)")
                }
                start += step.seconds
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + start) { [weak self] in
                self?.cameraHead.phase = ""
                self?.say("Замер окончен, спасибо.")
                log("CAMERA guided measurement done")
            }
        }
        if cameraHead.isRunning {
            run()
            return
        }
        cameraHead.start { [weak self] error in
            if let error {
                log("camera head tracking failed: \(error)")
                self?.say("Камера недоступна. Разрешите RayDesk доступ к камере в настройках конфиденциальности.")
                return
            }
            log("camera head tracking on")
            run()
        }
    }

    private func logCameraHead() {
        guard cameraHead.isRunning else { return }
        let reading = cameraHead.takeReading()
        if let glasses = reading.glassesPerSecond {
            log(String(format: "CAMERA по очкам: найдены в %d из %d кадров/с, с лицом %d · совпадение формы %.0f%% · курс по камере: расхождение %.1f°, доворот %.2f°, уплывание гироскопа %.2f°/с, масштаб курса камеры %.2f",
                       glasses, reading.framesPerSecond, reading.facesPerSecond, (reading.glassesScore ?? .nan) * 100,
                       (reading.headingDrift ?? .nan) * 180 / .pi, reading.headingCorrection * 180 / .pi,
                       reading.headingRate * 180 / .pi, reading.faceYawScale))
        }
        guard let position = reading.position else {
            log("CAMERA лицо не найдено · кадров \(reading.framesPerSecond)/с")
            return
        }
        let jitter = (reading.jitter ?? .zero) * 1000
        let angles = (reading.angles ?? SIMD3(repeating: .nan)) * (180 / .pi)
        let neck = cameraHead.neckOffset() * 100
        log(String(format: "CAMERA шея сдвинута x %.1f y %.1f z %.1f см · задержка кадра %.0f мс%@", neck.x, neck.y, neck.z,
                   (reading.latency ?? .nan) * 1000, renderer?.headOffset != nil ? " · калибровка камерой" : ""))
        log(String(format: "CAMERA голова x %.1f y %.1f z %.1f см · дрожь %.1f %.1f %.1f мм · кадров %d/с, с лицом %d · лицо yaw %.0f° pitch %.0f° roll %.0f°",
                   position.x * 100, position.y * 100, position.z * 100, jitter.x, jitter.y, jitter.z,
                   reading.framesPerSecond, reading.facesPerSecond, angles.x, angles.y, angles.z))
    }

    @objc private func moveWindowToGaze() {
        guard let target = lastCursorHit?.target else {
            say("Посмотрите на экран, куда перенести окно.")
            return
        }
        let display: CGDirectDisplayID
        switch target {
        case .virtual(let index): display = slots[index].virtualScreen.displayID
        case .mac: display = CGMainDisplayID()
        }
        do {
            let moved = try WindowMover.moveFrontWindow(to: display)
            log(String(format: "window of %@ moved to %@ at %.0f,%.0f %.0f×%.0f", moved.app, String(describing: target),
                       moved.frame.minX, moved.frame.minY, moved.frame.width, moved.frame.height))
        } catch WindowMoveError.noAccessibility {
            say("Нужно разрешение «Универсальный доступ» для RayDesk.")
        } catch WindowMoveError.noFrontWindow {
            log("window move: no front window")
            say("Нет активного окна.")
        } catch {
            log("window move failed: \(error)")
            say("Это окно не переносится.")
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
        let item = NSMenuItem(title: "Стыковка экранов", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (join, title) in [(ScreenJoin.hinge, "Как тройной монитор: вертикально, стык по всей длине"),
                              (.gaze, "По взгляду: каждый экран смотрит на вас")] {
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
        let item = NSMenuItem(title: "Медитация", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(menuItem("Включить / выключить   ⌃⌥Z", #selector(toggleMeditation)))
        let breathing = menuItem("Дыхание (вдох 4 с, выдох 6 с)", #selector(toggleBreathing(_:)))
        breathing.state = UserDefaults.standard.bool(forKey: "meditationBreathing") ? .on : .off
        submenu.addItem(breathing)
        submenu.addItem(.separator())
        submenu.addItem(NSMenuItem(title: "Нейроэффект", action: nil, keyEquivalent: ""))
        let saved = savedNeuralEffect()
        meditationAudio.neuralEffect = saved
        for (effect, title) in [(NeuralEffect.off, "Выключен"), (.low, "Слабый"), (.medium, "Средний"), (.high, "Сильный")] {
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
        renderer.toggleMeditation()
        if renderer.meditation.isActive {
            do {
                try meditationAudio.start()
            } catch {
                log("meditation audio failed: \(error)")
                say("Не удалось включить звук медитации.")
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
    private func changeFOV(by delta: Double) {
        guard let renderer else { return }
        renderer.verticalFOV = min(60, max(10, renderer.verticalFOV + delta))
        UserDefaults.standard.set(renderer.verticalFOV, forKey: "verticalFOV")
        log(String(format: "vertical FOV %.1f°", renderer.verticalFOV))
    }
    @objc private func toggleWindow() {
        guard let window else { return }
        window.isVisible ? window.orderOut(nil) : window.orderFrontRegardless()
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func setupHotkeys() {
        hotkeys.register(keyCode: kVK_Space) { [weak self] in self?.placeHere() }
        hotkeys.register(keyCode: kVK_ANSI_G) { [weak self] in self?.toggleGrab() }
        hotkeys.register(keyCode: kVK_UpArrow) { [weak self] in
            guard let self else { return }
            isCalibrating ? adjustCalibration(pitch: 0.5) : closer()
        }
        hotkeys.register(keyCode: kVK_DownArrow) { [weak self] in
            guard let self else { return }
            isCalibrating ? adjustCalibration(pitch: -0.5) : farther()
        }
        hotkeys.register(keyCode: kVK_UpArrow, modifiers: controlKey | optionKey | shiftKey) { [weak self] in self?.tiltBack() }
        hotkeys.register(keyCode: kVK_DownArrow, modifiers: controlKey | optionKey | shiftKey) { [weak self] in self?.tiltForward() }
        hotkeys.register(keyCode: kVK_LeftArrow, modifiers: controlKey | optionKey | shiftKey) { [weak self] in self?.turnLeft() }
        hotkeys.register(keyCode: kVK_RightArrow, modifiers: controlKey | optionKey | shiftKey) { [weak self] in self?.turnRight() }
        hotkeys.register(keyCode: kVK_UpArrow, modifiers: controlKey | optionKey | cmdKey) { [weak self] in self?.tiltAllBack() }
        hotkeys.register(keyCode: kVK_DownArrow, modifiers: controlKey | optionKey | cmdKey) { [weak self] in self?.tiltAllForward() }
        hotkeys.register(keyCode: kVK_LeftArrow) { [weak self] in self?.adjustCalibration(yaw: 1) }
        hotkeys.register(keyCode: kVK_RightArrow) { [weak self] in self?.adjustCalibration(yaw: -1) }
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
        hotkeys.register(keyCode: kVK_ANSI_R) { [weak self] in self?.recenterWorld() }
        hotkeys.register(keyCode: kVK_ANSI_R, modifiers: controlKey | optionKey | shiftKey) { [weak self] in self?.recenterToGaze() }
        hotkeys.register(keyCode: kVK_ANSI_V) { [weak self] in self?.toggleRecording() }
        hotkeys.register(keyCode: kVK_ANSI_K) { [weak self] in self?.calibrateCompass() }
        hotkeys.register(keyCode: kVK_ANSI_B) { [weak self] in self?.captureMacAnchor() }
        hotkeys.register(keyCode: kVK_ANSI_J) { [weak self] in self?.warpCursorToGaze() }
        hotkeys.register(keyCode: kVK_ANSI_RightBracket) { [weak self] in self?.widerFOV() }
        hotkeys.register(keyCode: kVK_ANSI_LeftBracket) { [weak self] in self?.narrowerFOV() }
        hotkeys.register(keyCode: kVK_ANSI_Z) { [weak self] in self?.toggleMeditation() }
        hotkeys.register(keyCode: kVK_ANSI_A) { [weak self] in self?.arrangeInArc() }
        hotkeys.register(keyCode: kVK_ANSI_W) { [weak self] in self?.moveWindowToGaze() }
    }

    private func setupMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "RayDesk")
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(menuItem("Поставить экран туда, куда смотрю   ⌃⌥Space", #selector(placeHere)))
        menu.addItem(menuItem("Взять / отпустить экран   ⌃⌥G", #selector(toggleGrab)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Ближе   ⌃⌥↑", #selector(closer)))
        menu.addItem(menuItem("Дальше   ⌃⌥↓", #selector(farther)))
        menu.addItem(menuItem("Больше   ⌃⌥=", #selector(bigger)))
        menu.addItem(menuItem("Меньше   ⌃⌥−", #selector(smaller)))
        menu.addItem(menuItem("Наклонить назад   ⌃⌥⇧↑", #selector(tiltBack)))
        menu.addItem(menuItem("Наклонить вперёд   ⌃⌥⇧↓", #selector(tiltForward)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Вернуть экраны по MacBook: навести перекрестие, ещё раз   ⌃⌥R", #selector(recenterWorld)))
        menu.addItem(menuItem("«Вперёд» = куда смотрю   ⌃⌥⇧R", #selector(recenterToGaze)))
        menu.addItem(menuItem("Метка: смотрю на средний экран (только в лог)   ⌃⌥M", #selector(markReference)))
        menu.addItem(menuItem("Собрать экраны перед собой", #selector(gatherScreens)))
        menu.addItem(menuItem("Собрать дугой, край к краю   ⌃⌥A", #selector(arrangeInArc)))
        menu.addItem(joinMenu())
        menu.addItem(menuItem("Довернуть экран влево   ⌃⌥⇧←", #selector(turnLeft)))
        menu.addItem(menuItem("Довернуть экран вправо   ⌃⌥⇧→", #selector(turnRight)))
        menu.addItem(menuItem("Наклонить все назад   ⌃⌥⌘↑", #selector(tiltAllBack)))
        menu.addItem(menuItem("Наклонить все вперёд   ⌃⌥⌘↓", #selector(tiltAllForward)))
        menu.addItem(menuItem("Записать видео очков (старт/стоп)   ⌃⌥V", #selector(toggleRecording)))
        menu.addItem(menuItem("Калибровка компаса   ⌃⌥K", #selector(calibrateCompass)))
        menu.addItem(menuItem("Калибровка масштаба гироскопа (очки на столе)", #selector(calibrateGyroScale)))
        menu.addItem(menuItem("Экран Mac — там, куда смотрю   ⌃⌥B", #selector(captureMacAnchor)))
        menu.addItem(menuItem("Курсор — туда, куда смотрю   ⌃⌥J", #selector(warpCursorToGaze)))
        menu.addItem(menuItem("Окно — туда, куда смотрю   ⌃⌥W", #selector(moveWindowToGaze)))
        menu.addItem(menuItem("Камера: замер положения головы", #selector(toggleCameraHead(_:))))
        menu.addItem(menuItem("Камера: замер по шагам с подсказками", #selector(guidedCameraMeasurement)))
        menu.addItem(menuItem("Дополнительная калибровка камерой (эксперимент)", #selector(toggleWallMode(_:))))
        let glassesItem = menuItem("Положение головы по очкам (MediaPipe, проба)", #selector(toggleGlassesTracking(_:)))
        glassesItem.state = UserDefaults.standard.bool(forKey: "glassesTracking") ? .on : .off
        glassesTrackingItem = glassesItem
        menu.addItem(glassesItem)
        menu.addItem(menuItem("Выучить форму очков (старт/стоп)", #selector(toggleGlassesLearning(_:))))
        menu.addItem(menuItem("Камера: окно отладки (рамка и точки лица)", #selector(toggleCameraDebug(_:))))
        let fieldOfView = NSMenuItem(title: "Угол обзора камеры (масштаб вперёд-назад)", action: nil, keyEquivalent: "")
        let angles = NSMenu()
        let currentAngle = UserDefaults.standard.object(forKey: "cameraFieldOfView") as? Double ?? 70
        for degrees in [60, 70, 80, 90, 100, 110] {
            let option = menuItem("\(degrees)°", #selector(chooseCameraFieldOfView(_:)))
            option.representedObject = degrees
            option.state = Double(degrees) == currentAngle ? .on : .off
            angles.addItem(option)
        }
        fieldOfView.submenu = angles
        menu.addItem(fieldOfView)
        let depth = NSMenuItem(title: "Калибровка камерой: сила вперёд-назад", action: nil, keyEquivalent: "")
        let strengths = NSMenu()
        for percent in [25, 50, 75, 100] {
            let option = menuItem("\(percent) %", #selector(chooseWallDepth(_:)))
            option.representedObject = percent
            option.state = Double(percent) / 100 == wallDepthStrength ? .on : .off
            strengths.addItem(option)
        }
        depth.submenu = strengths
        menu.addItem(depth)
        let compassItem = menuItem("Компас (эксперимент)", #selector(toggleCompass(_:)))
        compassItem.state = UserDefaults.standard.bool(forKey: "compassEnabled") ? .on : .off
        menu.addItem(compassItem)
        menu.addItem(menuItem("Добавить экран", #selector(addScreen)))
        menu.addItem(menuItem("Убрать экран", #selector(removeScreen)))
        menu.addItem(.separator())
        menu.addItem(meditationMenu())
        menu.addItem(.separator())
        menu.addItem(menuItem("Скрыть / показать картинку   ⌃⌥H", #selector(toggleWindow)))
        menu.addItem(menuItem("Сетка горизонта   ⌃⌥D", #selector(toggleGrid)))
        let bordersItem = menuItem("Рамка вокруг экранов", #selector(toggleScreenBorders(_:)))
        bordersItem.state = UserDefaults.standard.bool(forKey: "hideScreenBorders") ? .off : .on
        menu.addItem(bordersItem)
        let stabilization = NSMenuItem(title: "Стабилизация картинки", action: nil, keyEquivalent: "")
        let levels = NSMenu()
        for (level, title) in [(StabilizationLevel.off, "Выключена"), (.weak, "Слабая"), (.medium, "Средняя"), (.strong, "Сильная")] {
            let item = menuItem(title, #selector(chooseStabilization(_:)))
            item.representedObject = level.rawValue
            item.state = level == savedStabilization() ? .on : .off
            levels.addItem(item)
        }
        stabilization.submenu = levels
        menu.addItem(stabilization)
        menu.addItem(menuItem("Настроить сетку вручную   ⌃⌥C (стрелки, ⌃⌥, ⌃⌥.)", #selector(toggleCalibration)))
        menu.addItem(menuItem("Угол обзора больше   ⌃⌥]", #selector(widerFOV)))
        menu.addItem(menuItem("Угол обзора меньше   ⌃⌥[", #selector(narrowerFOV)))
        menu.addItem(menuItem("Предсказание больше   ⌃⌥0", #selector(morePrediction)))
        menu.addItem(menuItem("Предсказание меньше   ⌃⌥9", #selector(lessPrediction)))
        menu.addItem(menuItem("Перекалибровать гироскоп", #selector(recalibrate)))
        menu.addItem(.separator())
        menu.addItem(mouseTapLine)
        menu.addItem(.separator())
        menu.addItem(menuItem("Выйти   ⌃⌥Q", #selector(quit)))
        item.menu = menu
        statusItem = item
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func refreshStatus() {
        statusTicks += 1
        if statusTicks % 30 == 0 { saveGyroBias() }
        promptCompassRecalibrationIfFieldChanged()
        watchRendering()
        logCameraHead()
        let rate = imu?.takeSampleRate() ?? 0
        let yp = head.yawPitch
        statusLine.title = String(format: "IMU %@ %d Гц · взгляд %.0f° / %.0f° · экранов %d · FOV %.1f° · компас %@",
                                  imu?.isConnected == true ? "✓" : "✗", rate,
                                  yp.yaw * 180 / .pi, yp.pitch * 180 / .pi, scene.screens.count, renderer?.verticalFOV ?? 0,
                                  filter.magnetometerCalibration == nil ? "✗" : "✓")
        let learned = filter.gyroBias * 180 / .pi
        let compass = String(format: "ноль %.3f %.3f %.3f °/с", learned.x, learned.y, learned.z)
            + (filter.magnetometerCalibration == nil ? " · компас выкл" : String(format: " · компас расходится %.1f°", filter.compassError * 180 / .pi) + (filter.compassFieldChanged ? " · поле изменилось" : ""))
        log(statusLine.title + String(format: " · %@ · %.1f °C · предсказание %.0f мс · пересчётов нуля прошивкой отменено %d", compass,
                                      imu?.temperature ?? 0, (renderer?.headPipeline.predictionSeconds ?? 0) * 1000, filter.restoredFirmwareUpdates))
    }

    private func setupMouseTap() {
        let trusted = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        if trusted {
            startMouseTap()
        } else {
            mouseTapLine.title = "Перетаскивание мышью: нужно разрешение Accessibility"
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
            fail("Не удалось создать перехватчик событий мыши (CGEvent.tapCreate вернул nil).")
            return
        }
        mouseTap = tap
        mouseTapLine.title = "⌃⌥ + тащить — двигать экран, ⌃⌥ + скролл — ближе/дальше"
        log("mouse tap: started")
    }

    private func fail(_ message: String) {
        log("ERROR \(message)")
        statusLine.title = "Ошибка — см. окно"
        let alert = NSAlert()
        alert.messageText = "RayDesk"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

extension AppDelegate: MouseTapDelegate {
    func screenIndex(at point: CGPoint) -> Int? {
        slots.firstIndex { $0.displayBounds.contains(point) }
    }

    func gazeHit() -> GazeHit? { lastGazeHit }

    func cursorHit() -> CursorHit? { lastCursorHit }

    func cursorTarget(at point: CGPoint) -> CursorTarget? {
        if let index = screenIndex(at: point) { return .virtual(index) }
        return CGDisplayBounds(CGMainDisplayID()).contains(point) ? .mac : nil
    }

    func warpTarget(cursor: CursorTarget?) -> CursorTarget? {
        guard renderer?.meditation.isActive != true else { return nil }
        return warpPolicy.warpTarget(cursor: cursor, buttonsDown: false, at: CACurrentMediaTime())
    }

    func remappedCursor(previous: CGPoint, proposed: CGPoint, delta: CGVector) -> CGPoint? {
        guard let glassesID = glassesScreen()?.displayID else { return nil }
        var preferred: Int?
        if case .virtual(let index) = lastCursorHit?.target { preferred = index }
        return RayDeskCore.remappedCursor(previous: previous, proposed: proposed, delta: delta,
                                          panels: slots.map(\.displayBounds), main: CGDisplayBounds(CGMainDisplayID()),
                                          glasses: CGDisplayBounds(glassesID), preferredPanel: preferred)
    }

    func fencedCursor(previous: CGPoint, proposed: CGPoint) -> CGPoint? {
        guard let glassesID = glassesScreen()?.displayID else { return nil }
        return RayDeskCore.fencedCursor(previous: previous, proposed: proposed,
                                        main: CGDisplayBounds(CGMainDisplayID()), glasses: CGDisplayBounds(glassesID))
    }

    func bounds(of screen: Int) -> CGRect { slots[screen].displayBounds }

    func bounds(of target: CursorTarget) -> CGRect {
        switch target {
        case .virtual(let index): slots[index].displayBounds
        case .mac: CGDisplayBounds(CGMainDisplayID())
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

func log(_ message: String) {
    let line = "\(Date().formatted(date: .omitted, time: .standard)) \(message)\n"
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
