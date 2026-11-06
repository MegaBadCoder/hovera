import Foundation
import IOKit

/// Поиск подключённых очков VITURE по USB.
///
/// Все очки VITURE объявляют vendor id `0x35CA`; конкретную модель SDK просит
/// задать product id, поэтому до создания дескриптора нужно узнать, что подключено.
public enum VitureUSB {
    /// USB vendor id, общий для всех очков VITURE.
    public static let vendorID = 0x35CA

    /// Найденное устройство в системе.
    public struct Device: Equatable, Sendable {
        /// USB product id, например `0x1104` у Luma Ultra.
        public let productID: Int32
        /// Строка продукта из USB-дескриптора, если система её отдала.
        public let name: String?

        public init(productID: Int32, name: String?) {
            self.productID = productID
            self.name = name
        }
    }

    /// Перечисляет подключённые очки VITURE.
    ///
    /// - Returns: по одному элементу на устройство; пустой массив, если очков нет или
    ///   интерфейс закрыт песочницей.
    public static func connectedDevices() -> [Device] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var devices: [Device] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let vendor = dictionary["idVendor"] as? Int, Int32(vendor) == vendorID,
                  let product = dictionary["idProduct"] as? Int else { continue }
            let name = (dictionary["USB Product Name"] as? String) ?? (dictionary["kUSBProductString"] as? String)
            let device = Device(productID: Int32(product), name: name)
            if !devices.contains(device) {
                devices.append(device)
            }
        }
        return devices
    }
}
