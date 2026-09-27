import CoreGraphics
import MetalKit

final class ScreenSlot {
    let index: Int
    let virtualScreen: VirtualScreen
    let capture = DisplayCapture()
    var seenGeneration = 0
    var texture: MTLTexture?

    var displayBounds: CGRect { CGDisplayBounds(virtualScreen.displayID) }

    init(index: Int, pointWidth: Int = 1920, pointHeight: Int = 1080) {
        self.index = index
        virtualScreen = VirtualScreen(index: index, pointWidth: pointWidth, pointHeight: pointHeight)
    }

    func start() async throws {
        try await capture.start(displayID: virtualScreen.displayID, width: virtualScreen.pixelWidth, height: virtualScreen.pixelHeight)
    }

    func stop() {
        capture.stop()
    }
}
