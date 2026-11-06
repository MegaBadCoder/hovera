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
        guard device.start() else {
            throw StartError.startupFailed("start", code: -1)
        }
        return VitureTracker(library: library, device: device, productID: productID, productName: productName)
    }

    /// Текущая поза очков.
    ///
    /// - Parameter predictTime: на сколько вперёд предсказать позу, секунды.
    /// - Returns: поза либо `nil`, если SDK её не отдал.
    func pose(predictTime: Double = 0) -> ViturePose? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return nil }
        guard let pose = device.pose(predictTime: predictTime) else { return lastPose }
        lastPose = pose
        lastPoseTime = ProcessInfo.processInfo.systemUptime
        return pose
    }

    /// Возраст последней полученной позы, секунды; `nil`, если позы ещё не было.
    var poseAge: Double? {
        lock.lock()
        defer { lock.unlock() }
        guard lastPose != nil else { return nil }
        return ProcessInfo.processInfo.systemUptime - lastPoseTime
    }

    /// Переносит опору мира в текущее положение и курс.
    ///
    /// Наклон к гравитации SDK не трогает: горизонт после этого остаётся верным.
    @discardableResult
    func recenter() -> Bool {
        guard let current = pose(predictTime: 0) else { return false }
        return device.resetOrigin(to: current)
    }

    /// Останавливает трекинг. Повторный запуск требует нового трекера.
    func stop() {
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
        VitureUSB.connectedDevices().contains { $0.productID == productID }
    }
}
