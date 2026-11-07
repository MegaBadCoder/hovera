import Foundation
import simd
import VitureSDK

/// Трекер VITURE: держит дескриптор SDK, отдаёт позу и переносит опору.
///
/// В отличие от RayNeo, у VITURE поза считается на очках: VIO фьюзит стереокамеры
/// с IMU и отдаёт готовые 6DoF с привязкой наклона к гравитации. Поэтому фильтр
/// ориентации здесь не нужен, а дрейф курса отсутствует по определению.
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

    private let library: VitureLibrary
    private let device: VitureDevice
    private let lock = NSLock()
    private var lastPose: ViturePose?
    private var lastPoseTime: Double = 0
    private var stopped = false
    private var predictFailures = 0
    private var driftMeter = PoseDriftMeter()
    private var fusion = VitureOrientationFusion()
    /// С какого момента голова стоит по гироскопу: нужно для обучения нуля в темноте.
    private var gyroStillSince: Double?
    private var previousForRate: (time: Double, orientation: simd_quatd)?
    private var pollTimer: DispatchSourceTimer?
    private let pollQueue = DispatchQueue(label: "raydesk.viture.poll", qos: .userInteractive)
    private var connected = true
    private var lastConnectionCheck: Double = 0

    private let imuLock = NSLock()
    private var imuSample: (acceleration: SIMD3<Double>, angularVelocity: SIMD3<Double>, time: Double)?

    /// Последний сырой IMU-отсчёт: ускорение и угловая скорость, как их отдал SDK.
    var latestIMU: (acceleration: SIMD3<Double>, angularVelocity: SIMD3<Double>, time: Double)? {
        imuLock.lock()
        defer { imuLock.unlock() }
        return imuSample
    }

    private init(library: VitureLibrary, device: VitureDevice, productID: Int32, productName: String?) {
        self.library = library
        self.device = device
        self.productID = productID
        self.productName = productName
    }

    /// Ищет очки, загружает SDK и запускает трекинг.
    ///
    /// - Returns: готовый трекер либо `nil`, если VITURE нет в системе или SDK не загрузился.
    /// - Throws: `StartError`, если очки найдены, но SDK не смог их поднять.
    static func start(searchPaths: [String] = VitureLibrary.defaultSearchPaths(),
                      library: VitureLibrary? = nil) throws -> VitureTracker? {
        let connected = VitureUSB.connectedDevices()
        guard let found = connected.first else { return nil }
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
        return try start(library: sdk, device: device, productID: found.productID, productName: found.name)
    }

    private static func start(library: VitureLibrary, device: VitureDevice, productID: Int32, productName: String?) throws -> VitureTracker {
        device.setSixDegreesOfFreedom(true)
        guard device.initialize(cacheDirectory: VitureLibrary.defaultCacheDirectory()) else {
            throw StartError.startupFailed("initialize", code: -1)
        }
        let tracker = VitureTracker(library: library, device: device, productID: productID, productName: productName)
        device.registerCallbacks(imu: { acceleration, angularVelocity, time in
            tracker.store(imu: acceleration, angularVelocity: angularVelocity, time: time)
        })
        guard device.start() else {
            throw StartError.startupFailed("start", code: -1)
        }
        tracker.startPolling()
        return tracker
    }

    /// Текущая поза очков.
    ///
    /// - Parameter predictTime: на сколько вперёд предсказать позу, секунды.
    /// - Returns: поза либо `nil`, если SDK её не отдал.
    func pose(predictTime: Double = 0) -> ViturePose? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped, let lastPose else { return nil }
        guard predictTime > 0, let imu = latestIMU else { return lastPose }
        let rate = VitureIMU.radiansPerSecond(VitureIMU.bodyAngularVelocity(imu.angularVelocity)) - fusion.gyroBias
        return lastPose.extrapolated(by: predictTime, rate: rate)
    }

    /// Запускает опрос позы в отдельном потоке.
    ///
    /// Позу нельзя спрашивать с главного потока: SDK иногда застревает на USB,
    /// а главный поток рисует кадр и держит виртуальные дисплеи — его остановка
    /// и есть «картинка тормозит» и срабатывание watchdog.
    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: pollQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 120.0)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        pollTimer = timer
    }

    private func poll() {
        lock.lock()
        let stopped = self.stopped
        lock.unlock()
        guard !stopped else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let pose = device.pose(predictTime: 0)
        lock.lock()
        if pose == nil {
            predictFailures += 1
        }
        lock.unlock()
        guard let pose else { return }
        let gyro: SIMD3<Double>? = latestIMU.map { sample in VitureIMU.radiansPerSecond(VitureIMU.bodyAngularVelocity(sample.angularVelocity)) }
        if let gyro, length(gyro) < 0.03 {
            lock.lock()
            if gyroStillSince == nil { gyroStillSince = now }
            lock.unlock()
        } else {
            lock.lock()
            gyroStillSince = nil
            lock.unlock()
        }
        lock.lock()
        let stillForBias = gyroStillSince.map { now - $0 > 2 } ?? false
        lock.unlock()
        let fused = fusion.update(pose: pose.orientation, stable: pose.isStable, gyro: gyro, time: now, still: stillForBias)
        var result = pose
        if let fused { result.orientation = fused }
        lock.lock()
        if !pose.isStable, let previous = lastPose {
            result.position = previous.position
        }
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
        lastPoseTime = now
        lock.unlock()
        if now - lastConnectionCheck > 2 {
            lastConnectionCheck = now
            connected = VitureUSB.connectedDevices().contains { $0.productID == productID }
        }
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

    /// Возраст последней полученной позы, секунды; `nil`, если позы ещё не было.
    var poseAge: Double? {
        lock.lock()
        defer { lock.unlock() }
        guard lastPose != nil else { return nil }
        return ProcessInfo.processInfo.systemUptime - lastPoseTime
    }

    private func store(imu acceleration: SIMD3<Double>, angularVelocity: SIMD3<Double>, time: Double) {
        imuLock.lock()
        imuSample = (acceleration, angularVelocity, time)
        imuLock.unlock()
    }

    /// Переносит опору мира в текущее положение и курс.
    ///
    /// Наклон к гравитации SDK не трогает: горизонт после этого остаётся верным.
    @discardableResult
    func recenter() -> Bool {
        guard let current = pose(predictTime: 0) else { return false }
        return resetOrigin(to: current)
    }

    /// Переносит опору мира в заданную позу.
    ///
    /// Наклон к гравитации SDK не трогает: горизонт после этого остаётся верным.
    ///
    /// - Parameter pose: поза, которая станет началом координат.
    @discardableResult
    func resetOrigin(to pose: ViturePose) -> Bool {
        fusion.reset()
        gyroStillSince = nil
        return device.resetOrigin(to: pose)
    }

    /// Останавливает трекинг. Повторный запуск требует нового трекера.
    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        lock.unlock()
        device.stop()
    }

    /// `true`, если очки ещё видны в USB.
    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connected
    }
}
