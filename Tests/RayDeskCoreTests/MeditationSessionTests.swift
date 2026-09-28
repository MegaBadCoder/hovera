import Testing
@testable import RayDeskCore

@Test func meditationStartsInactiveAndHidden() {
    let transition = MeditationTransition()
    #expect(!transition.isActive)
    #expect(transition.eased == 0)
}

@Test func meditationFadesInOverThreeSeconds() {
    var transition = MeditationTransition()
    transition.toggle()
    #expect(transition.isActive)
    transition.advance(by: 1.5)
    #expect(abs(transition.progress - 0.5) < 1e-9)
    #expect(abs(transition.eased - 0.5) < 1e-9)
    transition.advance(by: 1.4)
    #expect(transition.eased < 1)
    transition.advance(by: 0.2)
    #expect(transition.eased == 1)
}

@Test func meditationEasingIsMonotonicAndGentleAtEnds() {
    var transition = MeditationTransition()
    transition.toggle()
    var previous = transition.eased
    transition.advance(by: 0.03)
    #expect(transition.eased < 0.01)
    while transition.progress < 1 {
        transition.advance(by: 0.03)
        #expect(transition.eased >= previous)
        previous = transition.eased
    }
}

@Test func meditationReversesFromWhereItIs() {
    var transition = MeditationTransition()
    transition.toggle()
    transition.advance(by: 1.2)
    let reached = transition.progress
    transition.toggle()
    #expect(!transition.isActive)
    transition.advance(by: 0.6)
    #expect(abs(transition.progress - (reached - 0.2)) < 1e-9)
    transition.advance(by: 10)
    #expect(transition.eased == 0)
}

@Test func breathingInhalesForFourSecondsAndExhalesForSix() {
    #expect(Breathing.openness(at: 0) == 0)
    #expect(abs(Breathing.openness(at: 4) - 1) < 1e-9)
    #expect(abs(Breathing.openness(at: 10)) < 1e-9)
    #expect(abs(Breathing.openness(at: 2) - 0.5) < 1e-9)
    #expect(abs(Breathing.openness(at: 7) - 0.5) < 1e-9)
}

@Test func breathingRisesDuringInhaleFallsDuringExhaleAndRepeats() {
    var previous = Breathing.openness(at: 0)
    for step in 1...40 {
        let value = Breathing.openness(at: Double(step) * 0.1)
        #expect(value > previous)
        previous = value
    }
    for step in 41...100 {
        let value = Breathing.openness(at: Double(step) * 0.1)
        #expect(value < previous)
        previous = value
    }
    #expect(abs(Breathing.openness(at: 13.3) - Breathing.openness(at: 3.3)) < 1e-9)
}
