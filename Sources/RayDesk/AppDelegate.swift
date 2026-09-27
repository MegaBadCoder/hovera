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
    private var renderer: Renderer?
    private var isCalibrating = false
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
    private var lastGazeHit: GazeHit?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupHotkeys()
        setupMouseTap()

        guard glassesScreen()?.displayID != nil else {
            fail("Очки не найдены среди дисплеев. Подключите RayNeo и перезапустите.")
            return
        }

        slots = scene.screens.indices.map { ScreenSlot(index: $0) }
        saveScene()
        arrangeDisplays()

        loadCompassCalibration()
        imu = GlassesIMU(filter: filter)
        imu?.start()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.fitWindowToGlasses()
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
        if let data = UserDefaults.standard.data(forKey: "viewCalibration") {
            renderer.calibration = try JSONDecoder().decode(ViewCalibration.self, from: data)
        }
        if let savedFOV = UserDefaults.standard.object(forKey: "verticalFOV") as? Double {
            renderer.verticalFOV = savedFOV
        }
        renderer.slots = slots
        renderer.onFrame = { [weak self] head in
            guard let self else { return }
            let hit = RayDeskCore.gazeHit(head: head, screens: scene.screens)
            lastGazeHit = hit
            warpPolicy.observeGaze(target: hit.map { .virtual($0.screen) }, at: CACurrentMediaTime())
        }
        view.delegate = renderer
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        window.contentView = view
        glassesView = view
        let link = screen.displayLink(target: self, selector: #selector(renderFrame))
        link.add(to: .main, forMode: .common)
        frameLink = link
        window.orderFrontRegardless()
        self.window = window
        self.renderer = renderer
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
        log(String(format: "MARK взгляд %.1f° / %.1f°", yp.yaw * 180 / .pi, yp.pitch * 180 / .pi))
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
        log(String(format: "CORRECTION %@ yaw %.1f° since %.0f s travel %.0f° yawTravel %.0f° temp %.1f °C",
                   kind, yawDegrees, now - previous.time,
                   (travel.total - previous.travel.total) * 180 / .pi,
                   (travel.yaw - previous.travel.yaw) * 180 / .pi,
                   imu?.temperature ?? 0))
        lastCorrection = (now, travel)
    }

    private func say(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ru-RU")
        speech.speak(utterance)
        log("say: \(text)")
    }

    private func loadCompassCalibration() {
        guard let data = UserDefaults.standard.data(forKey: "magCalibration.v1") else {
            log("compass: not calibrated")
            return
        }
        filter.magnetometerCalibration = try! JSONDecoder().decode(MagnetometerCalibration.self, from: data)
        log("compass: calibration loaded")
    }

    @objc private func calibrateCompass() {
        guard !isCalibratingCompass, let imu else { return }
        isCalibratingCompass = true
        imu.startCompassCalibration()
        say("Калибровка компаса. Двадцать пять секунд медленно поворачивайте голову во все стороны: влево, вправо, вверх, вниз и к плечам.")
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.finishCompassCalibration() }
    }

    private func finishCompassCalibration() {
        isCalibratingCompass = false
        guard let fitter = imu?.finishCompassCalibration() else { return }
        do {
            let calibration = try fitter.result()
            UserDefaults.standard.set(try! JSONEncoder().encode(calibration), forKey: "magCalibration.v1")
            filter.magnetometerCalibration = calibration
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

    @objc private func disableCompass() {
        UserDefaults.standard.removeObject(forKey: "magCalibration.v1")
        filter.magnetometerCalibration = nil
        log("compass: disabled")
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
        UserDefaults.standard.set(try! JSONEncoder().encode(mount), forKey: "viewCalibration")
    }

    @objc private func recenterWorld() {
        guard let renderer else { return }
        logCorrection(kind: "recenter", yawDegrees: -renderer.currentHead.yawPitch.yaw * 180 / .pi)
        filter.alignYawToZero()
        renderer.calibration.yaw = 0
    }

    @objc private func gatherScreens() {
        guard let renderer else { return }
        scene.gatherInFront(head: renderer.currentHead)
        saveScene()
        arrangeDisplays()
    }
    @objc private func toggleGrid() {
        guard let renderer else { return }
        renderer.showsGrid.toggle()
        UserDefaults.standard.set(renderer.showsGrid, forKey: "showsGrid")
        log("grid \(renderer.showsGrid ? "on" : "off")")
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
        hotkeys.register(keyCode: kVK_ANSI_M) { [weak self] in self?.markReference() }
        hotkeys.register(keyCode: kVK_ANSI_R) { [weak self] in self?.recenterWorld() }
        hotkeys.register(keyCode: kVK_ANSI_V) { [weak self] in self?.toggleRecording() }
        hotkeys.register(keyCode: kVK_ANSI_K) { [weak self] in self?.calibrateCompass() }
        hotkeys.register(keyCode: kVK_ANSI_RightBracket) { [weak self] in self?.widerFOV() }
        hotkeys.register(keyCode: kVK_ANSI_LeftBracket) { [weak self] in self?.narrowerFOV() }
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
        menu.addItem(.separator())
        menu.addItem(menuItem("«Вперёд» = куда смотрю   ⌃⌥R", #selector(recenterWorld)))
        menu.addItem(menuItem("Собрать экраны перед собой", #selector(gatherScreens)))
        menu.addItem(menuItem("Записать видео очков (старт/стоп)   ⌃⌥V", #selector(toggleRecording)))
        menu.addItem(menuItem("Калибровка компаса   ⌃⌥K", #selector(calibrateCompass)))
        menu.addItem(menuItem("Выключить компас", #selector(disableCompass)))
        menu.addItem(menuItem("Добавить экран", #selector(addScreen)))
        menu.addItem(menuItem("Убрать экран", #selector(removeScreen)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Скрыть / показать картинку   ⌃⌥H", #selector(toggleWindow)))
        menu.addItem(menuItem("Сетка горизонта   ⌃⌥D", #selector(toggleGrid)))
        menu.addItem(menuItem("Настроить сетку вручную   ⌃⌥C (стрелки, ⌃⌥, ⌃⌥.)", #selector(toggleCalibration)))
        menu.addItem(menuItem("Угол обзора больше   ⌃⌥]", #selector(widerFOV)))
        menu.addItem(menuItem("Угол обзора меньше   ⌃⌥[", #selector(narrowerFOV)))
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
        let rate = imu?.takeSampleRate() ?? 0
        let yp = head.yawPitch
        statusLine.title = String(format: "IMU %@ %d Гц · взгляд %.0f° / %.0f° · экранов %d · FOV %.1f° · компас %@",
                                  imu?.isConnected == true ? "✓" : "✗", rate,
                                  yp.yaw * 180 / .pi, yp.pitch * 180 / .pi, scene.screens.count, renderer?.verticalFOV ?? 0,
                                  filter.magnetometerCalibration == nil ? "✗" : "✓")
        let compass = filter.magnetometerCalibration == nil ? "компас ✗" : String(format: "компас ✓ %.3f °/с", filter.verticalBias * 180 / .pi)
        log(statusLine.title + String(format: " · %@ · %.1f °C", compass, imu?.temperature ?? 0))
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

    func warpTarget(cursorScreen: Int?) -> Int? {
        guard case .virtual(let screen) = warpPolicy.warpTarget(cursor: cursorScreen.map { .virtual($0) }, buttonsDown: false, at: CACurrentMediaTime()) else { return nil }
        return screen
    }

    func bounds(of screen: Int) -> CGRect { slots[screen].displayBounds }

    func pose(of screen: Int) -> ScreenPose { scene.screens[screen] }

    func setPose(_ screen: Int, _ pose: ScreenPose) { scene.setPose(screen, pose) }

    func dragBegan(_ screen: Int) {
        renderer?.draggingScreen = screen
        log("drag began: screen \(screen + 1)")
    }

    func dragEnded() {
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
