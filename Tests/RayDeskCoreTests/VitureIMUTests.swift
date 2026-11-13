import Foundation
import Testing
import simd
@testable import VitureSDK

@Test func carinaIMUVectorsMatchSDKDisplayTransform() {
    let displayFromIMU = simd_double3x3(columns: (
        SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, 1, 0)
    ))
    for raw in [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(0.22, 1.54, 9.69)] {
        #expect(VitureIMU.bodyAngularVelocity(raw) == displayFromIMU * raw)
        #expect(VitureIMU.bodyAcceleration(raw) == displayFromIMU * raw)
    }
}

@Test func carinaPitchPredictionDoesNotBecomeRoll() {
    let head = simd_quatd(angle: 0.4, axis: SIMD3(0, 1, 0))
        * simd_quatd(angle: -0.2, axis: SIMD3(1, 0, 0))
    let pose = ViturePose(position: .zero, orientation: head, timestamp: 1, isStable: true)
    let predicted = pose.extrapolated(by: 0.03, rate: VitureIMU.bodyAngularVelocity(SIMD3(1, 0, 0)))
    let expected = head * simd_quatd(angle: -0.03, axis: SIMD3(1, 0, 0))
    #expect(length(predicted.orientation.act(SIMD3(0, 0, -1)) - expected.act(SIMD3(0, 0, -1))) < 1e-9)
    #expect(length(predicted.orientation.act(SIMD3(0, 1, 0)) - expected.act(SIMD3(0, 1, 0))) < 1e-9)
}

@Test func carinaRollPredictionDoesNotBecomePitch() {
    let pose = ViturePose(position: .zero, orientation: simd_quatd(angle: 0.4, axis: SIMD3(0, 1, 0)), timestamp: 1, isStable: true)
    let predicted = pose.extrapolated(by: 0.03, rate: VitureIMU.bodyAngularVelocity(SIMD3(0, 1, 0)))
    #expect(length(predicted.orientation.act(SIMD3(0, 0, -1)) - pose.orientation.act(SIMD3(0, 0, -1))) < 1e-9)
    #expect(length(predicted.orientation.act(SIMD3(0, 1, 0)) - pose.orientation.act(SIMD3(0, 1, 0))) > 0.02)
}

@Test func degreesAreConvertedToRadians() {
    let radians = VitureIMU.radiansPerSecond(SIMD3(0, 180, 0), unit: .degrees)
    #expect(abs(radians.y - .pi) < 1e-6)
}

@Test func smallRatesAreLeftAlone() {
    #expect(VitureIMU.radiansPerSecond(SIMD3(0, 0.5, 0)) == SIMD3(0, 0.5, 0))
}

@Test func angularVelocityScaleDoesNotJumpAtTwenty() {
    let below = VitureIMU.radiansPerSecond(SIMD3(0, 19.9, 0)).y
    let above = VitureIMU.radiansPerSecond(SIMD3(0, 20.1, 0)).y
    #expect(abs(above - below - 0.2) < 1e-6)
}

@Test func slowDegreesUseTheSameUnitsAsFastDegrees() {
    #expect(abs(VitureIMU.radiansPerSecond(SIMD3(0, 0.5, 0), unit: .degrees).y - 0.5 * .pi / 180) < 1e-9)
}
