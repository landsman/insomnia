import CoreGraphics
import Foundation
import IOKit
import IOKit.hid
import Network
import os
import SystemConfiguration

/// Reads what BagDetector weighs, and the lid that Power.pause weighs for heat. The accelerometer only runs
/// while the lid is closed with no external display and Insomnia holds the Mac awake, the one case where a bag
/// is possible, and the network is only watched while the setting is on.
@MainActor
final class BagSensors {
    private static let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    private let store = SCDynamicStoreCreate(nil, "Insomnia" as CFString, nil, nil)
    private let motion = Motion()
    private var path: NWPathMonitor?
    /// A phone's hotspot, which macOS marks as an expensive path.
    private var hotspot = false

    /// Intel Macs and the 2020 M1 MacBook Pro have no accelerometer, and then a bag cannot be told.
    static let hasMotionSensor = Motion.driver.map { IOObjectRelease($0); return true } ?? false

    /// Closed with no external display, so not a Mac docked in clamshell mode.
    static var lidClosedUndocked: Bool { lidClosed && !externalDisplay }

    func read(watchMotion: Bool) -> BagDetector.Reading {
        if path == nil {
            let path = NWPathMonitor()
            path.pathUpdateHandler = { [weak self] path in
                MainActor.assumeIsolated { self?.hotspot = path.isExpensive }
            }
            path.start(queue: .main)
            self.path = path
        }
        let reading = BagDetector.Reading(lidClosed: Self.lidClosed, externalDisplay: Self.externalDisplay,
                                          carriedSeconds: motion.carriedSeconds, onEdge: motion.onEdge, router: router,
                                          hotspot: hotspot, thermal: ProcessInfo.processInfo.thermalState)
        watchMotion && reading.lidClosed && !reading.externalDisplay ? motion.start() : motion.stop()
        return reading
    }

    /// Stops the accelerometer, and with `network` the network watch too, for when the setting goes off.
    func stop(network: Bool = false) {
        motion.stop()
        guard network else { return }
        path?.cancel()
        path = nil
        hotspot = false
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
@MainActor
private final class Motion {
    nonisolated private static let usagePage = 0xFF00, usage = 3
    private static let log = Logger(subsystem: "com.michalptacek.insomnia", category: "bag")
    /// What the driver reported with before Insomnia woke it, put back when it stops.
    private static let reportingKeys = ["SensorPropertyReportingState", "SensorPropertyPowerState", "ReportInterval"]
    private var manager: IOHIDManager?
    private var timer: Timer?
    private var window = MotionWindow()
    private var original: [String: Int] = [:]
    private let report = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)
    /// Only grows, so a restart of the sensor never loses carrying the detector has not read yet.
    private(set) var carriedSeconds = 0
    var onEdge: Bool { window.onEdge }

    /// The accelerometer's driver, of the several behind the SPU: its siblings serve the lid angle and other
    /// sensors macOS relies on. The caller releases it.
    nonisolated static var driver: io_object_t? {
        var drivers: io_iterator_t = 0
        IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &drivers)
        defer { IOObjectRelease(drivers) }
        while case let driver = IOIteratorNext(drivers), driver != 0 {
            if property(driver, "PrimaryUsagePage") == usagePage, property(driver, "PrimaryUsage") == usage { return driver }
            IOObjectRelease(driver)
        }
        return nil
    }

    nonisolated private static func property(_ driver: io_object_t, _ key: String) -> Int? {
        IORegistryEntryCreateCFProperty(driver, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
    }

    func start() {
        guard manager == nil, BagSensors.hasMotionSensor, let driver = Self.driver else { return }
        defer { IOObjectRelease(driver) }
        original = Dictionary(uniqueKeysWithValues: Self.reportingKeys.map { ($0, Self.property(driver, $0) ?? 0) })
        // 100 reports a second, the rate the thresholds in MotionWindow were measured at.
        for (key, value) in zip(Self.reportingKeys, [1, 1, 10_000]) {
            IORegistryEntrySetCFProperty(driver, key as CFString, value as CFNumber)
        }

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDPrimaryUsagePageKey: Self.usagePage, kIOHIDPrimaryUsageKey: Self.usage] as CFDictionary)
        let opened = IOHIDManagerOpen(manager, 0)
        let devices = opened == kIOReturnSuccess ? IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [] : []
        // Right after a wake the device may not be back yet; the next poll tries again.
        guard !devices.isEmpty else {
            Self.log.info("Accelerometer not ready: open returned \(opened), \(devices.count) devices")
            IOHIDManagerClose(manager, 0)
            restore(driver)
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
                    Unmanaged<Motion>.fromOpaque(context).takeUnretainedValue().window.add(x: x, y: y, z: z)
                }
            }, context)
        }
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        self.manager = manager

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.window.tick() { self.carriedSeconds += 1 }
            }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, 0)
        self.manager = nil
        timer?.invalidate()
        timer = nil
        window = MotionWindow()
        if let driver = Self.driver {
            restore(driver)
            IOObjectRelease(driver)
        }
    }

    private func restore(_ driver: io_object_t) {
        for (key, value) in original { IORegistryEntrySetCFProperty(driver, key as CFString, value as CFNumber) }
    }
}
