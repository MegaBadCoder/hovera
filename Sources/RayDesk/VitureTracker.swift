import Foundation
import simd
import VitureSDK

/// Трекер VITURE: держит дескриптор SDK, отдаёт позу и переносит опору.
final class VitureTracker {
    /// Ошибки запуска трекера.
    enum StartError: Error {
        /// SDK не загрузился: библиотеки нет или в ней нет нужных функций.
        case sdkUnavailable(String)
        /// Очки VITURE не найдены в USB.
        case glassesNotFound
        /// SDK не создал дескриптор выбранного устройства.
        case deviceNotCreated(productID: Int32)
        /// SDK отказал на инициализации или старте.
        case startupFailed(String, code: Int32)
    }

    /// Product id подключённых очков.
    let productID: Int32
    /// Строка продукта, если система её отдала.
    let productName: String?

    private let clock: () -> Double
    private let connectionCheck: () -> Bool
    private let startedAt: Double
    private let library: VitureLibrary
    private let device: VitureDevice
    let poseMode: ViturePoseMode
    private let nativeToHost: (Double) -> Double
    private var pendingCallback: (native: Double, host: Double)?
    private var callbackScheduled = false
    private var callbackReady = false
    private var lastCallbackTimestamp = -Double.infinity
    private var callbackNotBefore = -Double.infinity
    private var callbackCount = 0
    private var processedCallbackCount = 0
    private var rejectedCallbackCount = 0
    private let lock = NSLock()
    private var lastPose: ViturePose?
    private var lastSDKPosition: SIMD3<Double>?
    private var lastPoseTime: Double?
    private var lastOutputTime: Double = 0
    private var positionGuard = ViturePositionGuard()
    private var originalFilmMode: Float?
    private var appliedFilmMode: Float?
    private var filmControlUnavailable = false
    private var stopped = false
    private var predictFailures = 0
    private var driftMeter = PoseDriftMeter()
    private var fusion = VitureOrientationFusion()
    /// С какого момента голова стоит по гироскопу: нужно для обучения нуля в темноте.
    private var gyroStillSince: Double?
    private var previousForRate: (time: Double, orientation: simd_quatd)?
    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "raydesk.viture.poll", qos: .userInteractive)
    private let serviceQueue = DispatchQueue(label: "raydesk.viture.connection", qos: .utility)
    private let connectionLock = NSLock()
    private var connectionTimer: DispatchSourceTimer?
    private var connected = true
    private var lastConnectionCheck: Double = 0
    private let settingsLock = NSLock()
    private var _usesFusion = UserDefaults.standard.bool(forKey: "vitureGyroFusion")
    private var _usesExtrapolation = UserDefaults.standard.object(forKey: "vitureExtrapolation") as? Bool ?? true

    /// Продолжать поворот гироскопом до 250 мс после потери устойчивой позы VIO.
    ///
    /// По умолчанию выключено. Устойчивая поза VIO всегда задаёт ориентацию напрямую.
    var usesFusion: Bool {
        get { settingsLock.withLock { _usesFusion } }
        set {
            lock.lock()
            defer { lock.unlock() }
            settingsLock.withLock { _usesFusion = newValue }
            fusion.reset()
        }
    }

    /// Предсказывать позу экстраполяцией гироскопа между отсчётами.
    ///
    /// Включено по умолчанию: между отсчётами VIO проходит больше времени, чем
    /// между кадрами, и без предсказания картинка отстаёт. Переключается пунктом
    /// меню «Очки VITURE» и флагом `vitureExtrapolation`.
    var usesExtrapolation: Bool {
        get { settingsLock.withLock { _usesExtrapolation } }
        set { settingsLock.withLock { _usesExtrapolation = newValue } }
    }

    private let angularVelocityUnit = VitureIMU.AngularVelocityUnit(rawValue: UserDefaults.standard.string(forKey: "vitureIMUAngularUnit") ?? "radians") ?? .radians
    private let imuLock = NSLock()
    private var imuArrivalTime = -Double.infinity
    private var imuSample: (acceleration: SIMD3<Double>, angularVelocity: SIMD3<Double>, time: Double)?

    /// Последний сырой IMU-отсчёт: ускорение и угловая скорость, как их отдал SDK.
    var latestIMU: (acceleration: SIMD3<Double>, angularVelocity: SIMD3<Double>, time: Double)? {
        imuLock.lock()
        defer { imuLock.unlock() }
        return imuSample
    }

    private init(library: VitureLibrary, device: VitureDevice, productID: Int32, productName: String?,
                 clock: @escaping () -> Double, connectionCheck: @escaping () -> Bool,
                 poseMode: ViturePoseMode, nativeToHost: @escaping (Double) -> Double) {
        self.clock = clock
        self.connectionCheck = connectionCheck
        startedAt = clock()
        self.library = library
        self.device = device
        self.productID = productID
        self.productName = productName
        self.poseMode = poseMode
        self.nativeToHost = nativeToHost
    }

    /// Ищет очки, загружает SDK и запускает трекинг.
    ///
    /// - Returns: готовый трекер либо `nil`, если Luma Ultra нет в системе.
    /// - Throws: `StartError`, если очки найдены, но SDK не смог их поднять.
    static func start(searchPaths: [String] = VitureLibrary.defaultSearchPaths(),
                      library: VitureLibrary? = nil, poseMode: ViturePoseMode = .polling) throws -> VitureTracker? {
        let connected = VitureUSB.connectedDevices()
        guard let found = connected.first(where: { $0.productID == 0x1104 }) else { return nil }
        let sdk: VitureLibrary
        if let library {
            sdk = library
        } else {
            do {
                sdk = try VitureLibrary.load(searchPaths: searchPaths)
                sdk.retainForProcessLifetime()
            } catch {
                throw StartError.sdkUnavailable("\(error)")
            }
        }
        guard let device = sdk.createDevice(productID: found.productID) else {
            throw StartError.deviceNotCreated(productID: found.productID)
        }
        return try start(library: sdk, device: device, productID: found.productID, productName: found.name, poseMode: poseMode)
    }

    static func start(library: VitureLibrary, device: VitureDevice, productID: Int32, productName: String?,
                      automaticallyPoll: Bool = true,
                      clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
                      connectionCheck: (() -> Bool)? = nil, poseMode: ViturePoseMode = .polling,
                      nativeToHost: @escaping (Double) -> Double = VitureNativeClock.hostTime) throws -> VitureTracker {
        var ready = false
        defer { if !ready { device.close() } }
        guard device.kind == .carina, device.setSixDegreesOfFreedom(true) else {
            throw StartError.startupFailed("setSixDegreesOfFreedom", code: -1)
        }
        guard device.initialize(config: poseMode.configuration, cacheDirectory: VitureLibrary.defaultCacheDirectory()) else {
            throw StartError.startupFailed("initialize", code: -1)
        }
        guard poseMode != .callback || device.supportsNativePose else {
            throw StartError.sdkUnavailable("native GL pose API для callback недоступен")
        }
        let tracker = VitureTracker(library: library, device: device, productID: productID, productName: productName,
                                    clock: clock, connectionCheck: connectionCheck ?? { VitureUSB.connectedDevices().contains { $0.productID == productID } },
                                    poseMode: poseMode, nativeToHost: nativeToHost)
        let poseClock: ((Double) -> Void)? = poseMode == .callback ? { [weak tracker] timestamp in
            tracker?.receivePoseClock(timestamp)
        } : nil
        guard device.registerCallbacks(imu: { [weak tracker] acceleration, angularVelocity, time in
            tracker?.store(imu: acceleration, angularVelocity: angularVelocity, time: time)
        }, poseClock: poseClock) else {
            throw StartError.startupFailed("registerCallbacks", code: -1)
        }
        guard device.start() else {
            throw StartError.startupFailed("start", code: -1)
        }
        ready = true
        tracker.activateCallbackDelivery()
        if automaticallyPoll { tracker.startPolling() }
        return tracker
    }

    private func activateCallbackDelivery() {
        lock.lock()
        defer { lock.unlock() }
        callbackReady = true
        guard pendingCallback != nil, !callbackScheduled else { return }
        callbackScheduled = true
        pollQueue.async { [weak self] in self?.consumePoseClock() }
    }

    private func receivePoseClock(_ timestamp: Double) {
        let host = nativeToHost(timestamp)
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        guard timestamp.isFinite, host.isFinite, timestamp > lastCallbackTimestamp,
              host <= now + 0.005, host >= now - 0.25, host >= callbackNotBefore else {
            rejectedCallbackCount += 1
            return
        }
        lastCallbackTimestamp = timestamp
        callbackCount += 1
        pendingCallback = (timestamp, host)
        guard callbackReady, !callbackScheduled else { return }
        callbackScheduled = true
        pollQueue.async { [weak self] in self?.consumePoseClock() }
    }

    private func consumePoseClock() {
        let sample = lock.withLock { () -> (native: Double, host: Double)? in
            guard !stopped else { pendingCallback = nil; callbackScheduled = false; return nil }
            guard let sample = pendingCallback else { callbackScheduled = false; return nil }
            pendingCallback = nil
            return sample
        }
        guard let sample else { return }
        let pose = device.nativePose(at: sample.native)
        accept(pose, at: clock(), poseTime: sample.host)
        lock.lock()
        processedCallbackCount += 1
        let again = !stopped && pendingCallback != nil
        if !again { callbackScheduled = false }
        lock.unlock()
        if again { pollQueue.async { [weak self] in self?.consumePoseClock() } }
    }

    func takeCallbackCounts() -> (received: Int, processed: Int, rejected: Int) {
        lock.withLock {
            defer { callbackCount = 0; processedCallbackCount = 0; rejectedCallbackCount = 0 }
            return (callbackCount, processedCallbackCount, rejectedCallbackCount)
        }
    }

    /// Текущая поза очков.
    ///
    /// - Parameter predictTime: на сколько вперёд предсказать позу, секунды.
    /// - Returns: поза либо `nil`, если SDK её не отдал.
    func pose(predictTime: Double = 0) -> ViturePose? {
        poseSample(predictTime: predictTime)?.pose
    }

    func poseSample(predictTime: Double = 0, extrapolate: Bool = true)
        -> (pose: ViturePose, predictionHorizon: Double, sampleTime: Double, maximumPredictionHorizon: Double)? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let lastPose else { return nil }
        let now = clock()
        guard usesExtrapolation, predictTime.isFinite, predictTime >= 0, let gyro = freshGyro(at: now) else { return (lastPose, 0, lastOutputTime, 0) }
        let maximumHorizon = usesFusion ? min(0.05, max(0, fusion.remainingPredictionTime(at: now))) : 0.05
        let horizon = min(maximumHorizon, max(0, now - lastOutputTime) + predictTime)
        if !extrapolate { return (lastPose, horizon, lastOutputTime, maximumHorizon) }
        return (lastPose.extrapolated(by: horizon, rate: gyro - fusion.gyroBias), horizon, lastOutputTime + horizon, maximumHorizon)
    }

    /// Запускает опрос позы в отдельном потоке.
    ///
    /// Позу нельзя спрашивать с главного потока: SDK иногда застревает на USB,
    /// а главный поток рисует кадр и держит виртуальные дисплеи — его остановка
    /// и есть «картинка тормозит» и срабатывание watchdog.
    private func startPolling() {
        let connectionTimer = DispatchSource.makeTimerSource(queue: serviceQueue)
        connectionTimer.schedule(deadline: .now(), repeating: 2)
        connectionTimer.setEventHandler { [weak self] in self?.refreshConnection(force: true) }
        self.connectionTimer = connectionTimer
        connectionTimer.resume()
        guard poseMode == .polling else { return }
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 120.0)
        timer.setEventHandler { [weak self] in self?.pollOnQueue() }
        timer.resume()
        pollTimer = timer
    }

    func poll() {
        refreshConnection()
        pollQueue.sync { pollOnQueue() }
    }

    private func freshGyro(at time: Double) -> SIMD3<Double>? {
        imuLock.lock()
        defer { imuLock.unlock() }
        guard time - imuArrivalTime <= 0.1, let sample = imuSample else { return nil }
        let rate = VitureIMU.radiansPerSecond(VitureIMU.bodyAngularVelocity(sample.angularVelocity), unit: angularVelocityUnit)
        guard rate.x.isFinite, rate.y.isFinite, rate.z.isFinite else { return nil }
        return rate
    }

    private func refreshConnection(force: Bool = false) {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        guard !lock.withLock({ stopped }) else { return }
        if force || clock() - lastConnectionCheck > 2 {
            lastConnectionCheck = clock()
            let present = connectionCheck()
            lock.withLock { if !stopped { connected = present } }
        }
    }

    private func pollOnQueue() {
        guard !lock.withLock({ stopped || !connected }) else { return }
        guard poseMode == .polling else { return }
        let pose = device.pose(predictTime: 0)
        let now = clock()
        accept(pose, at: now, poseTime: now)
    }

    private func accept(_ pose: ViturePose?, at now: Double, poseTime: Double) {
        let gyro = freshGyro(at: now)
        var message: String?
        lock.lock()
        defer {
            lock.unlock()
            if let message { serviceQueue.async { log(message) } }
        }
        guard !stopped else { return }
        if pose != nil {
            lastPoseTime = poseTime
            if let position = pose?.position, position.x.isFinite, position.y.isFinite, position.z.isFinite {
                lastSDKPosition = position
            }
        } else {
            predictFailures += 1
        }
        if let gyro, length(gyro) < 0.03 {
            if gyroStillSince == nil { gyroStillSince = now }
        } else {
            gyroStillSince = nil
        }
        let stillForBias = gyroStillSince.map { now - $0 > 2 } ?? false
        let useFusion = usesFusion
        let fused = fusion.update(pose: useFusion ? pose?.orientation : nil,
                                  stable: useFusion && pose?.isStable == true,
                                  gyro: gyro, time: now, still: stillForBias)
        guard var result = pose ?? lastPose else { return }
        if pose == nil {
            result.isStable = false
        }
        let wasHolding = positionGuard.isHolding
        result.position = positionGuard.update(pose?.position, stable: pose?.isStable == true, at: now)
        if positionGuard.isHolding != wasHolding {
            message = positionGuard.isHolding
                ? "VITURE: положение 6DoF удерживается — недостоверное смещение или потеря трекинга"
                : "VITURE: положение 6DoF восстановлено без скачка сцены"
        }
        if useFusion, let fused { result.orientation = fused }
        if useFusion && pose?.isStable != true && fused != nil && gyro != nil { lastOutputTime = now }
        else if pose != nil { lastOutputTime = poseTime }
        if let previous = previousForRate {
            let dt = now - previous.time
            if dt > 1e-6, dt < 0.5 {
                let delta = 2 * acos(min(1, abs(simd_dot(result.orientation.vector, previous.orientation.vector))))
                let yawPitch = result.orientation.yawPitch
                let roll = Self.roll(of: result.orientation)
                driftMeter.add(time: now, yaw: yawPitch.yaw * 180 / .pi, pitch: yawPitch.pitch * 180 / .pi,
                               roll: roll * 180 / .pi, angularSpeed: delta / dt)
            }
        }
        previousForRate = (now, result.orientation)
        lastPose = result
    }

    /// Крен ориентации в радианах.
    private static func roll(of orientation: simd_quatd) -> Double {
        atan2(2 * (orientation.real * orientation.imag.z + orientation.imag.x * orientation.imag.y),
              1 - 2 * (orientation.imag.y * orientation.imag.y + orientation.imag.z * orientation.imag.z))
    }

    /// Увод мира на неподвижной голове, градусы в минуту по осям; `nil`, пока окно не набрано.
    var driftPerMinute: (yaw: Double, pitch: Double, roll: Double)? {
        lock.lock()
        defer { lock.unlock() }
        return driftMeter.driftPerMinute
    }

    /// Длительность окна измерения увода, секунды.
    var driftSpan: Double {
        lock.lock()
        defer { lock.unlock() }
        return driftMeter.measuredSpan
    }

    /// Выученный ноль гироскопа, рад/с.
    var gyroBias: SIMD3<Double> {
        lock.lock()
        defer { lock.unlock() }
        return fusion.gyroBias
    }

    /// Сколько раз SDK не отдал позу; для диагностики.
    var predictionFailureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return predictFailures
    }

    /// Возраст последней позы SDK или время ожидания первой позы, секунды.
    var poseAge: Double? {
        lock.lock()
        defer { lock.unlock() }
        return clock() - (lastPoseTime ?? startedAt)
    }

    var shouldRestart: Bool {
        lock.withLock { clock() - (lastPoseTime ?? startedAt) > (lastPoseTime == nil ? 10 : 2) }
    }

    private func store(imu acceleration: SIMD3<Double>, angularVelocity: SIMD3<Double>, time: Double) {
        imuLock.lock()
        imuSample = (acceleration, angularVelocity, time)
        imuArrivalTime = clock()
        imuLock.unlock()
    }

    /// Переносит опору в заданную позу в очереди SDK. Результат приходит в той же очереди.
    func resetOrigin(to pose: ViturePose, completion: @escaping (Bool) -> Void = { _ in }) {
        pollQueue.async { [self] in
            let origin: ViturePose? = lock.withLock {
                guard !stopped else { return nil }
                var origin = pose
                origin.position = lastSDKPosition ?? pose.position
                return origin
            }
            guard let origin, device.resetOrigin(to: origin) else {
                completion(false)
                return
            }
            lock.withLock {
                fusion.reset()
                gyroStillSince = nil
                previousForRate = nil
                driftMeter = PoseDriftMeter()
                positionGuard = ViturePositionGuard()
                if poseMode == .callback {
                    pendingCallback = nil
                    callbackNotBefore = clock()
                }
            }
            pollOnQueue()
            completion(true)
        }
    }

    var supportsFilmControl: Bool { lock.withLock { !filmControlUnavailable } }

    func setLensTint(_ darkened: Bool?) {
        pollQueue.async { [self] in
            guard !lock.withLock({ stopped || filmControlUnavailable }) else { return }
            guard let darkened else {
                restoreFilmMode()
                return
            }
            if originalFilmMode == nil {
                originalFilmMode = device.filmMode()
                guard originalFilmMode != nil else {
                    lock.withLock { filmControlUnavailable = true }
                    log("VITURE: SDK не поддерживает чтение затемнения линз")
                    return
                }
            }
            let value: Float = darkened ? 1 : 0
            guard appliedFilmMode != value else { return }
            if device.setFilmMode(value) {
                appliedFilmMode = value
            } else {
                restoreFilmMode()
                lock.withLock { filmControlUnavailable = true }
                log("VITURE: SDK отклонил переключение затемнения линз")
            }
        }
    }

    private func restoreFilmMode() {
        guard let originalFilmMode else { return }
        if device.setFilmMode(originalFilmMode) {
            self.originalFilmMode = nil
            appliedFilmMode = nil
        }
    }

    /// Останавливает опрос и освобождает SDK в его очереди; завершение вызывается после очистки.
    func stop(completion: @escaping () -> Void = {}) {
        lock.withLock {
            stopped = true
            pendingCallback = nil
            pollTimer?.cancel()
            pollTimer = nil
            connectionTimer?.cancel()
            connectionTimer = nil
        }
        pollQueue.async { [self] in
            restoreFilmMode()
            device.close()
            completion()
        }
    }

    /// `true`, если очки ещё видны в USB.
    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connected
    }
}
