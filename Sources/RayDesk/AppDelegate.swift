import AppKit
import MetalKit
import Carbon.HIToolbox
import ApplicationServices
import QuartzCore
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
    private var renderer: Renderer?
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

    func applicationWillTerminate(_ notification: Notification) {
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
        if let savedFOV = UserDefaults.standard.object(forKey: "verticalFOV") as? Double {
            renderer.verticalFOV = savedFOV
        }
        renderer.slots = slots
        renderer.onFrame = { [weak self] head in
            guard let self else { return }
            let hit = RayDeskCore.gazeHit(head: head, screens: scene.screens)
            lastGazeHit = hit
            warpPolicy.observeGaze(screen: hit?.screen, at: CACurrentMediaTime())
        }
        view.delegate = renderer
        window.contentView = view
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
    @objc private func gatherScreens() {
        filter.alignYawToZero()
        scene.gatherInFront(head: filter.orientation(predictAhead: 0))
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
        hotkeys.register(keyCode: kVK_UpArrow) { [weak self] in self?.closer() }
        hotkeys.register(keyCode: kVK_DownArrow) { [weak self] in self?.farther() }
        hotkeys.register(keyCode: kVK_ANSI_Equal) { [weak self] in self?.bigger() }
        hotkeys.register(keyCode: kVK_ANSI_Minus) { [weak self] in self?.smaller() }
        hotkeys.register(keyCode: kVK_ANSI_H) { [weak self] in self?.toggleWindow() }
        hotkeys.register(keyCode: kVK_ANSI_Q) { [weak self] in self?.quit() }
        hotkeys.register(keyCode: kVK_ANSI_D) { [weak self] in self?.toggleGrid() }
        hotkeys.register(keyCode: kVK_ANSI_M) { [weak self] in self?.markReference() }
        hotkeys.register(keyCode: kVK_ANSI_R) { [weak self] in self?.gatherScreens() }
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
        menu.addItem(menuItem("Всё перед собой: «вперёд» = куда смотрю   ⌃⌥R", #selector(gatherScreens)))
        menu.addItem(menuItem("Добавить экран", #selector(addScreen)))
        menu.addItem(menuItem("Убрать экран", #selector(removeScreen)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Скрыть / показать картинку   ⌃⌥H", #selector(toggleWindow)))
        menu.addItem(menuItem("Сетка горизонта   ⌃⌥D", #selector(toggleGrid)))
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
        statusLine.title = String(format: "IMU %@ %d Гц · взгляд %.0f° / %.0f° · экранов %d · FOV %.1f°",
                                  imu?.isConnected == true ? "✓" : "✗", rate,
                                  yp.yaw * 180 / .pi, yp.pitch * 180 / .pi, scene.screens.count, renderer?.verticalFOV ?? 0)
        let bias = filter.gyroBias * 180 / .pi
        log(statusLine.title + String(format: " · bias %.3f %.3f %.3f °/с · %.1f °C", bias.x, bias.y, bias.z, imu?.temperature ?? 0))
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
        warpPolicy.warpTarget(cursorScreen: cursorScreen, buttonsDown: false, at: CACurrentMediaTime())
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
