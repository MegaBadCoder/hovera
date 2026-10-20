import Testing
@testable import RayDeskCore

private let motionWidth = CameraMotionDetector.width
private let motionHeight = CameraMotionDetector.height

/// Текстура, похожая на комнату: у сдвига есть чему измениться, но картинка детерминирована.
private func texturedFrame() -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: motionWidth * motionHeight)
    for y in 0..<motionHeight {
        for x in 0..<motionWidth {
            let value = (x * 5 + y * 11 + (x / 3) * (y / 4) + (x * y) % 53) % 256
            pixels[y * motionWidth + x] = UInt8(value)
        }
    }
    return pixels
}

private func shifted(_ image: [UInt8], dx: Int, dy: Int) -> [UInt8] {
    var result = [UInt8](repeating: 0, count: image.count)
    for y in 0..<motionHeight {
        for x in 0..<motionWidth {
            let sourceX = x + dx, sourceY = y + dy
            guard sourceX >= 0, sourceX < motionWidth, sourceY >= 0, sourceY < motionHeight else { continue }
            result[y * motionWidth + x] = image[sourceY * motionWidth + sourceX]
        }
    }
    return result
}

@Test func stillBackgroundDoesNotLookLikeCameraMotion() {
    var detector = CameraMotionDetector()
    let frame = texturedFrame()
    #expect(detector.update(luma: frame) == false)
    #expect(detector.update(luma: frame) == false)
    #expect(detector.shift == .zero)
}

@Test func shiftedBackgroundMeansTheCameraMoved() {
    var detector = CameraMotionDetector()
    let frame = texturedFrame()
    _ = detector.update(luma: frame)
    #expect(detector.update(luma: shifted(frame, dx: 3, dy: 2)) == true)
    #expect(detector.shift == SIMD2(3, 2))
}

@Test func brighterFrameIsNotCameraMotion() {
    var detector = CameraMotionDetector()
    let frame = texturedFrame()
    _ = detector.update(luma: frame)
    let brighter = frame.map { UInt8(min(255, Int($0) + 30)) }
    #expect(detector.update(luma: brighter) == false)
}

@Test func resetForgetsThePreviousFrame() {
    var detector = CameraMotionDetector()
    let frame = texturedFrame()
    _ = detector.update(luma: frame)
    detector.reset()
    #expect(detector.update(luma: shifted(frame, dx: 4, dy: 0)) == false)
}

@Test func faceMovingInsideExcludedRegionIsNotCameraMotion() {
    var detector = CameraMotionDetector()
    let frame = texturedFrame()
    _ = detector.update(luma: frame)
    var changed = frame
    for y in 30..<60 {
        for x in 60..<100 {
            changed[y * motionWidth + x] = UInt8((Int(changed[y * motionWidth + x]) + 90) % 256)
        }
    }
    let face = MotionRegion(minX: 55, minY: 25, maxX: 105, maxY: 65)
    #expect(detector.update(luma: changed, excluding: face) == false)
}
