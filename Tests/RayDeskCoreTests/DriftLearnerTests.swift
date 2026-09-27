import Foundation
import Testing
@testable import RayDeskCore

private let degree = Double.pi / 180

@Test func presseswithinBurstAreCombinedAndLearnedOnlyAfterSettling() {
    var learner = DriftLearner(coefficient: 0)
    learner.recordCorrection(yaw: 0, at: 0, travel: 0)
    #expect(learner.settle(at: 10) == false)

    learner.recordCorrection(yaw: -3 * degree, at: 60, travel: 1000 * degree)
    learner.recordCorrection(yaw: -2 * degree, at: 61, travel: 1010 * degree)
    #expect(learner.settle(at: 62) == false)
    #expect(learner.coefficient == 0)

    #expect(learner.settle(at: 66) == true)
    let expected = (5 * degree) / (1000 * degree + DriftLearner.dampingTravel)
    #expect(abs(learner.coefficient - expected) < 1e-12)
}

@Test func correctionAfterLittleMotionIsIgnored() {
    var learner = DriftLearner(coefficient: 0.001)
    learner.recordCorrection(yaw: 0, at: 0, travel: 0)
    _ = learner.settle(at: 10)
    learner.recordCorrection(yaw: -8 * degree, at: 20, travel: 150 * degree)
    #expect(learner.settle(at: 30) == false)
    #expect(learner.coefficient == 0.001)
}

@Test func coefficientIsClamped() {
    var learner = DriftLearner(coefficient: 0)
    learner.recordCorrection(yaw: 0, at: 0, travel: 0)
    _ = learner.settle(at: 10)
    learner.recordCorrection(yaw: -170 * degree, at: 20, travel: 300 * degree)
    _ = learner.settle(at: 30)
    #expect(learner.coefficient == DriftLearner.maxCoefficient)
}

@Test func firstCorrectionOnlyStartsMeasurement() {
    var learner = DriftLearner(coefficient: 0)
    learner.recordCorrection(yaw: -20 * degree, at: 100, travel: 5000 * degree)
    #expect(learner.settle(at: 200) == false)
    #expect(learner.coefficient == 0)
}
