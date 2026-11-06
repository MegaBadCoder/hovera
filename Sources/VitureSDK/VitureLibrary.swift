import Foundation

/// Загрузчик официального SDK VITURE через `dlopen`.
///
/// SDK распространяется как `libglasses.dylib` (macOS, aarch64) с C-интерфейсом.
/// Жёсткая линковка сделала бы Hovera неработоспособной без установленного SDK,
/// поэтому библиотека подгружается по требованию, а её отсутствие — штатная
/// ситуация: очки RayNeo продолжают работать как раньше.
public final class VitureLibrary: @unchecked Sendable {
    /// Ошибки загрузки SDK.
    public enum LoadError: Error, Equatable {
        /// Библиотека не найдена ни по одному из путей.
        case notFound([String])
        /// В библиотеке нет нужной функции.
        case missingSymbol(String)
    }

    /// Тип функции `xr_device_provider_create`.
    typealias CreateFunction = @convention(c) (Int32) -> UnsafeMutableRawPointer?
    /// Тип функции `xr_device_provider_initialize`.
    typealias InitializeFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Int32
    /// Тип функций `xr_device_provider_start/stop/shutdown`, у которых один аргумент — дескриптор.
    typealias HandleFunction = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    /// Тип функции `xr_device_provider_destroy`.
    typealias DestroyFunction = @convention(c) (UnsafeMutableRawPointer?) -> Void
    /// Тип функции `xr_device_provider_get_device_type`.
    typealias DeviceTypeFunction = @convention(c) (UnsafeMutableRawPointer?) -> Int32
    /// Тип функции `xr_device_provider_set_dof_type_carina`.
    typealias SetDofFunction = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    /// Тип функции `xr_device_provider_get_gl_pose_carina`.
    typealias GetPoseFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Float>?, Double, UnsafeMutablePointer<Int32>?) -> Int32
    /// Тип функции `xr_device_provider_reset_origin_carina`.
    typealias ResetOriginFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Float>?) -> Int32
    /// Колбэк позы: 7 чисел и метка времени.
    typealias PoseCallback = @convention(c) (UnsafeMutablePointer<Float>?, Double) -> Void
    /// Колбэк вертикальной синхронизации.
    typealias VSyncCallback = @convention(c) (Double) -> Void
    /// Колбэк IMU: ускорение и угловая скорость, метка времени.
    typealias ImuCallback = @convention(c) (UnsafeMutablePointer<Float>?, Double) -> Void
    /// Колбэк стереокадров; в Hovera пока не используется, но обязателен в сигнатуре регистрации.
    typealias CameraCallback = @convention(c) (UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<CChar>?,
                                               UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<CChar>?,
                                               Double, Int32, Int32) -> Void
    /// Тип функции `xr_device_provider_register_callbacks_carina`.
    typealias RegisterCallbacksFunction = @convention(c) (UnsafeMutableRawPointer?, PoseCallback?, VSyncCallback?,
                                                          ImuCallback?, CameraCallback?) -> Int32
    /// Тип функций, проверяющих корректность product id и поддержку частоты IMU.
    typealias ProductPredicateFunction = @convention(c) (Int32) -> Int32
    /// Тип функции `xr_device_provider_is_product_support_imu_frequency`.
    typealias ImuFrequencyPredicateFunction = @convention(c) (Int32, Int32, Int32) -> Int32

    /// Путь, откуда загружена библиотека.
    public let path: String

    private let handle: UnsafeMutableRawPointer
    private let createFunction: CreateFunction
    private let initializeFunction: InitializeFunction
    private let startFunction: HandleFunction
    private let stopFunction: HandleFunction
    private let shutdownFunction: HandleFunction
    private let destroyFunction: DestroyFunction
    private let deviceTypeFunction: DeviceTypeFunction
    private let setDofFunction: SetDofFunction
    private let getPoseFunction: GetPoseFunction
    private let resetOriginFunction: ResetOriginFunction
    private let registerCallbacksFunction: RegisterCallbacksFunction
    private let isProductIDValidFunction: ProductPredicateFunction

    /// Пути, где Hovera ищет SDK, в порядке приоритета.
    ///
    /// - `VITURE_SDK_DIR` — каталог для разработки, указывает прямо на распакованный SDK;
    /// - `Frameworks` внутри запущенного приложения — обычное место при поставке;
    /// - `Vendor/viture/aarch64` рядом с проектом — для запуска из Xcode без сборки app bundle.
    public static func defaultSearchPaths(bundle: Bundle = .main, environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var paths: [String] = []
        if let directory = environment["VITURE_SDK_DIR"], !directory.isEmpty {
            paths.append((directory as NSString).appendingPathComponent("libglasses.dylib"))
            paths.append((directory as NSString).appendingPathComponent("aarch64/libglasses.dylib"))
        }
        if let frameworks = bundle.privateFrameworksURL {
            paths.append(frameworks.appendingPathComponent("libglasses.dylib").path)
        }
        if let cwd = FileManager.default.currentDirectoryPath.isEmpty ? nil : Optional(FileManager.default.currentDirectoryPath) {
            paths.append((cwd as NSString).appendingPathComponent("Vendor/viture/aarch64/libglasses.dylib"))
        }
        return paths
    }

    /// Загружает SDK из первого существующего пути.
    ///
    /// - Parameter searchPaths: кандидаты в порядке приоритета; по умолчанию `defaultSearchPaths()`.
    /// - Throws: `LoadError.notFound`, если ни один путь не существует; `LoadError.missingSymbol`, если в библиотеке нет функции.
    public static func load(searchPaths: [String] = VitureLibrary.defaultSearchPaths()) throws -> VitureLibrary {
        guard let path = searchPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            throw LoadError.notFound(searchPaths)
        }
        return try VitureLibrary(path: path)
    }

    /// Загружает конкретный файл SDK.
    ///
    /// - Parameter path: путь к `libglasses.dylib`.
    /// - Throws: `LoadError.missingSymbol` или `LoadError.notFound`.
    public init(path: String) throws {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw LoadError.notFound([path])
        }
        self.path = path
        self.handle = handle
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw LoadError.missingSymbol(name) }
            return unsafeBitCast(pointer, to: T.self)
        }
        createFunction = try symbol("xr_device_provider_create", as: CreateFunction.self)
        initializeFunction = try symbol("xr_device_provider_initialize", as: InitializeFunction.self)
        startFunction = try symbol("xr_device_provider_start", as: HandleFunction.self)
        stopFunction = try symbol("xr_device_provider_stop", as: HandleFunction.self)
        shutdownFunction = try symbol("xr_device_provider_shutdown", as: HandleFunction.self)
        destroyFunction = try symbol("xr_device_provider_destroy", as: DestroyFunction.self)
        deviceTypeFunction = try symbol("xr_device_provider_get_device_type", as: DeviceTypeFunction.self)
        setDofFunction = try symbol("xr_device_provider_set_dof_type_carina", as: SetDofFunction.self)
        getPoseFunction = try symbol("xr_device_provider_get_gl_pose_carina", as: GetPoseFunction.self)
        resetOriginFunction = try symbol("xr_device_provider_reset_origin_carina", as: ResetOriginFunction.self)
        registerCallbacksFunction = try symbol("xr_device_provider_register_callbacks_carina", as: RegisterCallbacksFunction.self)
        isProductIDValidFunction = try symbol("xr_device_provider_is_product_id_valid", as: ProductPredicateFunction.self)
    }

    deinit {
        dlclose(handle)
    }

    /// Создаёт дескриптор устройства.
    ///
    /// - Parameter productID: USB product id очков, например 0x1104 у Luma Ultra.
    /// - Returns: дескриптор либо `nil`, если очки не найдены или product id неизвестен.
    public func createDevice(productID: Int32) -> VitureDevice? {
        guard isProductIDValidFunction(productID) != 0, let handle = createFunction(productID) else { return nil }
        return VitureDevice(library: self, handle: handle)
    }

    func initialize(_ handle: UnsafeMutableRawPointer, config: String?, cacheDirectory: String?) -> Int32 {
        initializeFunction(handle, config, cacheDirectory)
    }

    func start(_ handle: UnsafeMutableRawPointer) -> Int32 { startFunction(handle) }
    func stop(_ handle: UnsafeMutableRawPointer) -> Int32 { stopFunction(handle) }
    func shutdown(_ handle: UnsafeMutableRawPointer) -> Int32 { shutdownFunction(handle) }
    func destroy(_ handle: UnsafeMutableRawPointer) { destroyFunction(handle) }
    func deviceType(_ handle: UnsafeMutableRawPointer) -> Int32 { deviceTypeFunction(handle) }
    func setSixDegreesOfFreedom(_ handle: UnsafeMutableRawPointer, is6DOF: Bool) -> Int32 { setDofFunction(handle, is6DOF ? 1 : 0) }

    func pose(_ handle: UnsafeMutableRawPointer, predictTime: Double) -> (pose: ViturePose?, status: Int32)? {
        var values = [Float](repeating: 0, count: 7)
        var poseStatus: Int32 = 0
        let result = getPoseFunction(handle, &values, predictTime, &poseStatus)
        guard result == 0 else { return nil }
        let pose = values.withUnsafeBufferPointer { buffer in
            ViturePose(floats: buffer.baseAddress!, timestamp: 0, isStable: poseStatus == 0)
        }
        return (pose, poseStatus)
    }

    func resetOrigin(_ handle: UnsafeMutableRawPointer, to pose: ViturePose) -> Int32 {
        var values = pose.floats
        return resetOriginFunction(handle, &values)
    }

    func registerCallbacks(_ handle: UnsafeMutableRawPointer,
                           pose: PoseCallback?, vsync: VSyncCallback?, imu: ImuCallback?) -> Int32 {
        registerCallbacksFunction(handle, pose, vsync, imu, nil)
    }
}

/// Обёртка над устройством VITURE.
///
/// Держит дескриптор SDK и не даёт забыть освободить его: `shutdown()` и `destroy()`
/// вызываются в `deinit`.
public final class VitureDevice: @unchecked Sendable {
    /// Тип устройства, как его называет SDK.
    public enum Kind: Int32, Sendable {
        case gen1 = 0
        case gen2 = 1
        case carina = 2
    }

    /// Модель очков.
    public let kind: Kind
    private let library: VitureLibrary
    private let handle: UnsafeMutableRawPointer
    private var started = false

    init?(library: VitureLibrary, handle: UnsafeMutableRawPointer) {
        let kind = Kind(rawValue: library.deviceType(handle))
        guard let kind else {
            library.destroy(handle)
            return nil
        }
        self.library = library
        self.handle = handle
        self.kind = kind
    }

    deinit {
        if started {
            _ = library.stop(handle)
            _ = library.shutdown(handle)
        }
        library.destroy(handle)
    }

    /// Включает или выключает 6DoF. Вызывать до `initialize`.
    @discardableResult
    public func setSixDegreesOfFreedom(_ is6DOF: Bool) -> Bool {
        library.setSixDegreesOfFreedom(handle, is6DOF: is6DOF) == 0
    }

    /// Готовит SDK к работе.
    ///
    /// - Parameters:
    ///   - config: необязательная строка конфигурации SDK.
    ///   - cacheDirectory: куда SDK кладёт кеш калибровки; `nil` — выбор SDK.
    /// - Returns: `true`, если инициализация прошла.
    public func initialize(config: String? = nil, cacheDirectory: String? = nil) -> Bool {
        library.initialize(handle, config: config, cacheDirectory: cacheDirectory) == 0
    }

    /// Запускает поток данных устройства.
    @discardableResult
    public func start() -> Bool {
        let result = library.start(handle) == 0
        started = result
        return result
    }

    /// Останавливает поток данных, не уничтожая устройство.
    @discardableResult
    public func stop() -> Bool {
        let result = library.stop(handle) == 0
        if result { started = false }
        return result
    }

    /// Регистрирует колбэки Carina-устройства.
    ///
    /// Колбэки SDK не принимают пользовательский контекст, поэтому Hovera держит
    /// один набор обработчиков на процесс: очки в системе одни.
    ///
    /// - Parameters:
    ///   - pose: поза с частотой камеры (25 Гц); можно не задавать, если позу опрашиваем сами.
    ///   - vsync: момент вертикальной синхронизации панели.
    ///   - imu: сырые IMU-отсчёты: ускорение и угловая скорость с меткой времени.
    @discardableResult
    public func registerCallbacks(pose: ((ViturePose) -> Void)? = nil,
                                  vsync: ((Double) -> Void)? = nil,
                                  imu: ((SIMD3<Double>, SIMD3<Double>, Double) -> Void)? = nil) -> Bool {
        VitureCallbacks.shared.set(pose: pose, vsync: vsync, imu: imu)
        return library.registerCallbacks(self.handle,
                                         pose: pose == nil ? nil : viturePoseTrampoline,
                                         vsync: vsync == nil ? nil : vitureVSyncTrampoline,
                                         imu: imu == nil ? nil : vitureImuTrampoline) == 0
    }

    /// Опрашивает позу.
    ///
    /// - Parameter predictTime: на сколько вперёд предсказать позу, секунды; 0 — текущая.
    /// - Returns: поза либо `nil`, если SDK не отдал её.
    public func pose(predictTime: Double = 0) -> ViturePose? {
        library.pose(handle, predictTime: predictTime)?.pose
    }

    /// Переносит начало координат трекинга.
    ///
    /// Позиция и курс встают по переданной позе, pitch и roll остаются привязанными к гравитации.
    ///
    /// - Parameter pose: новая опора, обычно результат `pose(predictTime: 0)`.
    @discardableResult
    public func resetOrigin(to pose: ViturePose) -> Bool {
        library.resetOrigin(handle, to: pose) == 0
    }
}


/// Обработчики колбэков SDK, общие на процесс.
///
/// SDK вызывает C-функции без пользовательского контекста (`XRPoseCallback` и родственные
/// типы его не принимают), поэтому связать вызов с конкретным устройством можно только
/// через общий реестр. В системе одни очки, так что реестр хранит один набор обработчиков.
final class VitureCallbacks: @unchecked Sendable {
    static let shared = VitureCallbacks()

    private let lock = NSLock()
    private var poseHandler: ((ViturePose) -> Void)?
    private var vsyncHandler: ((Double) -> Void)?
    private var imuHandler: ((SIMD3<Double>, SIMD3<Double>, Double) -> Void)?

    func set(pose: ((ViturePose) -> Void)?, vsync: ((Double) -> Void)?, imu: ((SIMD3<Double>, SIMD3<Double>, Double) -> Void)?) {
        lock.lock()
        poseHandler = pose
        vsyncHandler = vsync
        imuHandler = imu
        lock.unlock()
    }

    func handlePose(_ pose: UnsafeMutablePointer<Float>, timestamp: Double) {
        lock.lock()
        let handler = poseHandler
        lock.unlock()
        handler?(ViturePose(floats: pose, timestamp: timestamp, isStable: true))
    }

    func handleVSync(timestamp: Double) {
        lock.lock()
        let handler = vsyncHandler
        lock.unlock()
        handler?(timestamp)
    }

    func handleIMU(_ imu: UnsafeMutablePointer<Float>, timestamp: Double) {
        lock.lock()
        let handler = imuHandler
        lock.unlock()
        handler?(SIMD3(Double(imu[0]), Double(imu[1]), Double(imu[2])),
                 SIMD3(Double(imu[3]), Double(imu[4]), Double(imu[5])),
                 timestamp)
    }
}

private func viturePoseTrampoline(_ pose: UnsafeMutablePointer<Float>?, _ timestamp: Double) {
    guard let pose else { return }
    VitureCallbacks.shared.handlePose(pose, timestamp: timestamp)
}

private func vitureVSyncTrampoline(_ timestamp: Double) {
    VitureCallbacks.shared.handleVSync(timestamp: timestamp)
}

private func vitureImuTrampoline(_ imu: UnsafeMutablePointer<Float>?, _ timestamp: Double) {
    guard let imu else { return }
    VitureCallbacks.shared.handleIMU(imu, timestamp: timestamp)
}
