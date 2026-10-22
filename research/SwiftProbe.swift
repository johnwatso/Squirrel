import Foundation

// IOPSKeys.h constants are C preprocessor #defines, so they do NOT bridge into
// Swift. The literal string values are the contract.
enum PSKey {
    static let name          = "Name"
    static let type          = "Type"
    static let transportType = "Transport Type"
    static let state         = "Power Source State"
    static let currentCap    = "Current Capacity"
    static let maxCap        = "Max Capacity"
    static let timeToEmpty   = "Time to Empty"
    static let isPresent     = "Is Present"
    static let isCharging    = "Is Charging"
}
enum PSValue {
    static let upsType   = "UPS"
    static let ethernet  = "Ethernet"
    static let acPower   = "AC Power"
}

// Pure Swift, no bridging header, no C target: resolve the three undocumented
// IOKit exports through dlsym and call them as @convention(c) pointers.
// IOPSPowerSourceID is an opaque pointer, not a CF object: typing it as
// CFTypeRef puts it under ARC and the first retain segfaults.
private typealias CreateFn  = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
private typealias SetFn     = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
private typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer) -> Int32

struct PowerSourcePublisher {
    private let create: CreateFn
    private let set: SetFn
    private let release: ReleaseFn

    init?() {
        guard let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let c = dlsym(h, "IOPSCreatePowerSource"),
              let s = dlsym(h, "IOPSSetPowerSourceDetails"),
              let r = dlsym(h, "IOPSReleasePowerSource") else { return nil }
        create  = unsafeBitCast(c, to: CreateFn.self)
        set     = unsafeBitCast(s, to: SetFn.self)
        release = unsafeBitCast(r, to: ReleaseFn.self)
    }

    func run() {
        var raw: UnsafeMutableRawPointer?
        let rc = withUnsafeMutablePointer(to: &raw) { create($0) }
        print("IOPSCreatePowerSource     -> 0x\(String(format: "%08x", rc))  uid=\(getuid())")
        guard rc == 0, let ps = raw else { return }

        let details: [String: Any] = [
            PSKey.name: "Squirrel Swift Probe",
            PSKey.type: PSValue.upsType,
            PSKey.transportType: PSValue.ethernet,
            PSKey.state: PSValue.acPower,   // healthy + on line power: nothing for powerd to act on
            PSKey.isPresent: true,
            PSKey.isCharging: false,
            PSKey.currentCap: 100,
            PSKey.maxCap: 100,
            PSKey.timeToEmpty: 1800,
        ]
        print("IOPSSetPowerSourceDetails -> 0x\(String(format: "%08x", set(ps, details as CFDictionary)))")
        fflush(stdout)
        Thread.sleep(forTimeInterval: 6)
        print("IOPSReleasePowerSource    -> 0x\(String(format: "%08x", release(ps)))")
    }
}

guard let p = PowerSourcePublisher() else { fputs("dlsym failed\n", stderr); exit(1) }
p.run()
