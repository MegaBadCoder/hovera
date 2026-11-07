import Foundation
import Testing
import simd
@testable import VitureSDK

private let yawAxis = SIMD3<Double>(0, 1, 0)

@Test func stablePoseDefinesTheOrientation() {
    var fusion = VitureOrientationFusion()
    let pose = simd_quatd(angle: 0.4, axis: yawAxis)
    var output: simd_quatd?
    for step in 0..<240 {
        output = fusion.update(pose: pose, stable: true, gyro: .zero, time: Double(step) / 120)
    }
    let angle = 2 * acos(min(1, abs((output ?? simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)).vector.z)))
    #expect(angle >= 0)
    let difference = (output ?? simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)) * pose.inverse
    #expect(abs(2 * acos(min(1, abs(difference.real)))) < 0.01)
}

@Test func unstablePoseDoesNotDragTheWorld() {
    var fusion = VitureOrientationFusion()
    _ = fusion.update(pose: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), stable: true, gyro: .zero, time: 0)
    let drifted = simd_quatd(angle: 0.8, axis: yawAxis)
    var output = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    for step in 1...120 {
        output = fusion.update(pose: drifted, stable: false, gyro: .zero, time: Double(step) / 120) ?? output
    }
    #expect(abs(2 * acos(min(1, abs(output.real)))) < 0.01)
}

@Test func gyroCarriesTheOrientationWhenPoseIsUnstable() {
    var fusion = VitureOrientationFusion()
    _ = fusion.update(pose: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), stable: true, gyro: .zero, time: 0)
    let rate = SIMD3<Double>(0, 1, 0)
    var output = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    for step in 1...120 {
        output = fusion.update(pose: nil, stable: false, gyro: rate, time: Double(step) / 120) ?? output
    }
    let yaw = output.yawPitch.yaw
    #expect(abs(yaw - 1.0) < 0.05)
}

@Test func gyroBiasIsLearnedAtRest() {
    var fusion = VitureOrientationFusion()
    let bias: SIMD3<Double> = [0.01, 0, 0]
    for step in 0...2000 {
        _ = fusion.update(pose: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), stable: true, gyro: bias, time: Double(step) / 120)
    }
    #expect(abs(fusion.gyroBias.x - 0.01) < 0.002)
}
