import Foundation
import Testing
import simd
@testable import RayDeskCore

private let hardIron = SIMD3(19.7, 77.3, -28.9)
private let earthField = simd_normalize(SIMD3(0.0, -0.64, -0.77)) * 34

private func randomRotation(_ generator: inout SystemRandomNumberGenerator) -> simd_quatd {
    let axis = simd_normalize(SIMD3(Double.random(in: -1...1, using: &generator), Double.random(in: -1...1, using: &generator), Double.random(in: -1...1, using: &generator)))
    return simd_quatd(angle: Double.random(in: 0..<(2 * .pi), using: &generator), axis: axis)
}

@Test func fitterRecoversHardIronCenterRadiusAndDip() throws {
    var generator = SystemRandomNumberGenerator()
    var fitter = HardIronFitter()
    for _ in 0..<3000 {
        let head = randomRotation(&generator)
        let noise = SIMD3(Double.random(in: -0.3...0.3, using: &generator), Double.random(in: -0.3...0.3, using: &generator), Double.random(in: -0.3...0.3, using: &generator))
        fitter.add(magnetometer: head.inverse.act(earthField) + hardIron + noise, up: head.inverse.act(SIMD3(0, 1, 0)))
    }
    let calibration = try fitter.result()

    #expect(length(calibration.center - hardIron) < 0.5)
    #expect(abs(calibration.radius - 34) < 0.3)
    let expectedDip = acos(simd_dot(simd_normalize(earthField), SIMD3(0, 1, 0)))
    #expect(abs(calibration.dip - expectedDip) < 1 * .pi / 180)
}

@Test func turningOnlyAroundVerticalIsNotEnoughCoverage() {
    var fitter = HardIronFitter()
    for step in 0..<3000 {
        let head = simd_quatd(angle: Double(step) * 0.01, axis: SIMD3(0, 1, 0))
        fitter.add(magnetometer: head.inverse.act(earthField) + hardIron, up: head.inverse.act(SIMD3(0, 1, 0)))
    }
    #expect(throws: MagnetometerCalibrationError.self) { try fitter.result() }
}

@Test func tooFewSamplesAreRejected() {
    var fitter = HardIronFitter()
    fitter.add(magnetometer: hardIron + earthField, up: SIMD3(0, 1, 0))
    #expect(throws: MagnetometerCalibrationError.tooFewSamples(1)) { try fitter.result() }
}

@Test func recordedWearFitsTheSameSphere() throws {
    var fitter = HardIronFitter()
    for row in try Fixture.rows("carousel.csv.lzfse") {
        fitter.add(magnetometer: SIMD3(row[9], -row[8], row[10]), up: simd_normalize(SIMD3(row[1], row[2], row[3])))
    }
    let calibration = try fitter.result()
    #expect(length(calibration.center - hardIron) < 2)
    #expect(abs(calibration.radius - 33.5) < 1.5)
}

@Test func magnetometerCalibrationRoundTripsThroughCodable() throws {
    let calibration = MagnetometerCalibration(center: hardIron, radius: 34, dip: 0.9)
    let decoded = try JSONDecoder().decode(MagnetometerCalibration.self, from: JSONEncoder().encode(calibration))
    #expect(decoded == calibration)
}
