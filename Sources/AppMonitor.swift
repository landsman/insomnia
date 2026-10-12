import AppKit
import IOKit.pwr_mgt

struct BusyApp: Equatable {
    let name: String
    let bundle: String?
}

/// Finds the rest of the work a Mac does for its user: apps that ask macOS to stay awake, as editors do
/// while they export and browsers while they download, apps that keep the processor busy, like a render,
/// and uploads. macOS honors such requests only while the lid is open. System processes do not count,
/// and neither does anything around an agent, which the agent monitor judges more precisely.
final class AppMonitor {
    private static let sleepAssertions: Set = ["PreventUserIdleSystemSleep", "NoIdleSleepAssertion", "PreventSystemSleep"]
    private static let systemPaths = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]
    /// Apple's own apps live under /System too, and an export from Photos or QuickTime Player is work.
    private static let systemApps = ["/System/Applications/", "/System/Library/CoreServices/Finder.app/"]
    /// Half a core held through a whole interval is a job rather than background noise.
    private static let busyCores = 0.5
    /// Half a megabit a second leaving the Mac is an upload rather than chatter.
    static let uploadBytesPerSecond = 64.0 * 1024

    private let host = mach_host_self()
    private let ownPID = getpid()
    private var hostTicks: [UInt32]?
    /// The app each process belongs to, or nil for system processes, looked up once per process.
    private var owners: [pid_t: (started: Int, key: String?)] = [:]
    private var apps: [String: BusyApp] = [:]
    private var cpu: [pid_t: (seconds: Double, at: Date)] = [:]
    private var sent: (bytes: [String: UInt32], at: Date)?

    func scan(_ processes: Processes, ignoring: Set<pid_t>, now: Date = .now) -> [BusyApp] {
        owners = owners.filter { processes.byPID[$0.key] != nil }
        cpu = cpu.filter { processes.byPID[$0.key] != nil }

        func owner(_ process: Processes.Process) -> String? {
            guard process.pid != ownPID, !ignoring.contains(process.pid) else { return nil }
            return self.owner(of: process)
        }

        var busy: Set<String> = []
        var assertions: Unmanaged<CFDictionary>?
        if IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
           let byProcess = assertions?.takeRetainedValue() as? [NSNumber: [[String: Any]]] {
            for (pid, list) in byProcess where list.contains(where: { Self.sleepAssertions.contains($0["AssertType"] as? String ?? "") }) {
                if let process = processes.byPID[pid.int32Value], let key = owner(process) { busy.insert(key) }
            }
        }

        // Most of the time the whole Mac idles, which spares looking at every process.
        if busyCores() >= Self.busyCores {
            var load: [String: Double] = [:]
            for process in processes.all {
                guard let key = owner(process) else { continue }
                let seconds = Processes.cpuSeconds(process.pid)
                if let previous = cpu[process.pid], now.timeIntervalSince(previous.at) < 60 {
                    load[key, default: 0] += (seconds - previous.seconds) / now.timeIntervalSince(previous.at)
                }
                cpu[process.pid] = (seconds, now)
            }
            busy.formUnion(load.filter { $0.value >= Self.busyCores }.keys)
        }
        return busy.map(app).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func app(_ key: String) -> BusyApp {
        if let app = apps[key] { return app }
        let app = key.hasSuffix(".app") ? BusyApp(name: FileManager.default.displayName(atPath: key), bundle: key)
            : BusyApp(name: (key as NSString).lastPathComponent, bundle: nil)
        apps[key] = app
        return app
    }

    /// Bytes per second sent over Wi-Fi and Ethernet since the previous call. VPN tunnels would count them twice.
    func uploadRate(now: Date = .now) -> Double {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return 0 }
        defer { freeifaddrs(list) }
        var bytes: [String: UInt32] = [:]
        var cursor = list
        while let entry = cursor?.pointee {
            cursor = entry.ifa_next
            let name = String(cString: entry.ifa_name)
            guard name.hasPrefix("en"), entry.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let data = entry.ifa_data else { continue }
            bytes[name] = data.assumingMemoryBound(to: if_data.self).pointee.ifi_obytes
        }
        let previous = sent
        sent = (bytes, now)
        guard let previous else { return 0 }
        let elapsed = now.timeIntervalSince(previous.at)
        guard elapsed > 0, elapsed < 60 else { return 0 }
        // The counters are 32 bits wide and wrap around.
        let delta = bytes.reduce(UInt64(0)) { $0 + UInt64($1.value &- (previous.bytes[$1.key] ?? $1.value)) }
        return Double(delta) / elapsed
    }

    /// Cores in use across the whole Mac since the previous call.
    private func busyCores() -> Double {
        var load = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &load) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return .infinity }
        let ticks = [load.cpu_ticks.0, load.cpu_ticks.1, load.cpu_ticks.2, load.cpu_ticks.3]
        let previous = hostTicks
        hostTicks = ticks
        guard let previous else { return 0 }
        let delta = zip(ticks, previous).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        // User, system, idle and nice ticks, summed over all cores.
        return total > 0 ? (total - delta[2]) / total * Double(ProcessInfo.processInfo.activeProcessorCount) : 0
    }

    /// The app bundle a process belongs to, its executable when it has none, or nil for system processes.
    private func owner(of process: Processes.Process) -> String? {
        if let known = owners[process.pid], known.started == process.started { return known.key }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(process.pid, &buffer, UInt32(buffer.count))
        let path = String(decoding: buffer.prefix(Int(max(length, 0))).map(UInt8.init(bitPattern:)), as: UTF8.self)
        var key: String?
        if !path.isEmpty, Self.systemApps.contains(where: path.hasPrefix) || !Self.systemPaths.contains(where: path.hasPrefix) {
            // Helpers sit inside their app, so the outermost bundle stands for the app.
            key = path.range(of: ".app/").map { String(path[..<$0.lowerBound]) + ".app" } ?? path
        }
        owners[process.pid] = (process.started, key)
        return key
    }
}
