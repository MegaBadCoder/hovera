import CoreGraphics
import ImageIO
import MetalKit
import Testing
import UniformTypeIdentifiers
import RayDeskCore
@testable import RayDesk

@Test func restIndicatorIsAnchoredToSphereInsteadOfFollowingHead() {
    let identity = simd_quatd(angle: 0, axis: SIMD3(0, 1, 0))
    let a = RestStatusIndicator.matrix(head: identity, position: .zero, anchorYaw: 0, verticalFOV: 0.5, size: SIMD2(1920, 1200))
    let b = RestStatusIndicator.matrix(head: simd_quatd(angle: 0.2, axis: SIMD3(0, 1, 0)), position: .zero,
                                       anchorYaw: 0, verticalFOV: 0.5, size: SIMD2(1920, 1200))
    let ca = a * SIMD4<Float>(0, 0, 0, 1)
    let cb = b * SIMD4<Float>(0, 0, 0, 1)
    #expect(abs(ca.x / ca.w) < 1e-5)
    #expect(ca.y / ca.w < 0)
    #expect(abs(cb.x / cb.w - ca.x / ca.w) > 0.1)
}

@Test func restIndicatorDrawsActualPhaseWithoutChangingOtherPixels() throws {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let queue = try #require(device.makeCommandQueue())
    let indicator = try RestStatusIndicator(device: device, pixelFormat: .rgba8Unorm)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1920, height: 1200, mipmapped: false)
    descriptor.storageMode = .shared
    descriptor.usage = [.renderTarget]
    let target = try #require(device.makeTexture(descriptor: descriptor))
    for phase in [RestStabilizationPhase.resting, .moving] {
        let command = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
        let clear = try #require(command.makeRenderCommandEncoder(descriptor: pass))
        clear.endEncoding()
        try indicator.encode(phase: phase, strength: .strong, adaptiveSync: phase == .moving, head: simd_quatd(angle: 0, axis: SIMD3(0, 1, 0)),
                             position: .zero, anchorYaw: 0, verticalFOV: 0.5,
                             destination: target, commandBuffer: command)
        command.commit()
        command.waitUntilCompleted()
        #expect(command.status == .completed)
        var pixels = [UInt8](repeating: 0, count: 1920 * 1200 * 4)
        target.getBytes(&pixels, bytesPerRow: 1920 * 4, from: MTLRegionMake2D(0, 0, 1920, 1200), mipmapLevel: 0)
        #expect(abs(Int(pixels[0]) - 26) <= 1)
        var colored = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[index]), green = Int(pixels[index + 1])
            if phase == .resting ? green > red + 30 : red > green + 30 { colored += 1 }
        }
        #expect(colored > 100)
        if let output = ProcessInfo.processInfo.environment["RAYDESK_REST_INDICATOR_PREVIEW"], phase == .resting {
            let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
            let image = try #require(CGImage(width: 1920, height: 1200, bitsPerComponent: 8, bitsPerPixel: 32,
                                           bytesPerRow: 1920 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let destination = try #require(CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
    }
}

@Test @MainActor func restControlsMenuCanBeRebuiltWithoutReusingOwnedItems() {
    _ = NSApplication.shared
    let delegate = AppDelegate()
    let first = delegate.buildMenu()
    let second = delegate.buildMenu()
    #expect(first !== second)
    #expect(first.items.allSatisfy { $0.menu === first })
    #expect(second.items.allSatisfy { $0.menu === second })
    let picture = second.items.compactMap(\.submenu).first { menu in
        menu.items.contains { $0.action == NSSelectorFromString("toggleAdaptiveVSync:") }
    }
    #expect(picture != nil)
    #expect(picture?.items.contains { $0.action == NSSelectorFromString("toggleAdaptiveVSync:") } == true)
    let strength = picture?.items.first { $0.submenu?.items.contains { $0.action == NSSelectorFromString("chooseStabilization:") } == true }
    #expect(strength?.submenu?.items.count == 4)
    #expect(strength?.submenu?.items.filter { $0.state == .on }.count == 1)
    #expect(picture?.items.contains { $0.action == NSSelectorFromString("toggleRestIndicator:") } == true)
    let tolerance = picture?.items.compactMap(\.view).flatMap(\.subviews)
        .compactMap { $0 as? NSSlider }.first { $0.action == NSSelectorFromString("restToleranceChanged:") }
    #expect(tolerance?.minValue == RestPoseStabilizer.toleranceRange.lowerBound)
    #expect(tolerance?.maxValue == RestPoseStabilizer.toleranceRange.upperBound)
    #expect(tolerance?.isContinuous == true)

}
