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
    /// Колбэк Carina: буфер выбранного формата и исходная метка времени, секунды.
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
    private typealias NativePoseFunction = @convention(c) (UnsafeMutablePointer<Float>?, Double) -> Int32
    private var nativePoseFunction: NativePoseFunction?
    private var nativeHandle: UnsafeMutableRawPointer?
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
    typealias GetFilmFunction = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<Float>?) -> Int32
    typealias SetFilmFunction = @convention(c) (UnsafeMutableRawPointer?, Float) -> Int32
    private let getFilmFunction: GetFilmFunction?
    private let setFilmFunction: SetFilmFunction?
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

    /// Каталог, куда SDK кладёт кеш калибровки; создаётся при необходимости.
    ///
    /// - Returns: `~/Library/Caches/RayDesk/viture` либо `nil`, если каталог не создать.
    public static func defaultCacheDirectory() -> String? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return cacheDirectory(base: base)
    }

    static func cacheDirectory(base: URL) -> String? {
        let directory = base.appendingPathComponent("RayDesk/viture", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory.path
        } catch {
            return nil
        }
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
        getFilmFunction = try? symbol("xr_device_provider_get_film_mode", as: GetFilmFunction.self)
        setFilmFunction = try? symbol("xr_device_provider_set_film_mode", as: SetFilmFunction.self)
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

    /// Загруженные библиотеки живут до конца процесса.
    ///
    /// `dlclose` вызывал падение при выходе: SDK держит собственные статические
    /// объекты и потоки, и их уничтожение в произвольный момент роняет процесс.
    private static let loadedLock = NSLock()
    nonisolated(unsafe) private static var loaded: [VitureLibrary] = []


    /// Оставляет библиотеку загруженной до конца процесса.
    public func retainForProcessLifetime() {
        Self.loadedLock.lock()
        Self.loaded.append(self)
        Self.loadedLock.unlock()
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

    func prepareNativePose() -> Bool {
        if nativePoseFunction != nil { return true }
        var pointer = dlsym(handle, "carina_a1088_viture_get_gl_pose")
        if pointer == nil {
            let sibling = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("libcarina_vio.dylib").path
            nativeHandle = dlopen(sibling, RTLD_NOW | RTLD_LOCAL)
            if let nativeHandle { pointer = dlsym(nativeHandle, "carina_a1088_viture_get_gl_pose") }
        }
        guard let pointer else { return false }
        nativePoseFunction = unsafeBitCast(pointer, to: NativePoseFunction.self)
        return true
    }

    func nativePose(at timestamp: Double) -> ViturePose? {
        guard timestamp.isFinite, timestamp >= 0, let nativePoseFunction else { return nil }
        var values = [Float](repeating: .nan, count: 32)
        guard nativePoseFunction(&values, timestamp) == 0 else { return nil }
        return ViturePose(nativeGL: values, timestamp: timestamp)
    }

    func resetOrigin(_ handle: UnsafeMutableRawPointer, to pose: ViturePose) -> Int32 {
        var values = pose.floats
        return resetOriginFunction(handle, &values)
    }

    func filmMode(_ handle: UnsafeMutableRawPointer) -> Float? {
        var value: Float = 0
        guard getFilmFunction?(handle, &value) == 0, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }

    func setFilmMode(_ handle: UnsafeMutableRawPointer, value: Float) -> Bool {
        guard value.isFinite, (0...1).contains(value) else { return false }
        return setFilmFunction?(handle, value) == 0
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
    private var handle: UnsafeMutableRawPointer?
    private var didStop = false
    private let callbackOwner = UUID()

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

    deinit { close() }

    /// Останавливает потоки SDK и освобождает устройство и обработчики; повторный вызов безопасен.
    /// Вызывать последовательно с остальными методами устройства, после завершения опроса позы.
    public func close() {
        guard let handle else { return }
        if !didStop { _ = library.stop(handle) }
        _ = library.shutdown(handle)
        library.destroy(handle)
        self.handle = nil
        VitureCallbacks.shared.clear(owner: callbackOwner)
    }

    /// Текущее затемнение линз в диапазоне 0…1; `nil`, если SDK не поддерживает чтение.
    public func filmMode() -> Float? {
        guard let handle else { return nil }
        return library.filmMode(handle)
    }

    /// Устанавливает затемнение линз: 0 — прозрачные, 1 — полностью затемнённые.
    /// Возвращает `false`, если значение недопустимо или устройство отклонило команду.
    public func setFilmMode(_ value: Float) -> Bool {
        guard let handle else { return false }
        return library.setFilmMode(handle, value: value)
    }

    /// Включает или выключает 6DoF. Вызывать до `initialize`.
    @discardableResult
    public func setSixDegreesOfFreedom(_ is6DOF: Bool) -> Bool {
        guard let handle else { return false }
        return library.setSixDegreesOfFreedom(handle, is6DOF: is6DOF) == 0
    }

    /// Готовит SDK к работе.
    ///
    /// - Parameters:
    ///   - config: необязательная строка конфигурации SDK.
    ///   - cacheDirectory: куда SDK кладёт кеш калибровки; `nil` — выбор SDK.
    /// - Returns: `true`, если инициализация прошла.
    public func initialize(config: String? = nil, cacheDirectory: String? = nil) -> Bool {
        guard let handle else { return false }
        return library.initialize(handle, config: config, cacheDirectory: cacheDirectory) == 0
    }

    /// Доступен ли запрос OpenGL-матрицы по исходной метке Carina после инициализации.
    public var supportsNativePose: Bool { library.prepareNativePose() }

    /// Возвращает OpenGL-позу на время Carina, в секундах; статус устойчивости требует 6DoF.
    /// Вызывать в одной очереди с управлением устройством. При ошибке SDK возвращает `nil`.
    public func nativePose(at timestamp: Double) -> ViturePose? {
        guard handle != nil, library.prepareNativePose() else { return nil }
        return library.nativePose(at: timestamp)
    }

    /// Запускает поток данных устройства.
    @discardableResult
    public func start() -> Bool {
        guard let handle else { return false }
        didStop = false
        let result = library.start(handle) == 0
        return result
    }

    /// Останавливает поток данных, не уничтожая устройство.
    @discardableResult
    public func stop() -> Bool {
        guard let handle, !didStop else { return true }
        let result = library.stop(handle) == 0
        if result { didStop = true }
        VitureCallbacks.shared.clear(owner: callbackOwner)
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
    ///   - poseClock: исходная метка Carina, секунды; требует конфигурации формата callback и исключает `pose`.
    @discardableResult
    public func registerCallbacks(pose: ((ViturePose) -> Void)? = nil,
                                  vsync: ((Double) -> Void)? = nil,
                                  imu: ((SIMD3<Double>, SIMD3<Double>, Double) -> Void)? = nil,
                                  poseClock: ((Double) -> Void)? = nil) -> Bool {
        guard let handle else { return false }
        guard pose == nil || poseClock == nil else { return false }
        VitureCallbacks.shared.set(owner: callbackOwner, pose: pose, vsync: vsync, imu: imu, poseClock: poseClock)
        let registered = library.registerCallbacks(handle,
                                         pose: pose == nil && poseClock == nil ? nil : viturePoseTrampoline,
                                         vsync: vsync == nil ? nil : vitureVSyncTrampoline,
                                         imu: imu == nil ? nil : vitureImuTrampoline) == 0
        if !registered { VitureCallbacks.shared.clear(owner: callbackOwner) }
        return registered
    }

    /// Опрашивает позу.
    ///
    /// - Parameter predictTime: на сколько вперёд предсказать позу, секунды; 0 — текущая.
    /// - Returns: поза либо `nil`, если SDK не отдал её.
    public func pose(predictTime: Double = 0) -> ViturePose? {
        guard let handle else { return nil }
        return library.pose(handle, predictTime: predictTime)?.pose
    }

    /// Переносит начало координат трекинга.
    ///
    /// Позиция и курс встают по переданной позе, pitch и roll остаются привязанными к гравитации.
    ///
    /// - Parameter pose: новая опора, обычно результат `pose(predictTime: 0)`.
    @discardableResult
    public func resetOrigin(to pose: ViturePose) -> Bool {
        guard let handle else { return false }
        return library.resetOrigin(handle, to: pose) == 0
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
    private var owner: UUID?
    private var poseHandler: ((ViturePose) -> Void)?
    private var vsyncHandler: ((Double) -> Void)?
    private var imuHandler: ((SIMD3<Double>, SIMD3<Double>, Double) -> Void)?
    private var poseClockHandler: ((Double) -> Void)?

    func set(owner: UUID, pose: ((ViturePose) -> Void)?, vsync: ((Double) -> Void)?, imu: ((SIMD3<Double>, SIMD3<Double>, Double) -> Void)?, poseClock: ((Double) -> Void)? = nil) {
        lock.lock()
        self.owner = owner
        poseHandler = pose
        vsyncHandler = vsync
        imuHandler = imu
        poseClockHandler = poseClock
        lock.unlock()
    }

    func clear(owner: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard self.owner == owner else { return }
        self.owner = nil
        poseHandler = nil
        vsyncHandler = nil
        imuHandler = nil
        poseClockHandler = nil
    }

    func handlePose(_ pose: UnsafeMutablePointer<Float>, timestamp: Double) {
        lock.lock()
        let handler = poseHandler
        let clockHandler = poseClockHandler
        lock.unlock()
        if let clockHandler { clockHandler(timestamp); return }
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
