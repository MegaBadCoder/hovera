import Foundation
import simd

/// Один отсчёт инерциального измерительного блока очков: угловая скорость,
/// ускорение и время с предыдущего отсчёта.
public struct IMUSample {
    /// Угловая скорость по осям тела, рад/с.
    public var gyro: SIMD3<Double>
    /// Ускорение по осям тела в единицах g (1g = 9.80665 м/с²).
    public var accel: SIMD3<Double>
    /// Время с предыдущего отсчёта, секунды.
    public var dt: Double
}

/// Протокол USB HID очков RayNeo: идентификаторы устройства, команды
/// управления IMU и декодер бинарных отчётов.
public enum RayNeoProtocol {
    public static let vendorID = 0x1BBB
    public static let productID = 0xAF50
    public static let startIMUCommand: [UInt8] = [0x66, 0x01, 0x00]
    public static let stopIMUCommand: [UInt8] = [0x66, 0x02, 0x00]

    private static let frameMagic: UInt8 = 0x99
    private static let imuFrameType: UInt8 = 0x65
    private static let ticksPerSecond = 10_000.0
    private static let standardGravity = 9.80665

    /// Декодер потока HID-отчётов IMU в `IMUSample`.
    ///
    /// Хранит номер последнего тика, чтобы вычислять `dt`: поэтому первый
    /// принятый кадр и кадр с повторным тиком декодируются в `nil`.
    public struct Decoder {
        private var lastTick: UInt32?

        public init() {}

        /// Разбирает один HID-отчёт.
        ///
        /// - Parameter report: сырые байты отчёта (минимум 44 байта, заголовок
        ///   `0x99 0x65`, ускорение и гироскоп float32 LE, тик u32 LE на смещении 40).
        /// - Returns: `IMUSample` с ускорением в g и гироскопом в рад/с, либо
        ///   `nil`, если отчёт не распознан, это первый кадр или тик повторился.
        public mutating func decode(_ report: UnsafeBufferPointer<UInt8>) -> IMUSample? {
            guard report.count >= 44, report[0] == frameMagic, report[1] == imuFrameType, let base = report.baseAddress else { return nil }
            func float(_ offset: Int) -> Double { Double(UnsafeRawPointer(base + offset).loadUnaligned(as: Float32.self)) }

            let tick = UInt32(littleEndian: UnsafeRawPointer(base + 40).loadUnaligned(as: UInt32.self))
            defer { lastTick = tick }
            guard let lastTick, tick != lastTick else { return nil }

            let accel = SIMD3(float(4), float(8), float(12)) / standardGravity
            let gyro = SIMD3(float(16), float(20), float(24)) * (.pi / 180)
            return IMUSample(gyro: gyro, accel: accel, dt: Double(tick &- lastTick) / ticksPerSecond)
        }
    }
}
