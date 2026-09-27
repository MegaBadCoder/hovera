import Testing
import Foundation
@testable import RayDeskCore

private let frameA: [UInt8] = [
    0x99, 0x65, 0x40, 0x00, 0x89, 0x6e, 0x4d, 0x3f, 0xba, 0xd3, 0x1d, 0x41, 0x1a, 0xb2, 0x57, 0x3c,
    0x2c, 0x7b, 0x97, 0x40, 0x5c, 0x94, 0x1d, 0xbf, 0xbd, 0x3a, 0xb5, 0xbf, 0x00, 0x1c, 0x19, 0x42,
    0x00, 0x00, 0x48, 0xc5, 0x00, 0x00, 0x48, 0xc5, 0xec, 0x82, 0xe0, 0x00, 0x00, 0xbc, 0x08, 0x46,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x48, 0x45, 0xec, 0x82, 0xe0, 0x00, 0xec, 0x82, 0xe0, 0x00,
]

private let frameB: [UInt8] = [
    0x99, 0x65, 0x40, 0x00, 0x24, 0x83, 0x28, 0x3f, 0x13, 0x5e, 0x1d, 0x41, 0x89, 0xac, 0xa6, 0x3c,
    0x60, 0xea, 0xd5, 0xbf, 0xf2, 0x3c, 0x48, 0xbe, 0x5e, 0x2e, 0x26, 0x3f, 0x00, 0xf8, 0x18, 0x42,
    0x00, 0x00, 0xc8, 0xc2, 0x00, 0x00, 0x48, 0xc0, 0xd2, 0xa9, 0xe0, 0x00, 0x00, 0x90, 0x07, 0x46,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x98, 0xb7, 0xc1, 0xa6, 0xa9, 0xe0, 0x00, 0xa6, 0xa9, 0xe0, 0x00,
]

private func withTick(_ frame: [UInt8], _ tick: UInt32) -> [UInt8] {
    var copy = frame
    withUnsafeBytes(of: tick.littleEndian) { bytes in
        copy.replaceSubrange(40..<44, with: bytes)
    }
    return copy
}

private func decode(_ decoder: inout RayNeoProtocol.Decoder, _ frame: [UInt8]) -> IMUSample? {
    frame.withUnsafeBufferPointer { decoder.decode($0) }
}

@Test func firstFrameHasNoPreviousTickAndReturnsNil() {
    var decoder = RayNeoProtocol.Decoder()
    #expect(decode(&decoder, frameA) == nil)
}

@Test func secondFrameDecodesRealAccelAndGyro() throws {
    var decoder = RayNeoProtocol.Decoder()
    _ = decode(&decoder, frameA)
    let sample = decode(&decoder, withTick(frameA, 0x00E082EC &+ 84))
    let s = try #require(sample)

    #expect(abs(s.accel.x - 0.0818) < 0.001)
    #expect(abs(s.accel.y - 1.0059) < 0.001)
    #expect(abs(s.accel.z - 0.001342) < 0.001)

    #expect(abs(s.gyro.x - 0.08262) < 0.0005)
    #expect(abs(s.gyro.y - (-0.010743)) < 0.0005)
    #expect(abs(s.gyro.z - (-0.024711)) < 0.0005)

    #expect(abs(s.dt - 0.0084) < 1e-9)
}

@Test func repeatedTickIsRejected() {
    var decoder = RayNeoProtocol.Decoder()
    _ = decode(&decoder, frameA)
    #expect(decode(&decoder, frameA) == nil)
}

@Test func tickWraparoundProducesCorrectDt() throws {
    var decoder = RayNeoProtocol.Decoder()
    _ = decode(&decoder, withTick(frameA, 0xFFFFFFF0))
    let sample = decode(&decoder, withTick(frameA, 0x0000000C))
    let s = try #require(sample)
    #expect(abs(s.dt - 0.0028) < 1e-9)
}

@Test func badMagicIsRejected() {
    var decoder = RayNeoProtocol.Decoder()
    _ = decode(&decoder, frameA)
    var corrupted = withTick(frameA, 0x00E082EC &+ 84)
    corrupted[0] = 0x00
    #expect(decode(&decoder, corrupted) == nil)
}

@Test func badFrameTypeIsRejected() {
    var decoder = RayNeoProtocol.Decoder()
    _ = decode(&decoder, frameA)
    var corrupted = withTick(frameA, 0x00E082EC &+ 84)
    corrupted[1] = 0x00
    #expect(decode(&decoder, corrupted) == nil)
}

@Test func secondCapturedFrameDecodesToPlausibleSample() throws {
    var decoder = RayNeoProtocol.Decoder()
    _ = decode(&decoder, frameB)
    let sample = decode(&decoder, withTick(frameB, 0x00E0A9D2 &+ 20))
    let s = try #require(sample)
    #expect(abs(s.dt - 0.0020) < 1e-9)
    #expect(abs(s.accel.x - 0.06712) < 0.001)
    #expect(abs(s.accel.y - 1.00294) < 0.001)
    #expect(abs(s.gyro.y - (-0.003413)) < 0.0005)
}

@Test func magnetometerIsReturnedInBodyAxes() throws {
    var decoder = RayNeoProtocol.Decoder()
    _ = decode(&decoder, frameA)
    let sample = try #require(decode(&decoder, frameB))
    let magnetometer = try #require(sample.magnetometer)
    #expect(abs(magnetometer.x - -3.125) < 1e-6)
    #expect(abs(magnetometer.y - 100) < 1e-6)
    #expect(abs(magnetometer.z - -22.9492) < 1e-3)
    #expect(abs(sample.temperature - 38.24) < 0.01)
}

@Test func placeholderMagnetometerIsDropped() throws {
    var decoder = RayNeoProtocol.Decoder()
    _ = decode(&decoder, frameA)
    let sample = try #require(decode(&decoder, withTick(frameA, 0x00E082EC &+ 84)))
    #expect(sample.magnetometer == nil)
}

@Test func carouselFixtureLoads() throws {
    let rows = try Fixture.rows("carousel.csv.lzfse")
    #expect(rows.count == 164_996)
    #expect(rows.allSatisfy { $0.count == 11 })
}
