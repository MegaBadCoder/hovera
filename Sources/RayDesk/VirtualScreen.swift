import CoreGraphics
import CGVirtualDisplayPrivate

final class VirtualScreen {
    private let display: CGVirtualDisplay
    let pixelWidth: Int
    let pixelHeight: Int

    var displayID: CGDirectDisplayID { display.displayID }

    init(index: Int, pointWidth: Int, pointHeight: Int, refreshRate: Double = 60) {
        pixelWidth = pointWidth
        pixelHeight = pointHeight

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = .main
        descriptor.name = "RayDesk \(index + 1)"
        descriptor.maxPixelsWide = UInt32(pixelWidth)
        descriptor.maxPixelsHigh = UInt32(pixelHeight)
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 600 * Double(pointHeight) / Double(pointWidth))
        descriptor.vendorID = 0x5244
        descriptor.productID = 0x0001
        descriptor.serialNum = UInt32(index + 1)
        display = CGVirtualDisplay(descriptor: descriptor)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: UInt32(pixelWidth), height: UInt32(pixelHeight), refreshRate: refreshRate)]
        display.apply(settings)
    }
}
