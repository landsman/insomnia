import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
import IOKit.ps
import SystemConfiguration

/// Reads what BagDetector weighs. The accelerometer only runs while the lid is closed on battery,
/// the one case where a bag is possible.
@MainActor
final class BagSensors {
    private static let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    private let store = SCDynamicStoreCreate(nil, "Insomnia" as CFString, nil, nil)
    private let motion = Motion()

    func read() -> BagDetector.Reading {
        let lidClosed = IORegistryEntryCreateCFProperty(Self.rootDomain, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool ?? false
        let onBattery = IOPSCopyPowerSourcesInfo().map {
            IOPSGetProvidingPowerSourceType($0.takeRetainedValue()).takeUnretainedValue() as String == kIOPSBatteryPowerValue
        } ?? false
        let reading = BagDetector.Reading(lidClosed: lidClosed, onBattery: onBattery, externalDisplay: Self.externalDisplay,
                                          carriedAt: motion.carriedAt, router: router,
                                          thermal: ProcessInfo.processInfo.thermalState)
        lidClosed && onBattery && !reading.externalDisplay ? motion.start() : motion.stop()
        return reading
    }

    func stop() {
        motion.stop()
    }

    private var router: String? {
        (SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any])?["Router"] as? String
    }

    /// The active display list still holds one display with the lid closed and nothing plugged in, so count only external ones.
    private static var externalDisplay: Bool {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &displays, &count)
        return displays.prefix(Int(count)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}

/// The accelerometer Apple silicon MacBooks have behind their Sensor Processing Unit. Apple does not document it:
/// it is the HID device on vendor page 0xFF00, usage 3, and stays silent until its driver is told to report.
/// Reports are 22 bytes with x, y and z as little-endian Int32 at offsets 6, 10 and 14, in 1/65536 g.
/// Intel Macs and the 2020 M1 MacBook Pro lack it, and then carrying simply never counts.
@MainActor
private final class Motion {
    private var manager: IOHIDManager?
    private var timer: Timer?
    private var window = MotionWindow()
    private let report = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    private(set) var carriedAt: Date?

    func start() {
        guard manager == nil else { return }
        var drivers: io_iterator_t = 0
        IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &drivers)
        while case let driver = IOIteratorNext(drivers), driver != 0 {
            // 100 reports a second, the rate the thresholds in MotionWindow were measured at.
            for (key, value) in [("SensorPropertyReportingState", 1), ("SensorPropertyPowerState", 1), ("ReportInterval", 10_000)] {
                IORegistryEntrySetCFProperty(driver, key as CFString, value as CFNumber)
            }
            IOObjectRelease(driver)
        }
        IOObjectRelease(drivers)

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: 0xFF00, kIOHIDPrimaryUsageKey: 3] as CFDictionary)
        guard IOHIDManagerOpen(manager, 0) == kIOReturnSuccess else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for device in IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [] {
            IOHIDDeviceRegisterInputReportCallback(device, report, 64, { context, _, _, _, _, report, length in
                guard length >= 18, let context else { return }
                let axes = (0..<3).map { Double(UnsafeRawPointer(report + 6 + $0 * 4).loadUnaligned(as: Int32.self)) / 65536 }
                MainActor.assumeIsolated {
                    Unmanaged<Motion>.fromOpaque(context).takeUnretainedValue()
                        .window.add(axes.reduce(0) { $0 + $1 * $1 }.squareRoot())
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

    /// ponytail: leaves the driver reporting, since other clients may rely on it; turning it off is a guess at shared state.
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
