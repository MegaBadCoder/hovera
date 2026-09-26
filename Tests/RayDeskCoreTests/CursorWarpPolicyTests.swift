import Testing
@testable import RayDeskCore

@Test func warpTargetIsNilBeforeDwellElapses() {
    var policy = CursorWarpPolicy()
    policy.observeGaze(screen: 1, at: 0)
    let target = policy.warpTarget(cursorScreen: 0, buttonsDown: false, at: 0.1)
    #expect(target == nil)
}

@Test func warpTargetFiresAfterDwellWhenCursorOnOtherScreen() {
    var policy = CursorWarpPolicy()
    policy.observeGaze(screen: 1, at: 0)
    let target = policy.warpTarget(cursorScreen: 0, buttonsDown: false, at: 0.25)
    #expect(target == 1)
}

@Test func warpTargetFiresAfterDwellWhenCursorOnNoScreen() {
    var policy = CursorWarpPolicy()
    policy.observeGaze(screen: 1, at: 0)
    let target = policy.warpTarget(cursorScreen: nil, buttonsDown: false, at: 0.25)
    #expect(target == 1)
}

@Test func warpTargetIsNilWhileButtonsAreDown() {
    var policy = CursorWarpPolicy()
    policy.observeGaze(screen: 1, at: 0)
    let target = policy.warpTarget(cursorScreen: 0, buttonsDown: true, at: 0.25)
    #expect(target == nil)
}

@Test func warpTargetIsNilWhenGazeScreenIsNil() {
    var policy = CursorWarpPolicy()
    policy.observeGaze(screen: nil, at: 0)
    let target = policy.warpTarget(cursorScreen: 0, buttonsDown: false, at: 0.25)
    #expect(target == nil)
}

@Test func warpTargetIsNilWhenGazeScreenMatchesCursorScreen() {
    var policy = CursorWarpPolicy()
    policy.observeGaze(screen: 1, at: 0)
    let target = policy.warpTarget(cursorScreen: 1, buttonsDown: false, at: 0.25)
    #expect(target == nil)
}

@Test func gazeMovingToAnotherScreenResetsDwell() {
    var policy = CursorWarpPolicy()
    policy.observeGaze(screen: 1, at: 0)
    policy.observeGaze(screen: 2, at: 0.15)
    let target = policy.warpTarget(cursorScreen: 0, buttonsDown: false, at: 0.2)
    #expect(target == nil)
    let target2 = policy.warpTarget(cursorScreen: 0, buttonsDown: false, at: 0.36)
    #expect(target2 == 2)
}
