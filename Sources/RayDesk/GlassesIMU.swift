import Foundation
import IOKit.hid
import simd
import RayDeskCore

final class GlassesIMU {
    private let filter: OrientationFilter
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private let reportBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private let counterLock = NSLock()
    private var decoder = RayNeoProtocol.Decoder()
    private var samplesSinceLastRead = 0
    private var lastReadTime = Date()
    private(set) var isConnected = false

    init(filter: OrientationFilter) {
        self.filter = filter
    }

    func start() {
        let thread = Thread { [weak self] in self?.runHID() }
        thread.name = "raydesk.imu"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
    }

    func stop() {
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    func takeSampleRate() -> Int {
        counterLock.lock()
        defer { counterLock.unlock() }
        let elapsed = Date().timeIntervalSince(lastReadTime)
        let rate = elapsed > 0 ? Double(samplesSinceLastRead) / elapsed : 0
        samplesSinceLastRead = 0
        lastReadTime = Date()
        return Int(rate.rounded())
    }

    private func runHID() {
        runLoop = CFRunLoopGetCurrent()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [
            kIOHIDVendorIDKey: RayNeoProtocol.vendorID,
            kIOHIDProductIDKey: RayNeoProtocol.productID,
            kIOHIDPrimaryUsagePageKey: 0xFF00,
        ] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<GlassesIMU>.fromOpaque(context!).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, _ in
            let imu = Unmanaged<GlassesIMU>.fromOpaque(context!).takeUnretainedValue()
            imu.device = nil
            imu.isConnected = false
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
        CFRunLoopRun()
        if let device { send(RayNeoProtocol.stopIMUCommand, to: device) }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func attach(_ device: IOHIDDevice) {
        self.device = device
        isConnected = true
        filter.reset()
        decoder = RayNeoProtocol.Decoder()
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, 64, { context, _, _, _, _, report, length in
            Unmanaged<GlassesIMU>.fromOpaque(context!).takeUnretainedValue().handle(report: report, length: length)
        }, context)
        send(RayNeoProtocol.startIMUCommand, to: device)
    }

    private func send(_ command: [UInt8], to device: IOHIDDevice) {
        guard !command.isEmpty else { return }
        var bytes = command + [UInt8](repeating: 0, count: max(0, 64 - command.count))
        IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, &bytes, bytes.count)
    }

    private func handle(report: UnsafeMutablePointer<UInt8>, length: CFIndex) {
        guard let sample = decoder.decode(UnsafeBufferPointer(start: report, count: length)) else { return }
        filter.update(gyro: sample.gyro, accel: sample.accel, dt: sample.dt)
        counterLock.lock()
        samplesSinceLastRead += 1
        counterLock.unlock()
    }
}
