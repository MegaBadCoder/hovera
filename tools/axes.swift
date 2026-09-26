import Foundation
import IOKit.hid
let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: 0x1BBB, kIOHIDProductIDKey: 0xAF50, kIOHIDPrimaryUsagePageKey: 0xFF00] as CFDictionary)
IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
IOHIDManagerOpen(m, 0)
guard let dev = (IOHIDManagerCopyDevices(m) as? Set<IOHIDDevice>)?.first else { print("no device"); exit(1) }
let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
var frames = 0, distinct = 0, lastData = [UInt8](), firstTick: UInt32 = 0, lastTick: UInt32 = 0
var angle = SIMD3<Double>(), lastTime = 0.0, bias = SIMD3<Double>(), biasN = 0.0, acc = SIMD3<Double>()
let start = Date()
func f(_ p: UnsafeMutablePointer<UInt8>, _ o: Int) -> Double { Double(UnsafeRawPointer(p + o).loadUnaligned(as: Float.self)) }
IOHIDDeviceRegisterInputReportCallback(dev, buf, 64, { _, _, _, _, _, r, _ in
  guard r[0] == 0x99, r[1] == 0x65 else { return }
  frames += 1
  let tick = UnsafeRawPointer(r + 40).loadUnaligned(as: UInt32.self)
  if firstTick == 0 { firstTick = tick }
  lastTick = tick
  let data = Array(UnsafeBufferPointer(start: r + 4, count: 24))
  guard data != lastData else { return }
  lastData = data; distinct += 1
  let now = Date().timeIntervalSince(start)
  let g = SIMD3(f(r,16), f(r,20), f(r,24)); acc = SIMD3(f(r,4), f(r,8), f(r,12))
  if now < 1.5 { bias += g; biasN += 1 } else if lastTime > 0 { angle += (g - bias / biasN) * (now - lastTime) }
  lastTime = now
}, nil)
var cmd: [UInt8] = [0x66, 0x01, 0x00] + [UInt8](repeating: 0, count: 61)
IOHIDDeviceSetReport(dev, kIOHIDReportTypeOutput, 0, &cmd, 64)
for i in 1...18 {
  RunLoop.main.run(until: start.addingTimeInterval(Double(i) * 0.5))
  print(String(format: "t=%.1f angle x=%7.1f y=%7.1f z=%7.1f  acc %.2f %.2f %.2f", Double(i)*0.5, angle.x, angle.y, angle.z, acc.x, acc.y, acc.z))
}
let el = Date().timeIntervalSince(start)
print(String(format: "frames/s %.0f distinct/s %.0f tick/s %.0f bias %@", Double(frames)/el, Double(distinct)/el, Double(lastTick &- firstTick)/el, "\(bias/biasN)"))
