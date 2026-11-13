import AppKit
import MetalKit
import Carbon.HIToolbox
import ApplicationServices
import QuartzCore
import AVFoundation
import simd
import RayDeskCore
import VitureSDK
import RayDeskLocalization

private let sceneDefaultsKey = "screens.v2"
private let languageDefaultsKey = "appLanguage"

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var scene = SpatialScene(screens: SpatialScene.decode(UserDefaults.standard.data(forKey: sceneDefaultsKey), default: 2, aspect: 16.0 / 9.0))
    private let filter = OrientationFilter()
    private let hotkeys = Hotkeys()
    private var imu: GlassesIMU?
    /// Трекер VITURE, если очки подключены и официальный SDK загрузился.
    private var viture: VitureTracker?
    /// Когда в следующий раз пробовать поднять трекер VITURE после неудачи или потери очков.
    private var vitureRetryAt: TimeInterval = 0
    /// Идёт попытка поднять трекер; второй параллельной попытки быть не должно.
    private var vitureStarting = false
    private var vitureStopping = false
    private var vitureGeneration = 0
    private var lensTintPolicy = LensTintPolicy()
    private var physicalMonitor: PhysicalMonitorDirection?
    private var monitorCaptureWork: DispatchWorkItem?
    private var autoTintMenuItem: NSMenuItem?
    private var terminating = false
    private var slots: [ScreenSlot] = []
    private var window: NSWindow?
    private var glassesView: MTKView?
    private var frameLink: CADisplayLink?
    /// Сколько кадров пришло без заявленного времени от дисплейного линка.
    private var missingTargetFrames = 0
    private var frameLinkDisplay: CGDirectDisplayID?
    private var frameLinkSize: CGSize = .zero
    private var screenChangeWork: DispatchWorkItem?
    private var lastRenderedFrame = CACurrentMediaTime()
    private var renderStalled = false
    private var renderer: Renderer?
    private var isSelectingFocus = false
    private var isCalibrating = false
    private var calibrationFamily: GlassesDisplayFamily?
    private var calibrationMenuItems: [NSMenuItem] = []
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
    /// Семейство очков, для которого собраны меню и строка состояния.
    ///
    /// Запоминается: когда очки отключают, меню остаётся на последнем устройстве,
    /// а не переключается на чужой набор пунктов.
    private var menuFamily: GlassesDisplayFamily?
    /// Пункты меню, которые относятся только к одному из семейств.
    private var rayNeoMenuItems: [NSMenuItem] = []
    private var vitureMenuItems: [NSMenuItem] = []
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
    private var handCamera: HandCamera?
    private var handWindow: HandPreviewWindow?
    private var handsCameraItem: NSMenuItem?
    private var lastHandsLog: TimeInterval = 0
    private static let debugObserver = "camera-debug-window"
    private static let outlineObserver = "glasses-outline-window"
    private var cameraCalibrationWindow: CameraCalibrationWindow?
    private var glassesOutlineWindow: GlassesOutlineWindow?
    private lazy var cameraHead = CameraHeadTracker(
        orientation: { [filter] uptime in (filter.orientation(atUptime: uptime), filter.isReady ? filter.angularSpeed : .infinity) }
    )
    private lazy var cameraUsage = CameraUsageController(
        start: { [weak self] completion in self?.cameraHead.start { completion($0) } },
        stop: { [weak self] in self?.cameraHead.stop() }
    )
    private var cameraCenteringRequested = false
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
    private var cameraMotionItem: NSMenuItem?
    private var didAlignSceneOnStart = false
    private var calibrationFile: FileHandle?
    private var calibrationActivity: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var calibrationItem: NSMenuItem?
    private var calibrationStarted: Date?

    private var wallModeItem: NSMenuItem?
    private var restToleranceValueLabel: NSTextField?
    private var scanoutCompensationEnabled = true
    private var scanoutBottomToTop = false
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
    /// Сколько ждать экран очков до первой жалобы в лог; дальше ждём молча.
    private static let glassesWaitLogEvery = 20

    private func waitForGlasses(attempt: Int) {
        if glassesScreen()?.displayID != nil {
            if attempt > 0 { log("glasses screen appeared after \(attempt) checks") }
            start()
            return
        }
        if attempt == 0 {
            log("glasses screen missing: waiting for it in the background")
        }
        if attempt > 0, attempt % Self.glassesWaitLogEvery == 0 {
            log("glasses screen still missing after \(Int(Double(attempt) * Self.glassesWaitStep)) s, still waiting")
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
        cameraHead.detectsCameraMotionEnabled = cameraMotionEnabled()
        log("camera motion from background \(cameraMotionEnabled() ? "on" : "off")")
        useLightGlassesMode()
        log("screens after light mode: \(screensDescription())")
        let family = connectedGlassesFamily
        slots = scene.screens.indices.map { ScreenSlot(index: $0, family: family) }
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
        loadGyroTemperatureSlope()
        // Восстановитель начинает со сдвига ноль, поэтому выученный с ним ноль к новому запуску не подходит.
        if !restoresFirmwareZero { loadGyroBias() }
        imu = GlassesIMU(filter: filter)
        cameraHead.recordsFrames = UserDefaults.standard.bool(forKey: "recordIMU")
        if UserDefaults.standard.bool(forKey: "recordIMU") {
            imu?.recorder = IMURecorder()
        }
        imu?.start()
        startVitureTracking()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.noteScreenParametersChanged()
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
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
            if UserDefaults.standard.bool(forKey: "calibrationAutoStart") {
                startCalibrationSession()
            }
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
        NSScreen.screens.first { RayDeskCore.glassesDisplayFamily(forDisplayName: $0.localizedName) != nil }
    }

    /// Семейство очков, которые сейчас работают: USB, HID и имя дисплея как запасной признак.
    private var connectedGlassesFamily: GlassesDisplayFamily? {
        RayDeskCore.activeGlassesFamily(vitureConnected: !VitureUSB.connectedDevices().isEmpty,
                                        rayNeoConnected: imu?.isConnected == true,
                                        displayName: glassesScreen()?.localizedName)
    }

    private func useLightGlassesMode() {
        guard let screen = glassesScreen(),
              let family = RayDeskCore.glassesDisplayFamily(forDisplayName: screen.localizedName),
              let id = screen.displayID,
              let current = CGDisplayCopyDisplayMode(id) else { return }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let candidates = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []).map { mode in
            (option: DisplayModeOption(pointWidth: mode.width, pointHeight: mode.height,
                                       pixelWidth: mode.pixelWidth, pixelHeight: mode.pixelHeight,
                                       refreshRate: mode.refreshRate, usableForDesktop: mode.isUsableForDesktopGUI()),
             mode: mode)
        }
        guard let chosen = chooseGlassesDisplayMode(candidates.map(\.option), family: family),
              let target = candidates.first(where: { $0.option == chosen })?.mode else {
            log("glasses display: no plain mode for \(family.rawValue)")
            return
        }
        guard current.pixelWidth != target.pixelWidth || current.pixelHeight != target.pixelHeight
                || abs(current.refreshRate - target.refreshRate) > 0.5 else { return }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, id, target, nil)
        let result = CGCompleteDisplayConfiguration(config, .forSession)
        log(String(format: "glasses display (\(family.rawValue)): %dx%d pixels @%.0f Hz -> %dx%d @%.0f Hz (%d)",
                   current.pixelWidth, current.pixelHeight, current.refreshRate,
                   target.pixelWidth, target.pixelHeight, target.refreshRate, result.rawValue))
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
        if let target = frameLink?.targetTimestamp, target > 0 {
            renderer?.nextTargetTime = target
        } else {
            missingTargetFrames += 1
            if missingTargetFrames % 300 == 1 {
                log("display link: no targetTimestamp, the frame time falls back to now + one frame")
            }
        }
        if let glassesView, let renderer {
            renderer.draw(in: glassesView)
        }
    }

    /// Пробует поднять трекер VITURE в фоне: SDK грузит VIO и может занять сотни миллисекунд.
    private func startVitureTracking() {
        guard !vitureStarting, !vitureStopping, !terminating, viture == nil else { return }
        guard VitureUSB.connectedDevices().contains(where: { $0.productID == 0x1104 }) else { return }
        vitureStarting = true
        let generation = vitureGeneration
        let poseMode = savedViturePoseMode()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try VitureTracker.start(poseMode: poseMode) }
            DispatchQueue.main.async {
                guard let self else {
                    if case .success(let tracker) = result { tracker?.stop() }
                    return
                }
                self.vitureStarting = false
                guard generation == self.vitureGeneration, !self.terminating else {
                    if case .success(let tracker?) = result { self.stopVitureTracking(tracker) }
                    return
                }
                switch result {
                case .success(let tracker?):
                    self.viture = tracker
                    self.lensTintPolicy = LensTintPolicy()
                    self.physicalMonitor = nil
                    self.didAlignSceneOnStart = false
                    log(String(format: "VITURE: трекер запущен (%@, product id 0x%04X)",
                               tracker.productName ?? "модель неизвестна", tracker.productID))
                    log("VITURE: источник позы \(tracker.poseMode.rawValue)")
                    self.installViturePose()
                case .success(nil):
                    self.vitureRetryAt = CACurrentMediaTime() + 1
                    log("VITURE: очки исчезли во время запуска, повторю после подключения")
                case .failure(let error):
                    self.vitureRetryAt = CACurrentMediaTime() + 3
                    log("VITURE: трекер не запустился — \(error)")
                }
            }
        }
    }

    private func stopVitureTracking(_ tracker: VitureTracker) {
        vitureStopping = true
        monitorCaptureWork?.cancel()
        monitorCaptureWork = nil
        if viture === tracker {
            viture = nil
            renderer?.externalPose = nil
            renderer?.independentSource = nil
            renderer?.suspendsIndependentScene = false
        }
        tracker.stop { [weak self] in
            DispatchQueue.main.async {
                self?.vitureStopping = false
                self?.vitureRetryAt = CACurrentMediaTime() + 1
            }
        }
    }

    private func watchVitureTracking() {
        if let viture {
            if !viture.isConnected || viture.shouldRestart {
                log("VITURE: нет свежей позы или USB-подключения, перезапускаю трекер")
                stopVitureTracking(viture)
            }
            return
        }
        guard CACurrentMediaTime() >= vitureRetryAt else { return }
        startVitureTracking()
    }

    /// Ставит начало координат VITURE так, чтобы центр раскладки был прямо перед взглядом.
    ///
    /// Экранные позы при этом не меняются: поворот живёт в опоре трекинга, поэтому
    /// сохранённые углы раскладки не копят сдвиг от запуска к запуску.
    private func alignVitureOrigin() {
        guard let viture, let pose = viture.pose(predictTime: 0) else { return }
        // reset_origin ставит опору в переданную позу, поэтому относительный курс
        // становится равен минус повороту: чтобы взгляд смотрел в центр раскладки,
        // опору надо развернуть на минус этот центр.
        let delta = remainder(-scene.centerYaw, 2 * .pi)
        let origin = pose.rotatedYaw(by: delta)
        renderer?.suspendsIndependentScene = true
        viture.resetOrigin(to: origin) { [weak self, weak viture] success in
            DispatchQueue.main.async {
                guard let self, let viture, self.viture === viture else { return }
                self.renderer?.suspendsIndependentScene = false
                if success {
                    self.renderer?.calibration.yaw = 0
                    self.physicalMonitor?.yaw -= origin.orientation.yawPitch.yaw
                    self.lensTintPolicy = LensTintPolicy()
                    log("VITURE: опора мира обновлена")
                } else {
                    log("VITURE: не удалось обновить опору мира")
                }
            }
        }
    }

    /// Сдвиг картинки по положению головы из VIO.
    ///
    /// По умолчанию выключен: VIO на неподвижной голове гуляет на сантиметры,
    /// и вся сцена начинает «плавать». Включается флагом `vitureSixDofPosition`,
    /// когда нужен настоящий параллакс.
    private var usesSixDofPosition: Bool {
        UserDefaults.standard.bool(forKey: "vitureSixDofPosition")
    }

    /// Отдаёт рендеру позу VITURE с предсказанием к моменту показа кадра.
    private func installViturePose() {
        if let renderer, calibrationFamily != .viture {
            restoreViewCalibration(renderer, family: .viture)
        }
        if let viture { renderer?.independentSource = .viture(viture) }
        renderer?.externalPose = { [weak self] presentTime in
            guard let self, let viture = self.viture else { return nil }
            let predictTime = max(0, min(0.05, presentTime - CACurrentMediaTime()))
            guard let sample = viture.poseSample(predictTime: predictTime) else { return nil }
            return (sample.pose.orientation, usesSixDofPosition ? sample.pose.position : .zero, sample.predictionHorizon)
        }
        log("VITURE: внешняя поза (ориентация и положение) установлена в рендер")
    }

    /// Пишет в лог позу VITURE и останавливает трекер, если очки отключились.
    private func logViturePose() {
        watchVitureTracking()
        guard let viture else { return }
        guard let pose = viture.pose() else {
            log("VITURE: SDK не отдаёт позу")
            return
        }
        let yawPitch = pose.orientation.yawPitch
        let roll = atan2(2 * (pose.orientation.real * pose.orientation.imag.z + pose.orientation.imag.x * pose.orientation.imag.y),
                         1 - 2 * (pose.orientation.imag.y * pose.orientation.imag.y + pose.orientation.imag.z * pose.orientation.imag.z))
        log(String(format: "VITURE pose: yaw %+.1f° pitch %+.1f° roll %+.1f° · позиция %+.2f %+.2f %+.2f м · %@ · в рендере %@ · ошибок чтения позы %d",
                   yawPitch.yaw * 180 / .pi, yawPitch.pitch * 180 / .pi, roll * 180 / .pi,
                   pose.position.x, pose.position.y, pose.position.z,
                   pose.isStable ? "стабильна" : "нестабильна",
                   renderer?.usedExternalOrientation == true ? "да" : "нет",
                   viture.predictionFailureCount))
        if let imu = viture.latestIMU {
            log(String(format: "VITURE imu: a %+.2f %+.2f %+.2f · ω %+.3f %+.3f %+.3f · %.3f с",
                       imu.acceleration.x, imu.acceleration.y, imu.acceleration.z,
                       imu.angularVelocity.x, imu.angularVelocity.y, imu.angularVelocity.z, imu.time))
        }
        let bias = viture.gyroBias * 180 / .pi
        log(String(format: "VITURE fusion: ноль ω %+.2f %+.2f %+.2f °/с", bias.x, bias.y, bias.z))
        if let drift = viture.driftPerMinute {
            log(String(format: "VITURE увод мира за %.0f с покоя: yaw %+.2f · pitch %+.2f · roll %+.2f °/мин",
                       viture.driftSpan, drift.yaw, drift.pitch, drift.roll))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminating = true
        cameraUsage.stopAll()
        vitureGeneration += 1
        if let viture {
            let done = DispatchSemaphore(value: 0)
            viture.stop { done.signal() }
            _ = done.wait(timeout: .now() + 2)
        }
        viture = nil
        handCamera?.stop()
        handCamera = nil
        calibrationFile?.closeFile()
        calibrationFile = nil
        frameLink?.invalidate()
        renderer?.stopIndependentReprojection()
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
        renderer.screenTextMode = savedScreenTextMode()
        log("screen text mode: \(renderer.screenTextMode.rawValue)")
        restoreViewCalibration(renderer, family: connectedGlassesFamily)
        renderer.verticalFOV = savedVerticalFOV()
        log(String(format: "display projection: vertical FOV %.6f°", renderer.verticalFOV))
        renderer.slots = slots
        renderer.stabilizer.level = savedStabilization()
        renderer.worldLockedPresentation = savedWorldLockedPresentation()
        renderer.worldLockSmoothing = savedWorldLockSmoothing()
        renderer.adaptiveVSync = savedAdaptiveVSync()
        renderer.restSmoothing = savedRestSmoothing()
        renderer.restStrength = savedRestStrength()
        renderer.restTolerance = savedRestTolerance()
        renderer.scanoutEnabled = scanoutCompensationEnabled
        renderer.scanoutBottomToTop = scanoutBottomToTop
        renderer.showsRestIndicator = savedRestIndicator()
        log("rotational world lock: \(renderer.worldLockedPresentation ? "on" : "off")")
        log("world lock light smoothing: \(renderer.worldLockSmoothing ? "on" : "off")")
        log("adaptive vsync: \(renderer.adaptiveVSync ? "on" : "off")")
        log("world lock rest smoothing: \(renderer.restSmoothing && !renderer.adaptiveVSync ? "on" : "off") · strength \(renderer.restStrength.rawValue) · tolerance \(renderer.restTolerance) · indicator \(renderer.showsRestIndicator)")
        if let savedPrediction = UserDefaults.standard.object(forKey: "predictionMs") as? Double {
            renderer.headPipeline.predictionSeconds = savedPrediction / 1000
            renderer.headPipeline.predictionBias = savedPrediction / 1000 - HeadPipeline.defaultPredictionSeconds
        }
        renderer.adaptivePrediction = UserDefaults.standard.bool(forKey: "adaptivePrediction")
        renderer.breathingEnabled = UserDefaults.standard.bool(forKey: "meditationBreathing")
        renderer.onFrame = { [weak self] head in
            guard let self else { return }
            updatePointerTargets(head: head)
            self.alignSceneOnStart(head: head)
            self.updateLensTint(head: head)
            guard self.renderer?.meditation.isActive != true else { return }
            warpPolicy.observeGaze(target: lastCursorHit?.target, at: CACurrentMediaTime())
        }
        view.delegate = nil
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        window.contentView = view
        glassesView = view
        window.orderFrontRegardless()
        self.window = window
        self.renderer?.stopIndependentReprojection()
        self.renderer = renderer
        if viture != nil {
            installViturePose()
        }
        try renderer.startIndependentReprojection(view: view, framesPerSecond: screen.maximumFramesPerSecond)
        log("independent reprojection: started at \(screen.maximumFramesPerSecond) Hz")
        restartFrameLink()
        scheduleReprojectionDelayCheck()
        syncCameraCentering(force: true)
        if cameraCenteringRequested, glassesTracking, !UserDefaults.standard.bool(forKey: "guidedCalibrationIntroduced") {
            UserDefaults.standard.set(true, forKey: "guidedCalibrationIntroduced")
            Task { @MainActor [weak self] in self?.startCameraCalibration() }
        }
    }

    private func scheduleReprojectionDelayCheck() {
        guard ProcessInfo.processInfo.environment["HOVERA_ATW_DELAY_CHECK"] == "1" else { return }
        for index in 0..<5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6 + Double(index) * 2) { [weak self] in
                guard let presenter = self?.renderer?.independentReprojection else { return }
                let before = presenter.snapshot
                let started = CACurrentMediaTime()
                Thread.sleep(forTimeInterval: 0.2)
                let after = presenter.snapshot
                log(String(format: "ATW DELAY CHECK %d main=%.1fms presented=%d reused=%d errors=%d",
                           index + 1, (CACurrentMediaTime() - started) * 1000,
                           after.presented - before.presented, after.reused - before.reused,
                           after.failed - before.failed))
            }
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

    /// После пробуждения дисплей очков может вернуться позже остальных: ждём его и пересобираем окно.
    private func handleWake() {
        log("wake: screens \(screensDescription())")
        vitureGeneration += 1
        if let viture { stopVitureTracking(viture) }
        renderer?.externalPose = nil
        vitureRetryAt = CACurrentMediaTime() + 2
        if !VitureUSB.connectedDevices().isEmpty {
            log("VITURE: после пробуждения трекер будет перезапущен")
        }
        screenParametersSettled()
        waitForGlassesAfterWake(attempt: 0)
    }

    private func waitForGlassesAfterWake(attempt: Int) {
        guard attempt < 20 else {
            log("wake: glasses screen did not return")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if self.glassesScreen() != nil {
                self.screenParametersSettled()
                log("wake: glasses screen is back")
            } else {
                self.waitForGlassesAfterWake(attempt: attempt + 1)
            }
        }
    }

    private func screenParametersSettled() {
        let started = CACurrentMediaTime()
        useLightGlassesMode()
        if let family = connectedGlassesFamily {
            for slot in slots { slot.virtualScreen.updateRefreshRate(family: family) }
            if let renderer, calibrationFamily != family { restoreViewCalibration(renderer, family: family) }
        }
        fitWindowToGlasses()
        restartFrameLink()
        syncCameraCentering()
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
    private var headOrigin: SIMD3<Double> { renderer?.currentHeadOffset ?? .zero }

    private func targetScreen() -> Int {
        scene.focus?.screen ?? RayDeskCore.gazeHit(head: head, screens: scene.screens, origin: headOrigin)?.screen ?? scene.screens.count - 1
    }

    private func saveScene() {
        setFocusSelection(false)
        UserDefaults.standard.set(scene.encoded(), forKey: sceneDefaultsKey)
    }

    private func updatePointerTargets(head: simd_quatd) {
        if let focus = scene.focus {
            lastGazeHit = focus.hit(head: head, origin: headOrigin)
            lastCursorHit = lastGazeHit.map { CursorHit(target: .virtual($0.screen), uv: $0.uv) }
        } else {
            lastGazeHit = RayDeskCore.gazeHit(head: head, screens: scene.screens, origin: headOrigin)
            var hit = RayDeskCore.cursorHit(head: head, screens: scene.screens, origin: headOrigin)
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
        guard let target = RayDeskCore.gazeHit(head: head, screens: scene.screens, origin: headOrigin)?.screen else { return }
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
        if let hit = RayDeskCore.gazeHit(head: head, screens: scene.screens, origin: headOrigin) { return hit.screen }
        let gaze = head.yawPitch
        return scene.screens.indices.min {
            angularGap(scene.screens[$0], gaze) < angularGap(scene.screens[$1], gaze)
        } ?? 0
    }

    private func angularGap(_ pose: ScreenPose, _ gaze: (yaw: Double, pitch: Double)) -> Double {
        let relativeCenter = pose.center - headOrigin
        let yaw = atan2(-relativeCenter.x, -relativeCenter.z)
        let pitch = atan2(relativeCenter.y, hypot(relativeCenter.x, relativeCenter.z))
        return hypot(atan2(sin(yaw - gaze.yaw), cos(yaw - gaze.yaw)), pitch - gaze.pitch)
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
        renderer?.suspendsIndependentScene = true
        filter.reset()
        renderer?.suspendsIndependentScene = false
    }

    @objc private func addScreen() {
        guard scene.addScreen(head: head) else {
            log("add screen: already at maximum")
            return
        }
        let slot = ScreenSlot(index: slots.count, family: connectedGlassesFamily)
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
        for item in calibrationMenuItems { item.state = isCalibrating ? .on : .off }
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

    /// Наклон нуля по температуре из калибровочной сессии: он убирает уход при прогреве.
    private func loadGyroTemperatureSlope() {
        let raw = UserDefaults.standard.array(forKey: "gyroBiasSlope.v1") ?? []
        let values = raw.compactMap { value -> Double? in
            if let number = value as? NSNumber { return number.doubleValue }
            if let text = value as? String { return Double(text) }
            return nil
        }
        guard values.count == 3 else {
            log("gyro temperature slope: not calibrated")
            return
        }
        filter.biasTemperatureSlope = SIMD3(values[0], values[1], values[2]) * .pi / 180
        log(String(format: "gyro temperature slope: %.4f %.4f %.4f °/s на °C", values[0], values[1], values[2]))
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

    private func restoreViewCalibration(_ renderer: Renderer, family: GlassesDisplayFamily?) {
        calibrationFamily = family
        let key = family == .viture ? "vitureViewCalibration" : "viewCalibration"
        renderer.calibration = loadSetting(ViewCalibration.self, key: key, name: t(.settingGrid)) ?? ViewCalibration()
    }

    private func saveCalibration() {
        guard let renderer else { return }
        let mount = ViewCalibration(yaw: 0, pitch: renderer.calibration.pitch, roll: renderer.calibration.roll)
        let key = calibrationFamily == .viture ? "vitureViewCalibration" : "viewCalibration"
        saveSetting(mount, key: key)
    }

    /// Ставит «вперёд» туда, куда смотрю: без запомненной точки MacBook и без маркера.
    /// На старте мир инициализируется с нуля, а экраны лежат в нём со старыми углами:
    /// поворачиваем мир так, чтобы центр раскладки оказался перед глазами, и не приходится
    /// ловить его кнопкой возврата.
    private func alignSceneOnStart(head: simd_quatd) {
        guard !didAlignSceneOnStart else { return }
        guard viture == nil || renderer?.usedExternalOrientation == true else { return }
        didAlignSceneOnStart = true
        guard !scene.screens.isEmpty else { return }
        let center = scene.centerYaw
        let delta = remainder(center - head.yawPitch.yaw, 2 * .pi)
        if renderer?.externalPose != nil {
            alignVitureOrigin()
            log(String(format: "startup alignment (VITURE): scene center %.0f°, head %.0f°",
                       center * 180 / .pi, head.yawPitch.yaw * 180 / .pi))
            return
        }
        guard abs(delta) > 2 * .pi / 180 else { return }
        renderer?.suspendsIndependentScene = true
        filter.rotateWorldYaw(by: delta)
        renderer?.suspendsIndependentScene = false
        if renderer?.headOffset != nil {
            cameraHead.worldYawChanged(by: delta)
            if glassesTracking { cameraHead.resetReference(after: 0.3) }
        }
        log(String(format: "startup alignment: scene center %.0f°, head %.0f°, world turned %.0f°",
                   center * 180 / .pi, head.yawPitch.yaw * 180 / .pi, delta * 180 / .pi))
    }

    @objc private func recenterToGaze() {
        guard let renderer else { return }
        if viture != nil {
            alignVitureOrigin()
            log("VITURE: запрошен перенос опоры по текущему взгляду")
            return
        }
        let yaw = filter.orientation(predictAhead: 0).yawPitch.yaw
        logCorrection(kind: "recenter", yawDegrees: -renderer.currentHead.yawPitch.yaw * 180 / .pi)
        renderer.suspendsIndependentScene = true
        filter.alignYawToZero()
        renderer.suspendsIndependentScene = false
        renderer.calibration.yaw = 0
        if renderer.headOffset != nil {
            cameraHead.worldYawChanged(by: -yaw)
            if glassesTracking { cameraHead.resetReference(after: 0.3) }
        }
    }

    @objc private func toggleHandsCamera(_ sender: NSMenuItem) {
        if handCamera != nil {
            stopHandsCamera()
            return
        }
        let camera = HandCamera()
        camera.onFrame = { [weak self] frame in
            guard let self, self.handCamera != nil else { return }
            self.showHandsWindow()
            handWindow?.update(frame: frame, framesPerSecond: handCamera?.framesPerSecond ?? 0)
            let now = CACurrentMediaTime()
            if now - lastHandsLog > 5 {
                lastHandsLog = now
                log(String(format: "hands: %.1f к/с · рук %d · кадр %d×%d", handCamera?.framesPerSecond ?? 0,
                           frame.hands.count, frame.width, frame.height))
            }
        }
        do {
            try camera.start()
        } catch {
            log("hands camera: \(error.localizedDescription)")
            return
        }
        handCamera = camera
        handsCameraItem?.state = .on
        log("hands camera on: \(camera.deviceName)")
    }

    /// Показывает превью камеры очков; закрытие окна останавливает камеру.
    private func showHandsWindow() {
        if handWindow == nil {
            let window = HandPreviewWindow()
            window.onClose = { [weak self] in
                guard let self else { return }
                handWindow = nil
                stopHandsCamera()
            }
            handWindow = window
        }
        if handWindow?.isVisible != true {
            handWindow?.orderFront(nil)
        }
    }

    /// Останавливает камеру очков и убирает превью: пункт меню и окно возвращаются в выключенное состояние.
    private func stopHandsCamera() {
        guard handCamera != nil || handWindow != nil else { return }
        handCamera?.stop()
        handCamera = nil
        handsCameraItem?.state = .off
        let window = handWindow
        handWindow = nil
        window?.close()
        log("hands camera off")
    }

    @MainActor @objc private func startCameraCalibration() {
        if let window = cameraCalibrationWindow { window.show(); return }
        guard !cameraUsage.isRequested(.calibration) else { return }
        let wasGlassesTracking = glassesTracking
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
                    UserDefaults.standard.set(true, forKey: "wallMode")
                    cameraHead.observeCalibration(nil)
                    cameraCalibrationWindow = nil
                    syncCameraCentering(force: true)
                    cameraUsage.release(.calibration)
                    signal(t(.signalCalibrationDone), symbol: "checkmark.circle", seconds: 6)
                }, cancel: { [weak self] in
                    self?.cameraHead.cancelGuidedCalibration()
                    self?.cameraHead.observeCalibration(nil)
                    self?.cameraCalibrationWindow = nil
                    if !wasGlassesTracking { self?.setGlassesTracking(false) }
                    self?.cameraUsage.release(.calibration)
                })
            cameraCalibrationWindow = window
            cameraHead.observeCalibration { [weak window] observation in window?.update(observation) }
            window.show()
        }
        cameraUsage.request(.calibration) { [weak self] error in
            guard error == nil else {
                self?.cameraUsage.release(.calibration)
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
            guard let self, learningGlasses, cameraUsage.isRequested(.learning) else { return }
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
        cameraUsage.request(.learning) { [weak self] error in
            if let error {
                self?.cameraUsage.release(.learning)
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
        cameraUsage.release(.learning)
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
        if cameraUsage.isRequested(.debug) {
            cameraDebugWindow?.close()
            cameraHead.removeObserver(Self.debugObserver)
            cameraUsage.release(.debug)
            sender.state = .off
            log("camera debug window off")
            return
        }
        let open = { [weak self] in
            guard let self else { return }
            let display: CGDirectDisplayID? = slots.isEmpty ? nil : slots[targetScreen()].displayID
            let screen = NSScreen.screens.first { $0.displayID == display }
            let window = CameraDebugWindow(session: cameraHead.captureSession, on: screen)
            window.onClose = { [weak self, weak sender] in
                guard let self else { return }
                cameraHead.removeObserver(Self.debugObserver)
                cameraDebugWindow = nil
                cameraUsage.release(.debug)
                sender?.state = .off
            }
            cameraDebugWindow = window
            cameraHead.addObserver(Self.debugObserver) { [weak window] observation in window?.update(observation) }
            window.show()
            sender.state = .on
            log("camera debug window on")
        }
        cameraUsage.request(.debug) { [weak self] error in
            if let error {
                self?.cameraUsage.release(.debug)
                log("camera head tracking failed: \(error)")
                self?.signal(t(.signalCameraUnavailablePrivacy), symbol: "video.slash", seconds: 10)
                return
            }
            log("camera head tracking on")
            open()
        }
    }

    /// Сравнивать ли кадры фона, чтобы ловить поездку ноутбука.
    private func cameraMotionEnabled() -> Bool {
        UserDefaults.standard.object(forKey: "cameraMotion") as? Bool ?? false
    }

    /// Начинает и останавливает запись калибровочной сессии: раз в секунду температура, ноль,
    /// поправка восстановителя и скорость головы — по ним строится таблица ноль(T).
    @objc private func toggleCalibrationSession(_ sender: NSMenuItem) {
        if calibrationFile != nil {
            stopCalibrationSession()
            sender.state = .off
            return
        }
        if startCalibrationSession() {
            sender.state = .on
        }
    }

    @discardableResult
    private func startCalibrationSession() -> Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RayDesk-imu")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("calibration-\(Int(Date().timeIntervalSinceReferenceDate)).csv")
        FileManager.default.createFile(atPath: url.path, contents: "time,temp,biasX,biasY,biasZ,shiftX,shiftY,shiftZ,speed,compassError,restored\n".data(using: .utf8))
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        handle.seekToEndOfFile()
        calibrationFile = handle
        calibrationStarted = Date()
        calibrationActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "calibration session")
        calibrationItem?.state = .on
        signal(String(format: t(.signalCalibrationStarted), url.lastPathComponent), symbol: "waveform.path.ecg", seconds: 10)
        log("calibration session: \(url.path)")
        return true
    }

    private func stopCalibrationSession() {
        UserDefaults.standard.set(false, forKey: "calibrationAutoStart")
        calibrationFile?.closeFile()
        calibrationFile = nil
        if let calibrationActivity {
            ProcessInfo.processInfo.endActivity(calibrationActivity)
            self.calibrationActivity = nil
        }
        calibrationStarted = nil
        calibrationItem?.state = .off
        signal(t(.signalCalibrationStopped), symbol: "waveform.path.ecg", seconds: 6)
    }

    private func writeCalibrationRow() {
        guard let calibrationFile, let started = calibrationStarted else { return }
        if Date().timeIntervalSince(started) > 5400 {
            stopCalibrationSession()
            return
        }
        let bias = filter.gyroBias * 180 / .pi
        let shift = filter.firmwareZeroShift * 180 / .pi
        let line = String(format: "%.3f,%.2f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.3f,%.1f,%d\n",
                          Date().timeIntervalSinceReferenceDate, imu?.temperature ?? .nan,
                          bias.x, bias.y, bias.z, shift.x, shift.y, shift.z,
                          filter.angularSpeed * 180 / .pi, filter.compassError * 180 / .pi,
                          filter.restoredFirmwareUpdates)
        calibrationFile.write(line.data(using: .utf8) ?? Data())
    }

    @objc private func toggleCameraMotion(_ sender: NSMenuItem) {
        let enabled = !cameraMotionEnabled()
        UserDefaults.standard.set(enabled, forKey: "cameraMotion")
        cameraHead.detectsCameraMotionEnabled = enabled
        sender.state = enabled ? .on : .off
        log("camera motion from background \(enabled)")
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

    private func syncCameraCentering(force: Bool = false) {
        let needed = !terminating && CameraUsageController.needsCentering(
            family: connectedGlassesFamily,
            visible: window?.isVisible == true && renderer != nil,
            enabled: UserDefaults.standard.bool(forKey: "wallMode")
        )
        guard force || needed != cameraCenteringRequested else { return }
        cameraCenteringRequested = needed
        guard needed else {
            renderer?.headOffset = nil
            wallModeItem?.state = .off
            cameraUsage.release(.centering)
            log("camera centering off")
            return
        }
        wallModeItem?.state = .on
        cameraUsage.request(.centering) { [weak self] error in
            guard let self, cameraCenteringRequested else { return }
            if let error {
                log("camera head tracking failed: \(error)")
                wallModeItem?.state = .off
                signal(t(.signalCameraUnavailablePrivacy), symbol: "video.slash", seconds: 10)
                return
            }
            guard let renderer else { return }
            cameraHead.resetReference(after: 0.3)
            installCameraHeadOffset(renderer)
            wallModeItem?.state = .on
            signal(glassesTracking ? t(.signalWallModeGlasses) : t(.signalWallModeFace), symbol: "rectangle.on.rectangle", seconds: 6)
            log("wall mode on")
        }
    }

    @objc private func toggleWallMode(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.state != .on, forKey: "wallMode")
        syncCameraCentering(force: true)
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
        cameraUsage.request(.learning) { [weak self] error in
            if let error {
                self?.cameraUsage.release(.learning)
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

    private var automaticLensTint: Bool {
        UserDefaults.standard.object(forKey: "vitureAutomaticLensTint") as? Bool ?? true
    }

    private func updateLensTint(head: simd_quatd) {
        guard automaticLensTint, let viture, viture.supportsFilmControl else { return }
        guard renderer?.usedExternalOrientation == true, (viture.poseAge ?? .infinity) < 0.15 else {
            _ = lensTintPolicy.update(target: nil, time: CACurrentMediaTime())
            return
        }
        let target: CursorTarget?
        if renderer?.meditation.isActive == true {
            target = .virtual(0)
        } else if lastGazeHit == nil, let rawHead = viture.pose()?.orientation, physicalMonitor?.contains(head: rawHead) == true {
            target = .mac
        } else {
            target = lastCursorHit?.target
        }
        if let darkened = lensTintPolicy.update(target: target, time: CACurrentMediaTime()) {
            viture.setLensTint(darkened)
        }
    }

    @objc private func toggleAutomaticLensTint(_ sender: NSMenuItem) {
        let enabled = !automaticLensTint
        UserDefaults.standard.set(enabled, forKey: "vitureAutomaticLensTint")
        sender.state = enabled ? .on : .off
        lensTintPolicy = LensTintPolicy()
        if !enabled { viture?.setLensTint(nil) }
    }

    @objc private func rememberPhysicalMonitor() {
        monitorCaptureWork?.cancel()
        let generation = vitureGeneration
        let tracker = viture
        let work = DispatchWorkItem { [weak self, weak tracker] in
            guard let self, let tracker, self.viture === tracker, self.vitureGeneration == generation,
                  self.renderer?.usedExternalOrientation == true,
                  (tracker.poseAge ?? .infinity) < 0.15 else { return }
            guard let rawPose = tracker.pose() else { return }
            let direction = rawPose.orientation.yawPitch
            self.physicalMonitor = PhysicalMonitorDirection(yaw: direction.yaw, pitch: direction.pitch)
            self.lensTintPolicy = LensTintPolicy()
            self.monitorCaptureWork = nil
            NSSound(named: "Tink")?.play()
            log("VITURE: направление на физический монитор запомнено")
        }
        monitorCaptureWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    @objc private func forgetPhysicalMonitor() {
        monitorCaptureWork?.cancel()
        monitorCaptureWork = nil
        physicalMonitor = nil
        lensTintPolicy = LensTintPolicy()
        viture?.setLensTint(nil)
    }

    private var vitureExtrapolation: Bool {
        UserDefaults.standard.object(forKey: "vitureExtrapolation") as? Bool ?? true
    }

    private func savedViturePoseMode() -> ViturePoseMode {
        UserDefaults.standard.string(forKey: "viturePoseMode").flatMap(ViturePoseMode.init(rawValue:)) ?? .callback
    }

    @objc private func toggleVitureCallbackPose(_ sender: NSMenuItem) {
        let mode: ViturePoseMode = savedViturePoseMode() == .callback ? .polling : .callback
        UserDefaults.standard.set(mode.rawValue, forKey: "viturePoseMode")
        sender.state = mode == .callback ? .on : .off
        vitureGeneration += 1
        if let viture { stopVitureTracking(viture) }
        log("VITURE: выбран источник позы \(mode.rawValue), перезапускаю трекер")
    }

    @objc private func toggleVitureSixDof(_ sender: NSMenuItem) {
        let enabled = !UserDefaults.standard.bool(forKey: "vitureSixDofPosition")
        UserDefaults.standard.set(enabled, forKey: "vitureSixDofPosition")
        sender.state = enabled ? .on : .off
        log("VITURE: положение головы по 6DoF \(enabled ? "вкл" : "выкл")")
    }

    @objc private func toggleVitureExtrapolation(_ sender: NSMenuItem) {
        let enabled = !vitureExtrapolation
        UserDefaults.standard.set(enabled, forKey: "vitureExtrapolation")
        viture?.usesExtrapolation = enabled
        sender.state = enabled ? .on : .off
        log("VITURE: экстраполяция позы \(enabled ? "вкл" : "выкл")")
    }

    @objc private func toggleVitureGyroFusion(_ sender: NSMenuItem) {
        let enabled = !UserDefaults.standard.bool(forKey: "vitureGyroFusion")
        UserDefaults.standard.set(enabled, forKey: "vitureGyroFusion")
        viture?.usesFusion = enabled
        sender.state = enabled ? .on : .off
        log("VITURE: гироскопное слияние \(enabled ? "вкл" : "выкл")")
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
        guard renderer != nil, let anchor = gazedScreen else { NSSound.beep(); return }
        scene.arrangeInArc(around: anchor, join: savedJoin())
        saveScene()
        arrangeDisplays()
        log("screens arranged around screen \(anchor + 1)")
    }

    private var gazedScreen: Int? {
        scene.focus?.screen ?? RayDeskCore.gazeHit(head: head, screens: scene.screens, origin: headOrigin)?.screen
    }

    @objc private func rollLeft() {
        rotateTargetInPlane(by: .pi / 180)
    }

    @objc private func rollRight() {
        rotateTargetInPlane(by: -.pi / 180)
    }

    private func rotateTargetInPlane(by angle: Double) {
        guard renderer != nil, let index = gazedScreen else { NSSound.beep(); return }
        scene.rotateInPlane(index, by: angle)
        saveScene()
        log(String(format: "screen %d rotated in plane by %.0f°", index + 1, angle * 180 / .pi))
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

    private func turnAll(by angle: Double) {
        scene.rotateWorld(by: angle)
        saveScene()
        log(String(format: "layout pan %.0f°", scene.centerYaw * 180 / .pi))
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

    private func savedWorldLockedPresentation() -> Bool {
        UserDefaults.standard.object(forKey: "worldLockedPresentation") as? Bool ?? true
    }

    private func savedWorldLockSmoothing() -> Bool {
        UserDefaults.standard.object(forKey: "worldLockSmoothing") as? Bool ?? true
    }

    private func savedAdaptiveVSync() -> Bool {
        UserDefaults.standard.object(forKey: "adaptiveVSync") as? Bool ?? false
    }

    @objc private func toggleAdaptiveVSync(_ sender: NSMenuItem) {
        let enabled = !savedAdaptiveVSync()
        UserDefaults.standard.set(enabled, forKey: "adaptiveVSync")
        renderer?.adaptiveVSync = enabled
        sender.state = enabled ? .on : .off
        log("adaptive vsync: \(enabled ? "on" : "off")")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            statusItem?.menu = buildMenu()
        }
    }

    private func savedRestSmoothing() -> Bool {
        UserDefaults.standard.object(forKey: "restSmoothing") as? Bool ?? true
    }

    @objc private func toggleScanoutCompensation(_ sender: NSMenuItem) {
        scanoutCompensationEnabled.toggle()
        renderer?.scanoutEnabled = scanoutCompensationEnabled
        sender.state = scanoutCompensationEnabled ? .on : .off
        log("scanout compensation: \(scanoutCompensationEnabled ? "on" : "off")")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            statusItem?.menu = buildMenu()
        }
    }

    @objc private func toggleScanoutDirection(_ sender: NSMenuItem) {
        scanoutBottomToTop.toggle()
        renderer?.scanoutBottomToTop = scanoutBottomToTop
        sender.state = scanoutBottomToTop ? .on : .off
        log("scanout direction: \(scanoutBottomToTop ? "bottom-to-top" : "top-to-bottom")")
    }

    private func savedRestStrength() -> RestStabilizationStrength {
        UserDefaults.standard.string(forKey: "restStrength").flatMap(RestStabilizationStrength.init(rawValue:)) ?? .light
    }

    private func savedRestTolerance() -> Double {
        let value = UserDefaults.standard.object(forKey: "restTolerance") as? Double ?? 1
        return value.isFinite ? min(RestPoseStabilizer.toleranceRange.upperBound, max(RestPoseStabilizer.toleranceRange.lowerBound, value)) : 1
    }

    @objc private func restToleranceChanged(_ sender: NSSlider) {
        let value = min(RestPoseStabilizer.toleranceRange.upperBound, max(RestPoseStabilizer.toleranceRange.lowerBound, (sender.doubleValue * 4).rounded() / 4))
        sender.doubleValue = value
        restToleranceValueLabel?.stringValue = String(format: "×%.2f", value)
        guard value != savedRestTolerance() else { return }
        UserDefaults.standard.set(value, forKey: "restTolerance")
        renderer?.restTolerance = value
        log(String(format: "world lock rest tolerance: ×%.2f", value))
    }

    private func savedRestIndicator() -> Bool {
        UserDefaults.standard.object(forKey: "showsRestIndicator") as? Bool ?? true
    }

    @objc private func toggleRestIndicator(_ sender: NSMenuItem) {
        let enabled = !savedRestIndicator()
        UserDefaults.standard.set(enabled, forKey: "showsRestIndicator")
        renderer?.showsRestIndicator = enabled
        sender.state = enabled ? .on : .off
        log("world lock rest indicator: \(enabled)")
    }

    @objc private func toggleWorldLockSmoothing(_ sender: NSMenuItem) {
        let enabled = !savedWorldLockSmoothing()
        UserDefaults.standard.set(enabled, forKey: "worldLockSmoothing")
        renderer?.worldLockSmoothing = enabled
        sender.state = enabled ? .on : .off
        log("world lock light smoothing: \(enabled ? "on" : "off")")
    }

    @objc private func toggleWorldLockedPresentation() {
        let enabled = !savedWorldLockedPresentation()
        UserDefaults.standard.set(enabled, forKey: "worldLockedPresentation")
        renderer?.worldLockedPresentation = enabled
        renderer?.stabilizer = OrientationStabilizer(level: savedStabilization())
        log("rotational world lock: \(enabled ? "on" : "off")")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            statusItem?.menu = buildMenu()
        }
    }

    private func savedScreenTextMode() -> ScreenTextMode {
        UserDefaults.standard.string(forKey: "screenTextMode").flatMap(ScreenTextMode.init(rawValue:)) ?? .original
    }

    @objc private func chooseScreenTextMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = ScreenTextMode(rawValue: raw) else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: "screenTextMode")
        renderer?.screenTextMode = mode
        sender.menu?.items.forEach { item in
            item.state = item.representedObject as? String == raw ? .on : .off
        }
        log("screen text mode: \(mode.rawValue)")
    }

    @objc private func chooseStabilization(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let level = StabilizationLevel(rawValue: raw) else { return }
        if savedWorldLockedPresentation() {
            let enabled = level != .off
            UserDefaults.standard.set(enabled, forKey: "restSmoothing")
            renderer?.restSmoothing = enabled
            if enabled {
                let strength: RestStabilizationStrength
                switch level {
                case .off, .weak: strength = .light
                case .medium: strength = .medium
                case .strong: strength = .strong
                }
                UserDefaults.standard.set(strength.rawValue, forKey: "restStrength")
                UserDefaults.standard.set(false, forKey: "adaptiveVSync")
                renderer?.restStrength = strength
                renderer?.adaptiveVSync = false
            }
            log("world lock rest stabilization: \(raw)")
        } else {
            UserDefaults.standard.set(level.rawValue, forKey: "stabilization")
            renderer?.stabilizer.level = level
            log("stabilization \(raw)")
        }
        sender.menu?.items.forEach { $0.state = ($0.representedObject as? String) == raw ? .on : .off }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            statusItem?.menu = buildMenu()
        }
    }

    private func pictureStabilizationLevel() -> StabilizationLevel {
        guard savedWorldLockedPresentation() else { return savedStabilization() }
        guard savedRestSmoothing() && !savedAdaptiveVSync() else { return .off }
        switch savedRestStrength() {
        case .light: return .weak
        case .medium: return .medium
        case .strong: return .strong
        }
    }

    private func pictureStabilizationMenu() -> NSMenuItem {
        let stabilization = NSMenuItem(title: t(.menuStabilization), action: nil, keyEquivalent: "")
        let hint = t(savedWorldLockedPresentation() ? .pictureStabilizationAnchoredHint : .pictureStabilizationUnanchoredHint)
        stabilization.toolTip = hint
        let levels = NSMenu()
        levels.autoenablesItems = false
        for (level, title) in [(StabilizationLevel.off, t(.menuStabilizationOff)), (.weak, t(.menuStabilizationWeak)),
                               (.medium, t(.menuStabilizationMedium)), (.strong, t(.menuStabilizationStrong))] {
            let item = menuItem(title, #selector(chooseStabilization(_:)))
            item.representedObject = level.rawValue
            item.state = level == pictureStabilizationLevel() ? .on : .off
            item.toolTip = hint
            levels.addItem(item)
        }
        stabilization.submenu = levels
        return stabilization
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
        let limit = 45.0
        let bias = min(limit, max(-limit, renderer.headPipeline.predictionBias * 1000 + milliseconds)) / 1000
        renderer.headPipeline.predictionBias = bias
        let fallback = renderer.headPipeline.predictionSeconds + bias
        UserDefaults.standard.set(fallback * 1000, forKey: "predictionMs")
        log(String(format: "prediction: поправка %+.0f ms, запасной путь %.0f ms", bias * 1000, fallback * 1000))
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
        let stored = UserDefaults.standard.object(forKey: "verticalFOV")
        let value = stored as? Double ?? (stored as? String).flatMap(Double.init)
        guard let value, Renderer.verticalFOVRange.contains(value) else { return Renderer.defaultVerticalFOV }
        return value
    }
    private func showVerticalFOV(_ value: Double) {
        fovSlider?.doubleValue = value
        fovValueLabel?.stringValue = String(format: "%.1f°", value)
    }
    @objc private func toggleWindow() {
        guard let window else { return }
        window.isVisible ? window.orderOut(nil) : window.orderFrontRegardless()
        syncCameraCentering()
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
        hotkeys.register(keyCode: kVK_LeftArrow, modifiers: controlKey | optionKey | cmdKey) { [weak self] in self?.turnAll(by: self?.turnStep ?? 0) }
        hotkeys.register(keyCode: kVK_RightArrow, modifiers: controlKey | optionKey | cmdKey) { [weak self] in self?.turnAll(by: -(self?.turnStep ?? 0)) }
        hotkeys.register(keyCode: kVK_ANSI_Comma, modifiers: controlKey | optionKey | shiftKey) { [weak self] in self?.rollLeft() }
        hotkeys.register(keyCode: kVK_ANSI_Period, modifiers: controlKey | optionKey | shiftKey) { [weak self] in self?.rollRight() }
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
        syncMenuFamily()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "eyeglasses", accessibilityDescription: "RayDesk")
        item.menu = buildMenu()
        statusItem = item
    }

    func buildMenu() -> NSMenu {
        statusLine.menu?.removeItem(statusLine)
        mouseTapLine.menu?.removeItem(mouseTapLine)
        rayNeoMenuItems = []
        vitureMenuItems = []
        calibrationMenuItems = []
        let menu = NSMenu()
        statusLine.title = statusText.isEmpty ? t(.statusStarting) : statusText
        refreshMouseTapLine()
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(screensMenu())
        menu.addItem(centreHeadingMenu())
        let camera = cameraMenu()
        rayNeoMenuItems.append(camera)
        menu.addItem(camera)
        let viture = vitureMenu()
        vitureMenuItems.append(viture)
        menu.addItem(viture)
        menu.addItem(pictureMenu())
        menu.addItem(meditationMenu())
        menu.addItem(settingsMenu())
        menu.addItem(.separator())
        menu.addItem(mouseTapLine)
        menu.addItem(.separator())
        menu.addItem(menuItem(t(.menuQuit), #selector(quit)))
        applyMenuFamily()
        return menu
    }

    private func screensMenu() -> NSMenuItem {
        submenu(t(.menuScreens)) { screens in
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
            screens.addItem(menuItem(t(.menuRollLeft), #selector(rollLeft)))
            screens.addItem(menuItem(t(.menuRollRight), #selector(rollRight)))
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
        }
    }

    private func manualCalibrationMenuItem() -> NSMenuItem {
        let item = menuItem(t(.menuGridManual), #selector(toggleCalibration))
        item.state = isCalibrating ? .on : .off
        calibrationMenuItems.append(item)
        return item
    }

    private func centreHeadingMenu() -> NSMenuItem {
        submenu(t(.menuCentreHeading)) { center in
            center.addItem(menuItem(t(.menuRecentreWorld), #selector(recenterToGaze)))
            center.addItem(manualCalibrationMenuItem())
            center.addItem(menuItem(t(.menuMarkReference), #selector(markReference)))
            let separator = NSMenuItem.separator()
            center.addItem(separator)
            let compassItem = menuItem(t(.menuCompass), #selector(toggleCompass(_:)))
            compassItem.state = UserDefaults.standard.bool(forKey: "compassEnabled") ? .on : .off
            center.addItem(compassItem)
            let calibrateCompassItem = menuItem(t(.menuCalibrateCompass), #selector(calibrateCompass))
            center.addItem(calibrateCompassItem)
            let gyroScaleItem = menuItem(t(.menuCalibrateGyroScale), #selector(calibrateGyroScale))
            center.addItem(gyroScaleItem)
            let recalibrateItem = menuItem(t(.menuRecalibrateGyro), #selector(recalibrate))
            center.addItem(recalibrateItem)
            rayNeoMenuItems += [separator, compassItem, calibrateCompassItem, gyroScaleItem, recalibrateItem]
        }
    }

    private func cameraMenu() -> NSMenuItem {
        submenu(t(.menuCamera)) { camera in
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
            let motionItem = menuItem(t(.menuCameraMotion), #selector(toggleCameraMotion(_:)))
            motionItem.state = cameraMotionEnabled() ? .on : .off
            cameraMotionItem = motionItem
            camera.addItem(motionItem)
            let calibrationItem = menuItem(t(.menuCalibrationSession), #selector(toggleCalibrationSession(_:)))
            calibrationItem.state = calibrationFile != nil ? .on : .off
            self.calibrationItem = calibrationItem
            camera.addItem(calibrationItem)
            let debugItem = menuItem(t(.menuCameraDebugWindow), #selector(toggleCameraDebug(_:)))
            debugItem.state = cameraDebugWindow?.isVisible == true ? .on : .off
            camera.addItem(debugItem)
        }
    }

    private func vitureMenu() -> NSMenuItem {
        submenu(t(.menuViture)) { viture in
            let callbackPose = menuItem(t(.menuVitureCallbackPose), #selector(toggleVitureCallbackPose(_:)))
            callbackPose.state = savedViturePoseMode() == .callback ? .on : .off
            viture.addItem(callbackPose)
            let autoTint = menuItem(t(.menuVitureAutoTint), #selector(toggleAutomaticLensTint(_:)))
            autoTint.state = automaticLensTint ? .on : .off
            autoTintMenuItem = autoTint
            viture.addItem(autoTint)
            viture.addItem(menuItem(t(.menuVitureRememberMonitor), #selector(rememberPhysicalMonitor)))
            viture.addItem(menuItem(t(.menuVitureForgetMonitor), #selector(forgetPhysicalMonitor)))
            viture.addItem(.separator())
            let sixDof = menuItem(t(.menuVitureSixDof), #selector(toggleVitureSixDof(_:)))
            sixDof.state = UserDefaults.standard.bool(forKey: "vitureSixDofPosition") ? .on : .off
            viture.addItem(sixDof)
            let extrapolation = menuItem(t(.menuVitureExtrapolation), #selector(toggleVitureExtrapolation(_:)))
            extrapolation.state = vitureExtrapolation ? .on : .off
            viture.addItem(extrapolation)
            let fusion = menuItem(t(.menuVitureGyroFusion), #selector(toggleVitureGyroFusion(_:)))
            fusion.state = UserDefaults.standard.bool(forKey: "vitureGyroFusion") ? .on : .off
            viture.addItem(fusion)
            viture.addItem(.separator())
            let handsItem = menuItem(t(.menuHandsCamera), #selector(toggleHandsCamera(_:)))
            handsItem.state = handCamera == nil ? .off : .on
            handsCameraItem = handsItem
            viture.addItem(handsItem)
        }
    }

    private func pictureMenu() -> NSMenuItem {
        submenu(t(.menuPicture)) { picture in
            picture.autoenablesItems = false
            picture.addItem(menuItem(t(.menuTogglePicture), #selector(toggleWindow)))
            let bordersItem = menuItem(t(.menuScreenBorders), #selector(toggleScreenBorders(_:)))
            bordersItem.state = UserDefaults.standard.bool(forKey: "hideScreenBorders") ? .off : .on
            picture.addItem(bordersItem)
            picture.addItem(submenu(t(.menuSoftText)) { modes in
                for (mode, title) in [(ScreenTextMode.original, t(.menuTextOriginal)), (.soft, t(.menuTextSoft)), (.softDimmed, t(.menuTextSoftDimmed))] {
                    let item = menuItem(title, #selector(chooseScreenTextMode(_:)))
                    item.representedObject = mode.rawValue
                    item.state = mode == savedScreenTextMode() ? .on : .off
                    modes.addItem(item)
                }
            })
            picture.addItem(.separator())
            picture.addItem(fovControl())
            picture.addItem(menuItem(t(.menuFieldOfViewWider), #selector(widerFOV)))
            picture.addItem(menuItem(t(.menuFieldOfViewNarrower), #selector(narrowerFOV)))
            picture.addItem(menuItem(t(.menuMorePrediction), #selector(morePrediction)))
            picture.addItem(menuItem(t(.menuLessPrediction), #selector(lessPrediction)))
            let worldLock = menuItem(t(.menuWorldLockedPresentation), #selector(toggleWorldLockedPresentation))
            worldLock.state = savedWorldLockedPresentation() ? .on : .off
            worldLock.toolTip = t(.worldLockedPresentationHint)
            picture.addItem(worldLock)
            picture.addItem(pictureStabilizationMenu())
            let lightSmoothing = menuItem(t(.menuWorldLockSmoothing), #selector(toggleWorldLockSmoothing(_:)))
            lightSmoothing.state = savedWorldLockSmoothing() ? .on : .off
            lightSmoothing.isEnabled = savedWorldLockedPresentation()
            picture.addItem(lightSmoothing)
            let adaptiveVSync = menuItem(t(.menuAdaptiveVSync), #selector(toggleAdaptiveVSync(_:)))
            adaptiveVSync.state = savedAdaptiveVSync() ? .on : .off
            adaptiveVSync.isEnabled = savedWorldLockedPresentation()
            adaptiveVSync.toolTip = t(.adaptiveVSyncHint)
            picture.addItem(adaptiveVSync)
            let scanout = menuItem(t(.menuScanoutCompensation), #selector(toggleScanoutCompensation(_:)))
            scanout.state = scanoutCompensationEnabled ? .on : .off
            scanout.isEnabled = savedWorldLockedPresentation()
            scanout.toolTip = t(.scanoutCompensationHint)
            picture.addItem(scanout)
            let scanoutDirection = menuItem(t(.menuScanoutBottomToTop), #selector(toggleScanoutDirection(_:)))
            scanoutDirection.state = scanoutBottomToTop ? .on : .off
            scanoutDirection.isEnabled = savedWorldLockedPresentation() && scanoutCompensationEnabled
            picture.addItem(scanoutDirection)
            picture.addItem(restToleranceControl())
            let restIndicator = menuItem(t(.menuRestIndicator), #selector(toggleRestIndicator(_:)))
            restIndicator.state = savedRestIndicator() ? .on : .off
            picture.addItem(restIndicator)
            picture.addItem(.separator())
            picture.addItem(menuItem(t(.menuHorizonGrid), #selector(toggleGrid)))
            picture.addItem(manualCalibrationMenuItem())
            picture.addItem(menuItem(t(.menuRecordGlassesVideo), #selector(toggleRecording)))
        }
    }

    private func settingsMenu() -> NSMenuItem {
        submenu(t(.menuSettings)) { settings in
            for language in AppLanguage.allCases {
                let option = menuItem(language.nativeName, #selector(chooseLanguage(_:)))
                option.representedObject = language.rawValue
                option.state = language == Localization.shared.language ? .on : .off
                settings.addItem(option)
            }
        }
    }

    /// Переключает меню и строку состояния на семейство подключённых очков.
    private func syncMenuFamily() {
        guard let family = connectedGlassesFamily, family != menuFamily else { return }
        menuFamily = family
        log("glasses family: \(family.rawValue)")
        applyMenuFamily()
    }

    /// Прячет пункты меню, которых у подключённого семейства очков нет.
    private func applyMenuFamily() {
        let viture = menuFamily == .viture
        for item in rayNeoMenuItems { item.isHidden = viture }
        for item in vitureMenuItems { item.isHidden = !viture }
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

    private func restToleranceControl() -> NSMenuItem {
        let value = NSTextField(labelWithString: String(format: "×%.2f", savedRestTolerance()))
        value.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 48).isActive = true
        let title = NSTextField(labelWithString: t(.menuRestTolerance))
        title.font = .menuFont(ofSize: 0)
        let slider = NSSlider(value: savedRestTolerance(), minValue: RestPoseStabilizer.toleranceRange.lowerBound,
                              maxValue: RestPoseStabilizer.toleranceRange.upperBound,
                              target: self, action: #selector(restToleranceChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.altIncrementValue = 0.25
        slider.setAccessibilityLabel(t(.menuRestTolerance))
        slider.toolTip = t(.restToleranceHint)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [title, slider, value])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 14, bottom: 2, right: 14)
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 28)
        restToleranceValueLabel = value
        let item = NSMenuItem()
        item.view = stack
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

    private func logFrameTiming(_ kind: String, _ timing: FrameTimeline.Summary) {
        func milliseconds(_ value: Double?) -> String {
            value.map { String(format: "%.3f", $0) } ?? "n/a"
        }
        log("GPU \(kind) window=240 frames=\(timing.frames) cpuP95=\(milliseconds(timing.cpuMillisecondsP95))ms queueP95=\(milliseconds(timing.gpuQueueMillisecondsP95))ms executionP95=\(milliseconds(timing.gpuMillisecondsP95))ms presentWaitP95=\(milliseconds(timing.presentWaitMillisecondsP95))ms poseAgeP95=\(milliseconds(timing.sourceAgeMillisecondsP95))ms")
    }

    private func refreshStatus() {
        statusTicks += 1
        if let viture, viture.poseMode == .callback {
            let counts = viture.takeCallbackCounts()
            log("VITURE callback: received=\(counts.received) processed=\(counts.processed) rejected=\(counts.rejected)")
        }
        if let state = renderer?.independentReprojection?.snapshot {
            log(String(format: "ATW presented=%d submitted=%d reused=%d dropped=%d errors=%d age=%.1fms maxAge=%.1fms maxGap=%.1fms",
                       state.presented, state.submitted, state.reused, state.dropped, state.failed,
                       state.frameAge * 1000, state.maximumFrameAge * 1000, state.maximumPresentGap * 1000))
            let sampleToPresent = state.presented > 0
                ? String(format: "%.2fms", (state.lastPresentedTime - state.sampleTime) * 1000) : "n/a"
            log(String(format: "ATW adaptive=%@ vsync=%@ switches=%d targetLead=%.2fms sampleToPresent=%@ presentedSync=%@ horizon=%.2fms timeResidual=%.2fms",
                       state.adaptiveVSync ? "on" : "off", state.displaySyncEnabled ? "on" : "off",
                       state.syncSwitches, (state.poseTargetTime - state.sampleTime) * 1000, sampleToPresent,
                       state.presentedDisplaySyncEnabled ? "on" : "off", state.horizon * 1000,
                       (state.lastPresentedTime - state.poseTargetTime) * 1000))
            if let pacing = state.pacing {
                let latency = pacing.latencyPeriods.map { String(format: "%.2f", $0) } ?? "n/a"
                log("ATW pacing skips=\(pacing.skipped) latencyPeriods=\(latency) streak=\(pacing.overStreak) pending=\(pacing.drainRequested) motionEligible=\(pacing.motionEligible)")
            }
            log(String(format: "SCANOUT span=%.3fms referenceTarget=%.6f lastRowTarget=%.6f referenceResidual=%.3fms angle=%.5fdeg direction=%@",
                       state.scanoutDuration * 1000, state.poseTargetTime, state.scanoutEndTargetTime,
                       (state.lastPresentedTime - state.poseTargetTime) * 1000, state.scanoutAngle * 180 / .pi,
                       state.scanoutBottomToTop ? "bottom-to-top" : "top-to-bottom"))
            if let error = state.error { log("ATW error: \(error)") }
        }
        if let renderer {
            let warp = renderer.independentReprojection?.timings ?? renderer.warpTimings
            logFrameTiming("warp", warp.summary(synchronized: renderer.displaySyncEnabled))
            logFrameTiming("scene", renderer.sceneTimings.summary(synchronized: nil))
            let position = renderer.currentHeadOffset
            log(String(format: "ATW appliedPosition=%.4f,%.4f,%.4fm", position.x, position.y, position.z))
        }
        syncMenuFamily()
        syncCameraCentering()
        watchRendering()
        logCameraHead()
        logViturePose()
        if let renderer { showVerticalFOV(renderer.verticalFOV) }
        if let offset = renderer?.presentation.offset {
            let source = renderer?.usedExternalOrientation == true ? "VITURE" : "внутренний трекер"
            log(String(format: "DIAG поправка времени показа %.1f мс · горизонт предсказания (%@) %.1f мс",
                       offset * 1000, source, (renderer?.lastPredictionHorizon ?? 0) * 1000))
        }
        if let renderer, renderer.adaptivePrediction {
            log(String(format: "DIAG поправка предсказания %+.1f мс", renderer.headPipeline.predictionBias * 1000))
        }
        if let renderer, renderer.worldLockedPresentation {
            if renderer.restSmoothing || renderer.adaptiveVSync {
                log(String(format: "DIAG покой %@ · сила %@ · порог ×%.2f · поправка %.4f°",
                           renderer.restPhase.rawValue, renderer.restStrength.rawValue, renderer.restTolerance,
                           renderer.restCorrection * 180 / .pi))
            }
            log(String(format: "DIAG закрепление поворотов %@ · поздняя поправка %.3f°",
                       renderer.lastReprojectionApplied ? "активно" : "без перепроекции", renderer.lastReprojectionAngle * 180 / .pi))
        }
        if menuFamily == .viture {
            refreshVitureStatus()
        } else {
            refreshRayNeoStatus()
        }
    }

    /// Строка состояния RayNeo: IMU, компас и выученный ноль гироскопа.
    private func refreshRayNeoStatus() {
        if statusTicks % 30 == 0 { saveGyroBias() }
        promptCompassRecalibrationIfFieldChanged()
        let cameraHoldsHeading = cameraHead.isRunning && cameraHead.correctsHeading
        if filter.compassPaused != cameraHoldsHeading {
            filter.compassPaused = cameraHoldsHeading
            log(cameraHoldsHeading ? "compass paused: camera reference owns heading (including temporary tracking loss)" : "compass resumed")
        }
        let rate = imu?.takeSampleRate() ?? 0
        let yp = head.yawPitch
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
        writeCalibrationRow()
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

    /// Строка состояния VITURE: ориентация и положение приходят из SDK.
    private func refreshVitureStatus() {
        autoTintMenuItem?.toolTip = viture?.supportsFilmControl == false ? t(.menuVitureTintUnavailable) : nil
        let yp = head.yawPitch
        let yaw = yp.yaw * 180 / .pi
        let pitch = yp.pitch * 180 / .pi
        let fov = renderer?.verticalFOV ?? 0
        if let viture, let pose = viture.pose() {
            let position = pose.position
            statusText = String(format: t(.statusViture), pose.isStable ? "✓" : "✗",
                                yaw, pitch, scene.screens.count, fov,
                                position.x, position.y, position.z)
        } else if viture != nil {
            statusText = String(format: t(.statusVitureNoPose), yaw, pitch, scene.screens.count, fov)
        } else {
            statusText = String(format: t(.statusVitureNoTracker), yaw, pitch, scene.screens.count, fov)
        }
        statusLine.title = statusText
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
