import Foundation
import IOKit.hid

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x1BBB, kIOHIDProductIDKey: 0xAF50, kIOHIDPrimaryUsagePageKey: 0xFF00] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("open:", String(format: "0x%08x", r))
guard let devs = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let dev = devs.first else { print("no device"); exit(1) }

let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
var count = 0
var seen = [UInt8: Int]()
let cb: IOHIDReportCallback = { _, _, _, _, _, report, len in
    count += 1
    seen[report[0], default: 0] += 1
    if count <= 12 || count % 500 == 0 {
        print(String(format: "#%5d len=%2d ", count, len) + (0..<len).map { String(format: "%02x", report[$0]) }.joined(separator: " "))
    }
}
IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, cb, nil)

func send(_ bytes: [UInt8]) {
    var b = bytes + [UInt8](repeating: 0, count: 64 - bytes.count)
    let s = IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, &b, 64)
    print("send", bytes.map { String(format: "%02x", $0) }.joined(separator: " "), "->", String(format: "0x%08x", s))
}

let args = CommandLine.arguments.dropFirst()
if !args.isEmpty { send(args.map { UInt8($0, radix: 16)! }) }

let secs = Double(ProcessInfo.processInfo.environment["SECS"] ?? "3")!
RunLoop.main.run(until: Date().addingTimeInterval(secs))
print("total reports:", count, "first-byte histogram:", seen.sorted { $0.key < $1.key }.map { String(format: "%02x:%d", $0.key, $0.value) })
