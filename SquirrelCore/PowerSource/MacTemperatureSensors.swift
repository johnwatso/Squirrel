import Foundation
import os

/// Reads the Mac's own chip temperature, for comparing against the UPS's.
///
/// macOS has no public API for this. Apple silicon publishes its temperature
/// sensors as HID services, readable by any unsandboxed app without
/// privileges, through IOKit functions that ship in macOS but are not in the
/// public headers. As with `PowerSourcePublisher`, they are resolved at
/// runtime, and if a future macOS removes them the reading is simply nil.
///
/// Intel Macs keep their sensors in the SMC instead and read nil here.
public final class MacTemperatureSensors: @unchecked Sendable {
    private typealias CreateFn = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatFn = @convention(c) (AnyObject, Int32) -> Double

    /// `kIOHIDEventTypeTemperature`, and the field holding its value.
    private static let temperatureEvent: Int64 = 15
    private static let temperatureField: Int32 = 15 << 16

    private let copyEvent: CopyEventFn?
    private let getFloat: GetFloatFn?
    private let lock = NSLock()
    /// The sensors chosen to stand for the chip. Retained for the life of the
    /// reader; looking them up again on every reading would be wasted work.
    private let sensors: [AnyObject]
    private let client: AnyObject?

    public static let shared = MacTemperatureSensors()

    init() {
        let log = Logger(subsystem: "io.github.johnwatso.Squirrel", category: "MacTemperature")
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let create = dlsym(iokit, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(iokit, "IOHIDEventSystemClientSetMatching"),
              let copyServices = dlsym(iokit, "IOHIDEventSystemClientCopyServices"),
              let copyProperty = dlsym(iokit, "IOHIDServiceClientCopyProperty"),
              let copyEvent = dlsym(iokit, "IOHIDServiceClientCopyEvent"),
              let getFloat = dlsym(iokit, "IOHIDEventGetFloatValue"),
              let client = unsafeBitCast(create, to: CreateFn.self)(kCFAllocatorDefault)?.takeRetainedValue()
        else {
            log.notice("Mac temperature sensors are unavailable on this Mac")
            self.copyEvent = nil
            self.getFloat = nil
            self.sensors = []
            self.client = nil
            return
        }
        // Apple's vendor page and its temperature-sensor usage.
        let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
        _ = unsafeBitCast(setMatching, to: SetMatchingFn.self)(client, matching)
        let services = unsafeBitCast(copyServices, to: CopyServicesFn.self)(client)?.takeRetainedValue() as? [AnyObject] ?? []
        let named = services.map { service in
            (name: unsafeBitCast(copyProperty, to: CopyPropertyFn.self)(service, "Product" as CFString)?
                .takeRetainedValue() as? String ?? "", service: service)
        }
        let chosen = Self.chipSensorNames(named.map(\.name))
        self.copyEvent = unsafeBitCast(copyEvent, to: CopyEventFn.self)
        self.getFloat = unsafeBitCast(getFloat, to: GetFloatFn.self)
        self.sensors = named.filter { chosen.contains($0.name) }.map(\.service)
        self.client = client
        if sensors.isEmpty {
            log.notice("No chip temperature sensors among \(services.count) HID sensors")
        }
    }

    /// The chip's average temperature in degrees Celsius, or nil if this Mac
    /// does not expose one.
    public func chipTemperature() -> Double? {
        guard let copyEvent, let getFloat else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let values = sensors.compactMap { sensor -> Double? in
            guard let event = copyEvent(sensor, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            return getFloat(event, Self.temperatureField)
        }
        return Self.average(values)
    }

    /// Which sensors stand for the chip. The die and core-cluster sensors
    /// ("SOC Die", "pACC MTR", "GPU MTR" and so on) where the chip has them,
    /// else the power manager's die sensors ("PMU tdie"). Never the "tcal"
    /// calibration constants, the "tdev" board sensors or the storage.
    static func chipSensorNames(_ names: [String]) -> Set<String> {
        let die = names.filter { $0.contains("MTR Temp") || $0.contains("SOC Die") }
        if !die.isEmpty { return Set(die) }
        return Set(names.filter { $0.contains("tdie") })
    }

    /// Some sensors read nonsense (−21 °C on an M1 Mac mini at room
    /// temperature), so anything a running chip could not be is left out.
    static func average(_ values: [Double]) -> Double? {
        let plausible = values.filter { $0.isFinite && $0 > 5 && $0 < 130 }
        guard !plausible.isEmpty else { return nil }
        return plausible.reduce(0, +) / Double(plausible.count)
    }
}
