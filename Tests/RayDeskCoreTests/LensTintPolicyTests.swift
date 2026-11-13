import Testing
import simd
@testable import RayDeskCore

@Test func lensesClearOnlyAfterSustainedPhysicalScreenGaze() {
    var policy = LensTintPolicy()
    #expect(policy.update(target: .mac, time: 0) == nil)
    #expect(policy.update(target: .mac, time: 0.2) == nil)
    #expect(policy.update(target: .mac, time: 0.4) == false)
    #expect(policy.update(target: .mac, time: 1) == nil)
}

@Test func lensesDarkenAgainOnVirtualScreen() {
    var policy = LensTintPolicy()
    _ = policy.update(target: .mac, time: 0)
    _ = policy.update(target: .mac, time: 0.4)
    #expect(policy.update(target: .virtual(0), time: 1) == nil)
    #expect(policy.update(target: .virtual(1), time: 1.4) == true)
    #expect(policy.update(target: .virtual(0), time: 2) == nil)
}

@Test func glancesAndMissingTargetsDoNotToggleLenses() {
    var policy = LensTintPolicy()
    _ = policy.update(target: .virtual(0), time: 0)
    _ = policy.update(target: .virtual(0), time: 0.4)
    #expect(policy.update(target: .mac, time: 1) == nil)
    #expect(policy.update(target: nil, time: 1.2) == nil)
    #expect(policy.update(target: .mac, time: 1.5) == nil)
    #expect(policy.update(target: .virtual(0), time: 1.6) == nil)
    #expect(policy.update(target: nil, time: 2) == nil)
}

@Test func frameGapsRestartTintDwell() {
    var policy = LensTintPolicy()
    _ = policy.update(target: .mac, time: 0)
    #expect(policy.update(target: .mac, time: 5) == nil)
    #expect(policy.update(target: .mac, time: 5.4) == false)
}

@Test func physicalMonitorDirectionWrapsAtPi() {
    let monitor = PhysicalMonitorDirection(yaw: .pi - 0.05, pitch: 0)
    #expect(monitor.contains(head: yawPitchQuat(yaw: -.pi + 0.05, pitch: 0)))
    #expect(!monitor.contains(head: yawPitchQuat(yaw: 0, pitch: 0)))
    #expect(!monitor.contains(head: yawPitchQuat(yaw: .pi, pitch: 0.5)))
}
