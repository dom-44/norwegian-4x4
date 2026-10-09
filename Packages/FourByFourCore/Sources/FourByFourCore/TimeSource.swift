import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A point in time captured from two clocks at once.
///
/// * `monotonic` comes from a clock that never jumps when the user (or the
///   network) changes the wall clock and keeps counting while the device sleeps
///   (`CLOCK_MONOTONIC` on Darwin, which is backed by `mach_continuous_time`).
/// * `wall` is used only as a fallback when two timestamps were captured in
///   different boot sessions (for example after a reboot during a workout),
///   because monotonic values are meaningless across boots.
public struct Timestamp: Codable, Equatable, Sendable {
    public var wall: Date
    public var monotonic: TimeInterval
    public var bootID: String?

    public init(wall: Date, monotonic: TimeInterval, bootID: String?) {
        self.wall = wall
        self.monotonic = monotonic
        self.bootID = bootID
    }

    /// Seconds from `self` to `later`. Uses the monotonic clock when both
    /// timestamps belong to the same boot session, otherwise the wall clock.
    public func seconds(until later: Timestamp) -> TimeInterval {
        if let a = bootID, let b = later.bootID, a == b {
            return later.monotonic - monotonic
        }
        return later.wall.timeIntervalSince(wall)
    }

    /// The same instant shifted by `seconds` on both clocks.
    public func adding(_ seconds: TimeInterval) -> Timestamp {
        Timestamp(wall: wall.addingTimeInterval(seconds), monotonic: monotonic + seconds, bootID: bootID)
    }
}

public protocol TimeSource: AnyObject {
    func now() -> Timestamp
}

/// Production clock.
public final class SystemTimeSource: TimeSource {
    public static let shared = SystemTimeSource()

    /// Identifies the current boot session (kernel boot time, whole seconds).
    public static let bootID: String? = {
        #if canImport(Darwin)
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &bootTime, &size, nil, 0) == 0 else { return nil }
        return String(bootTime.tv_sec)
        #else
        return nil
        #endif
    }()

    public init() {}

    public func now() -> Timestamp {
        #if canImport(Darwin)
        let monotonic = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
        #else
        let monotonic = ProcessInfo.processInfo.systemUptime
        #endif
        return Timestamp(wall: Date(), monotonic: monotonic, bootID: Self.bootID)
    }
}

/// Deterministic clock for tests and previews.
public final class ManualTimeSource: TimeSource {
    public var current: Timestamp

    public init(wall: Date = Date(timeIntervalSince1970: 1_800_000_000), monotonic: TimeInterval = 1_000, bootID: String? = "boot-1") {
        current = Timestamp(wall: wall, monotonic: monotonic, bootID: bootID)
    }

    public func now() -> Timestamp { current }

    public func advance(_ seconds: TimeInterval) {
        current = current.adding(seconds)
    }

    /// Simulates a reboot: monotonic clock restarts, wall clock continues.
    public func reboot(after seconds: TimeInterval, newBootID: String) {
        current = Timestamp(wall: current.wall.addingTimeInterval(seconds), monotonic: 5, bootID: newBootID)
    }
}
