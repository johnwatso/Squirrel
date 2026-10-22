import Foundation
import os

/// Publishes a UPS power source to macOS, so the Mac behaves as though a UPS
/// were plugged into it: the battery menu bar item, System Settings → Energy →
/// UPS Options, and `powerd`'s own emergency shutdown thresholds
/// (`pmset -u haltlevel / haltafter / haltremain`).
///
/// This is the same mechanism Apple's own `/usr/libexec/ioupsd` uses for USB
/// UPSes — `nm -u /usr/libexec/ioupsd` imports exactly these three symbols. A
/// USB UPS is not special to macOS; `ioupsd` reads HID Power Device usages and
/// then makes these calls. Squirrel has a different data source and the same
/// destination.
///
/// The symbols are exported from IOKit and present in the SDK's `IOKit.tbd`,
/// but they are not declared in the public headers, so they are resolved at
/// runtime and every failure path degrades rather than trapping.
public actor PowerSourcePublisher {
    public enum PublishError: Error, Equatable {
        /// IOKit did not hand back the undocumented symbols. macOS has changed;
        /// fall back to app-level handling and tell the user plainly.
        case symbolsUnavailable
        case createFailed(Int32)
        case updateFailed(Int32)
    }

    /// `IOPSCreatePowerSource` hands back an `IOPSPowerSourceID`, which is an
    /// opaque pointer and *not* a CoreFoundation object. Typing it as
    /// `CFTypeRef` makes ARC retain and release it, which segfaults the moment
    /// the handle is stored or passed on — so it is carried as a raw pointer
    /// and released only through `IOPSReleasePowerSource`.
    private typealias CreateFn  = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    private typealias SetFn     = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
    private typealias ReleaseFn = @convention(c) (UnsafeMutableRawPointer) -> Int32

    private struct Symbols {
        let create: CreateFn
        let set: SetFn
        let release: ReleaseFn

        init?() {
            guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
                  let create = dlsym(handle, "IOPSCreatePowerSource"),
                  let set = dlsym(handle, "IOPSSetPowerSourceDetails"),
                  let release = dlsym(handle, "IOPSReleasePowerSource")
            else { return nil }
            self.create = unsafeBitCast(create, to: CreateFn.self)
            self.set = unsafeBitCast(set, to: SetFn.self)
            self.release = unsafeBitCast(release, to: ReleaseFn.self)
        }
    }

    private let log = Logger(subsystem: "io.github.johnwatso.Squirrel", category: "PowerSource")
    private let symbols: Symbols?
    private var handle: UnsafeMutableRawPointer?
    private var lastPublished: PowerSourceSnapshot?

    public init() {
        symbols = Symbols()
        if symbols == nil {
            log.error("IOKit power source symbols unavailable; macOS will not see a UPS")
        }
    }

    /// Whether this build of macOS still exposes the mechanism at all.
    public nonisolated var isSupported: Bool { symbols != nil }

    public var isPublishing: Bool { handle != nil }

    public var publishedSnapshot: PowerSourceSnapshot? { lastPublished }

    /// Creates the power source if needed, then updates its details.
    ///
    /// Idempotent: publishing the same snapshot twice does no work, so this is
    /// safe to call on every poll.
    @discardableResult
    public func publish(_ snapshot: PowerSourceSnapshot) throws -> Bool {
        guard let symbols else { throw PublishError.symbolsUnavailable }
        if lastPublished == snapshot, handle != nil { return false }

        if handle == nil {
            var raw: UnsafeMutableRawPointer?
            let status = withUnsafeMutablePointer(to: &raw) { symbols.create($0) }
            guard status == 0, let created = raw else {
                log.error("IOPSCreatePowerSource failed: \(status)")
                throw PublishError.createFailed(status)
            }
            handle = created
            log.notice("Published UPS power source to macOS")
        }

        guard let handle else { throw PublishError.createFailed(-1) }
        let status = symbols.set(handle, snapshot.dictionaryRepresentation() as CFDictionary)
        guard status == 0 else {
            log.error("IOPSSetPowerSourceDetails failed: \(status)")
            throw PublishError.updateFailed(status)
        }

        lastPublished = snapshot
        return true
    }

    /// Removes the UPS from macOS. Call this when monitoring is paused or the
    /// UPS is deleted — a paused monitor must not keep asserting a healthy UPS.
    ///
    /// Not called from `deinit`: an actor cannot run isolated code there. The
    /// source is released by the kernel when the process exits in any case,
    /// which is also why the app must not be allowed to terminate while idle.
    public func withdraw() {
        guard let symbols, let handle else { return }
        _ = symbols.release(handle)
        self.handle = nil
        lastPublished = nil
        log.notice("Withdrew UPS power source from macOS")
    }
}
