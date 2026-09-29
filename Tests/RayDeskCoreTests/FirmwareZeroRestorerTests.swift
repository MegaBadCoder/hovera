import Foundation
import Testing
import simd
@testable import RayDeskCore

private let lsb = FirmwareZeroRestorer.step

/// Имитация прошивки: целые шаги решётки минус своё смещение; по `updateAt` смещение
/// сдвигается на среднее последних 1000 выданных отсчётов, как делают очки.
private struct FakeFirmware {
    var offset = SIMD3(0.0123, -0.0071, 0.0049) * .pi / 180
    var history: [SIMD3<Double>] = []

    mutating func output(raw: SIMD3<Double>, update: Bool) -> SIMD3<Double> {
        let counts = (raw / lsb).rounded(.toNearestOrEven)
        if update, history.count >= FirmwareZeroRestorer.window {
            var window = history.suffix(FirmwareZeroRestorer.window - 1).reduce(SIMD3<Double>.zero, +)
            window += counts * lsb - offset
            offset += window / Double(FirmwareZeroRestorer.window)
        }
        let value = counts * lsb - offset
        history.append(value)
        return value
    }
}

private func slowHead(_ i: Int) -> SIMD3<Double> {
    let t = Double(i) * 0.002
    return SIMD3(sin(t * 0.7) * 1.5, cos(t * 0.4) * 2.0, sin(t * 1.3 + 1) * 0.8) * .pi / 180
}

@Test func restoresFirmwareZeroUpdatesToAConstantOffset() {
    var firmware = FakeFirmware()
    var restorer = FirmwareZeroRestorer()
    let updates: Set<Int> = [2000, 3000, 4000, 7321, 9000]
    var firstDifference: SIMD3<Double>?
    var worst = 0.0
    for i in 0..<12000 {
        let raw = slowHead(i)
        let restored = restorer.restore(firmware.output(raw: raw, update: updates.contains(i)))
        let quantized = (raw / lsb).rounded(.toNearestOrEven) * lsb
        let difference = restored - quantized
        if let firstDifference {
            worst = max(worst, abs(difference - firstDifference).max())
        } else {
            firstDifference = difference
        }
    }
    #expect(restorer.restoredUpdates == updates.count)
    #expect(worst < 1e-9)
}

@Test func leavesSignalWithoutLatticeUntouched() {
    var restorer = FirmwareZeroRestorer()
    for i in 0..<5000 {
        let gyro = slowHead(i) + SIMD3(0.001, -0.002, 0.0005) * Double(i % 7)
        #expect(restorer.restore(gyro) == gyro)
    }
    #expect(restorer.restoredUpdates == 0)
}

@Test func ignoresLatticeJumpsThatAreNotAFirmwareUpdate() {
    var firmware = FakeFirmware()
    var restorer = FirmwareZeroRestorer()
    for i in 0..<3000 {
        var raw = slowHead(i)
        if i >= 2000 { raw += SIMD3(0.3, -0.2, 0.1) }
        let output = firmware.output(raw: raw, update: false)
        let shifted = i >= 2500 ? output + SIMD3(0.37, 0.11, -0.23) * lsb : output
        #expect(restorer.restore(shifted) == shifted)
    }
    #expect(restorer.restoredUpdates == 0)
}

@Test func orientationFilterRestoresFirmwareZeroByDefault() {
    let moving = OrientationFilter()
    var movingFirmware = FakeFirmware()
    for i in 0..<6000 {
        let gyro = movingFirmware.output(raw: slowHead(i), update: i == 3000)
        moving.update(gyro: gyro, accel: SIMD3(0, 1, 0), dt: 0.002)
    }
    #expect(moving.restoredFirmwareUpdates == 1)
}
