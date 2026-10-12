import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
import IOKit.ps
import SystemConfiguration

/// Reads what BagDetector weighs, and the lid that Power.pause weighs for heat. The accelerometer only runs
/// while the lid is closed on battery and Insomnia holds the Mac awake, the one case where a bag is possible.
@MainActor
final class BagSensors {
    private static let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    private let store = SCDynamicStoreCreate(nil, "Insomnia" as CFString, nil, nil)
    private let motion = Motion()

    /// Closed with no external display, so not a Mac docked in clamshell mode.
    static var lidClosedUndocked: Bool { lidClosed && !externalDisplay }

    func read(watchMotion: Bool) -> BagDetector.Reading {
        let onBattery = IOPSCopyPowerSourcesInfo().map {
            IOPSGetProvidingPowerSourceType($0.takeRetainedValue()).takeUnretainedValue() as String == kIOPSBatteryPowerValue
        } ?? false
        let reading = BagDetector.Reading(lidClosed: Self.lidClosed, onBattery: onBattery, externalDisplay: Self.externalDisplay,
                                          carriedAt: motion.carriedAt, router: router)
        watchMotion && reading.lidClosed && onBattery && !reading.externalDisplay ? motion.start() : motion.stop()
        return reading
    }

    func stop() {
        motion.stop()
    }

    private static var lidClosed: Bool {
        IORegistryEntryCreateCFProperty(rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
    }

    private var router: String? {
        (SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any])?["Router"] as? String
    }

    /// Online rather than active, so a monitor that has gone to sleep still counts. The built-in display stays
    /// in the list with the lid closed and nothing plugged in, so count only external ones.
    private static var externalDisplay: Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &displays, &count)
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}

/// The accelerometer Apple silicon MacBooks have behind their Sensor Processing Unit. Apple does not document it:
/// it is the HID device on vendor page 0xFF00, usage 3, and stays silent until its driver is told to report.
/// Reports are 22 bytes with x, y and z as little-endian Int32 at offsets 6, 10 and 14, in 1/65536 g.
/// Intel Macs and the 2020 M1 MacBook Pro lack it, and then carrying simply never counts.
@MainActor
private final class Motion {
    private static let usagePage = 0xFF00, usage = 3
    private var manager: IOHIDManager?
    private var timer: Timer?
    private var window = MotionWindow()
    private let report = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    /// Set once a Mac turns out to have no accelerometer, so it is not looked for again on every poll.
    private var unsupported = false
    private(set) var carriedAt: Date?

    func start() {
        guard manager == nil, !unsupported else { return }
        // Only the accelerometer's driver: its siblings serve the lid angle and other sensors macOS relies on.
        var drivers: io_iterator_t = 0
        IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &drivers)
        var found = false
        while case let driver = IOIteratorNext(drivers), driver != 0 {
            defer { IOObjectRelease(driver) }
            func property(_ key: String) -> Int? {
                IORegistryEntryCreateCFProperty(driver, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
            }
            guard property("PrimaryUsagePage") == Self.usagePage, property("PrimaryUsage") == Self.usage else { continue }
            // 100 reports a second, the rate the thresholds in MotionWindow were measured at.
            for (key, value) in [("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1), ("ReportInterval", 10_000)] {
                IORegistryEntrySetCFProperty(driver, key as CFString, value as CFNumber)
            }
            found = true
        }
        IOObjectRelease(drivers)

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: Self.usagePage, kIOHIDPrimaryUsageKey: Self.usage] as CFDictionary)
        let devices = IOHIDManagerOpen(manager, 0) == kIOReturnSuccess ? IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [] : []
        guard found, !devices.isEmpty else {
            unsupported = true
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for device in devices {
            IOHIDDeviceRegisterInputReportCallback(device, report, 64, { context, _, _, _, _, report, length in
                guard length >= 18, let context else { return }
                func axis(_ offset: Int) -> Double {
                    Double(UnsafeRawPointer(report + offset).loadUnaligned(as: Int32.self)) / 65536
                }
                let (x, y, z) = (axis(6), axis(10), axis(14))
                MainActor.assumeIsolated {
                    Unmanaged<Motion>.fromOpaque(context).takeUnretainedValue().window.add((x * x + y * y + z * z).squareRoot())
                }
            }, context)
        }
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.manager = manager

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.window.tick() { self.carriedAt = .now }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// ponytail: leaves the accelerometer's driver reporting, since other clients may rely on it.
    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, 0)
        self.manager = nil
        timer?.invalidate()
        timer = nil
        window = MotionWindow()
        carriedAt = nil
    }
}
