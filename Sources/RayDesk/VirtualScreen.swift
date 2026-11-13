import CoreGraphics
import RayDeskCore
import CGVirtualDisplayPrivate

final class VirtualScreen {
    /// Код изготовителя, которым помечаются виртуальные экраны приложения.
    static let vendorID: UInt32 = 0x5244

    private let display: CGVirtualDisplay
    let pixelWidth: Int
    let pixelHeight: Int
    let serialNumber: UInt32
    private(set) var refreshRate: Double?

    var displayID: CGDirectDisplayID { display.displayID }

    init(index: Int, pointWidth: Int, pointHeight: Int, family: GlassesDisplayFamily? = nil) {
        pixelWidth = pointWidth
        pixelHeight = pointHeight
        serialNumber = UInt32(index + 1)

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = .main
        descriptor.name = "RayDesk \(index + 1)"
        descriptor.maxPixelsWide = UInt32(pixelWidth)
        descriptor.maxPixelsHigh = UInt32(pixelHeight)
        descriptor.sizeInMillimeters = CGSize(width: 600, height: 600 * Double(pointHeight) / Double(pointWidth))
        descriptor.vendorID = Self.vendorID
        descriptor.productID = 0x0001
        descriptor.serialNum = serialNumber
        display = CGVirtualDisplay(descriptor: descriptor)

        updateRefreshRate(family: family)
    }

    func updateRefreshRate(family: GlassesDisplayFamily?) {
        let target = family?.targetRefreshRate ?? 60
        guard refreshRate != target else { return }
        let settings = Self.settings(width: pixelWidth, height: pixelHeight, family: family)
        if display.apply(settings) {
            refreshRate = target
            log("virtual display \(serialNumber): \(pixelWidth)×\(pixelHeight) @\(Int(target)) Hz")
        } else {
            log("virtual display \(serialNumber): macOS отклонила режим \(Int(target)) Hz")
        }
    }

    static func settings(width: Int, height: Int, family: GlassesDisplayFamily?) -> CGVirtualDisplaySettings {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: family?.targetRefreshRate ?? 60)]
        return settings
    }
}
