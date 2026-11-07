import Foundation
import Testing
import simd
@testable import VitureSDK

@Test func nwuAxesAreMappedToOpenGLAxes() {
    // Вперёд (NWU X) — это «назад» в OpenGL: поворот вокруг него даёт минус по Z.
    #expect(VitureIMU.bodyAngularVelocity(SIMD3(1, 0, 0)) == SIMD3(0, 0, -1))
    // Влево (NWU Y) — это «влево» в OpenGL, то есть минус по X.
    #expect(VitureIMU.bodyAngularVelocity(SIMD3(0, 1, 0)) == SIMD3(-1, 0, 0))
    // Вверх (NWU Z) совпадает с осью Y в OpenGL.
    #expect(VitureIMU.bodyAngularVelocity(SIMD3(0, 0, 1)) == SIMD3(0, 1, 0))
}

@Test func degreesAreConvertedToRadians() {
    let radians = VitureIMU.radiansPerSecond(SIMD3(0, 180, 0))
    #expect(abs(radians.y - .pi) < 1e-6)
}

@Test func smallRatesAreLeftAlone() {
    #expect(VitureIMU.radiansPerSecond(SIMD3(0, 0.5, 0)) == SIMD3(0, 0.5, 0))
}
