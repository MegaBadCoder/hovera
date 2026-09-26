import AppKit
import MetalKit
import Carbon.HIToolbox
import simd

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let placement = ScreenPlacement()
    private let filter = OrientationFilter()
    private let capture = DisplayCapture()
    private let hotkeys = Hotkeys()
    private var imu: GlassesIMU?
    private var virtualScreen: VirtualScreen?
    private var window: NSWindow?
    private var renderer: Renderer?
    private var statusItem: NSStatusItem?
    private var statusLine = NSMenuItem(title: "Запуск…", action: nil, keyEquivalent: "")
    private var followItem: NSMenuItem?
    private var statusTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        setupHotkeys()

        guard let glassesID = glassesScreen()?.displayID else {
            fail("Очки не найдены среди дисплеев. Подключите RayNeo и перезапустите.")
            return
        }

        let virtualScreen = VirtualScreen(pointWidth: 1920, pointHeight: 1080)
        self.virtualScreen = virtualScreen
        arrangeDisplays(virtualID: virtualScreen.displayID, glassesID: glassesID)

        imu = GlassesIMU(filter: filter)
        imu?.start()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.fitWindowToGlasses()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            do {
                try openGlassesWindow(aspect: Double(virtualScreen.pixelWidth) / Double(virtualScreen.pixelHeight))
            } catch {
                fail("Metal: \(error)")
                return
            }
            startCapture(virtualScreen)
            placeWhenTrackingReady()
        }

        statusTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStatus() }
    }

    private func glassesScreen() -> NSScreen? {
        NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains("SmartGlasses") || $0.localizedName.localizedCaseInsensitiveContains("RayNeo") }
    }

    private func arrangeDisplays(virtualID: CGDirectDisplayID, glassesID: CGDirectDisplayID) {
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let glassesBounds = CGDisplayBounds(glassesID)
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayOrigin(config, virtualID, Int32(mainBounds.maxX), Int32(mainBounds.minY))
        CGConfigureDisplayOrigin(config, glassesID, Int32(mainBounds.minX - glassesBounds.width), Int32(mainBounds.minY))
        let result = CGCompleteDisplayConfiguration(config, .forAppOnly)
        log("arrange displays: \(result.rawValue)")
    }

    private func startCapture(_ virtualScreen: VirtualScreen) {
        if !CGPreflightScreenCaptureAccess() {
            log("screen capture: not granted, requesting")
            CGRequestScreenCaptureAccess()
            fail("Нужно разрешение на запись экрана.\n\nСистемные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука → включите RayDesk, затем перезапустите RayDesk.\n\nПока в очках будет серый прямоугольник вместо экрана.")
            return
        }
        Task { @MainActor in
            do {
                try await capture.start(displayID: virtualScreen.displayID, width: virtualScreen.pixelWidth, height: virtualScreen.pixelHeight)
                log("capture started")
            } catch {
                fail("Захват экрана не запустился: \(error)")
            }
        }
    }

    private func placeWhenTrackingReady(attempt: Int = 0) {
        if filter.isReady {
            placeHere()
            log("placed at gaze")
        } else if attempt < 50 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.placeWhenTrackingReady(attempt: attempt + 1) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        capture.stop()
        imu?.stop()
    }

    private func openGlassesWindow(aspect: Double) throws {
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
        let renderer = try Renderer(view: view, capture: capture, filter: filter, placement: placement, screenAspect: aspect)
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

    @objc private func placeHere() { placement.place(atGaze: head) }
    @objc private func toggleGrab() { placement.toggleGrab(head: head) }
    @objc private func closer() { placement.adjustDistance(by: 1 / 1.1) }
    @objc private func farther() { placement.adjustDistance(by: 1.1) }
    @objc private func bigger() { placement.adjustWidth(by: 1.1) }
    @objc private func smaller() { placement.adjustWidth(by: 1 / 1.1) }
    @objc private func recalibrate() {
        filter.reset()
        placement.yaw = 0
        placement.pitch = 0
    }
    @objc private func toggleFollow() {
        placement.follow.toggle()
        followItem?.state = placement.follow ? .on : .off
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
        hotkeys.register(keyCode: kVK_ANSI_F) { [weak self] in self?.toggleFollow() }
        hotkeys.register(keyCode: kVK_ANSI_H) { [weak self] in self?.toggleWindow() }
        hotkeys.register(keyCode: kVK_ANSI_Q) { [weak self] in self?.quit() }
    }

    private func setupMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "RayDesk")
        let menu = NSMenu()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(menuItem("Поставить экран туда, куда смотрю   ⌃⌥Space", #selector(placeHere)))
        menu.addItem(menuItem("Взять / отпустить экран   ⌃⌥G", #selector(toggleGrab)))
        let follow = menuItem("Экран следует за головой   ⌃⌥F", #selector(toggleFollow))
        followItem = follow
        menu.addItem(follow)
        menu.addItem(.separator())
        menu.addItem(menuItem("Ближе   ⌃⌥↑", #selector(closer)))
        menu.addItem(menuItem("Дальше   ⌃⌥↓", #selector(farther)))
        menu.addItem(menuItem("Больше   ⌃⌥=", #selector(bigger)))
        menu.addItem(menuItem("Меньше   ⌃⌥−", #selector(smaller)))
        menu.addItem(.separator())
        menu.addItem(menuItem("Скрыть / показать картинку   ⌃⌥H", #selector(toggleWindow)))
        menu.addItem(menuItem("Перекалибровать гироскоп", #selector(recalibrate)))
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
        statusLine.title = String(format: "IMU %@ %d Гц · взгляд %.0f° / %.0f° · %.1f м",
                                  imu?.isConnected == true ? "✓" : "✗", rate,
                                  yp.yaw * 180 / .pi, yp.pitch * 180 / .pi, placement.distance)
        log(statusLine.title)
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
