import Testing
import RayDeskCore
@testable import RayDesk

private final class CameraDriver {
    var starts: [(Error?) -> Void] = []
    var stops = 0
    lazy var controller = CameraUsageController(start: { [weak self] in self?.starts.append($0) }, stop: { [weak self] in self?.stops += 1 })
}

@Test func cameraCenteringIsOnlyNeededForVisibleRayNeoScene() {
    #expect(CameraUsageController.needsCentering(family: .rayNeo, visible: true, enabled: true))
    #expect(!CameraUsageController.needsCentering(family: .viture, visible: true, enabled: true))
    #expect(!CameraUsageController.needsCentering(family: nil, visible: true, enabled: true))
    #expect(!CameraUsageController.needsCentering(family: .rayNeo, visible: false, enabled: true))
    #expect(!CameraUsageController.needsCentering(family: .rayNeo, visible: true, enabled: false))
}

@Test func cameraStopsAfterItsLastConsumerLeaves() {
    let driver = CameraDriver()
    driver.controller.request(.centering) { _ in }
    driver.starts[0](nil)
    driver.controller.request(.debug) { _ in }
    #expect(driver.starts.count == 1)
    driver.controller.release(.centering)
    #expect(driver.stops == 0)
    driver.controller.release(.debug)
    #expect(driver.stops == 1)
}

@Test func closingDuringStartupPreventsLateCameraActivation() {
    let driver = CameraDriver()
    var opened = false
    driver.controller.request(.debug) { _ in opened = true }
    driver.controller.release(.debug)
    driver.starts[0](nil)
    #expect(!opened)
    #expect(driver.stops == 1)
}

@Test func staleStartupCannotCompleteANewerCameraRequest() {
    let driver = CameraDriver()
    var currentOpened = false
    driver.controller.request(.centering) { _ in }
    driver.controller.release(.centering)
    driver.controller.request(.calibration) { _ in currentOpened = true }
    driver.starts[0](nil)
    #expect(!currentOpened)
    driver.starts[1](nil)
    #expect(currentOpened)
    driver.controller.release(.calibration)
    #expect(driver.stops == 2)
}

@Test func overlappingCameraRequestsShareStartupAndCanCancelIndependently() {
    let driver = CameraDriver()
    var centeringOpened = false
    var debugOpened = false
    driver.controller.request(.centering) { _ in centeringOpened = true }
    driver.controller.request(.debug) { _ in debugOpened = true }
    #expect(driver.starts.count == 1)
    driver.controller.release(.centering)
    #expect(driver.stops == 0)
    driver.starts[0](nil)
    #expect(!centeringOpened)
    #expect(debugOpened)
    driver.controller.release(.debug)
    driver.controller.release(.debug)
    #expect(driver.stops == 1)
}

@Test func failedCameraStartCanBeRetriedExplicitly() {
    enum Failure: Error { case unavailable }
    let driver = CameraDriver()
    var failed = false
    driver.controller.request(.centering) { failed = $0 != nil }
    driver.starts[0](Failure.unavailable)
    #expect(failed)
    var retried = false
    driver.controller.request(.centering) { retried = $0 == nil }
    driver.starts[1](nil)
    #expect(retried)
    driver.controller.stopAll()
    #expect(!driver.controller.isRequested(.centering))
    #expect(driver.stops == 1)
}

@Test func cameraCalibrationCanHandOffToCenteringWithoutStoppingCapture() {
    let driver = CameraDriver()
    var handedOff = false
    driver.controller.request(.calibration) { _ in
        driver.controller.request(.centering) { _ in handedOff = true }
        driver.controller.release(.calibration)
    }
    driver.starts[0](nil)
    #expect(handedOff)
    #expect(driver.starts.count == 1)
    #expect(driver.stops == 0)
    driver.controller.release(.centering)
    #expect(driver.stops == 1)
}
