import Darwin
import Foundation

/// This user's processes at one moment, read in a single sysctl and shared by the monitors.
struct Processes {
    struct Process {
        let pid: pid_t
        let parent: pid_t
        let name: String
        let started: Int
    }

    let all: [Process]
    let byPID: [pid_t: Process]
    let children: [pid_t: [Process]]

    static func current() -> Processes {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        var list: [kinfo_proc] = []
        if sysctl(&mib, 4, nil, &size, nil, 0) == 0 {
            list = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
            size = list.count * MemoryLayout<kinfo_proc>.stride
            if sysctl(&mib, 4, &list, &size, nil, 0) != 0 { size = 0 }
        }
        let all = list.prefix(size / MemoryLayout<kinfo_proc>.stride).map {
            Process(pid: $0.kp_proc.p_pid, parent: $0.kp_eproc.e_ppid, name: string($0.kp_proc.p_comm),
                    started: $0.kp_proc.p_un.__p_starttime.tv_sec)
        }
        var byPID: [pid_t: Process] = [:], children: [pid_t: [Process]] = [:]
        for process in all {
            byPID[process.pid] = process
            children[process.parent, default: []].append(process)
        }
        return Processes(all: all, byPID: byPID, children: children)
    }

    /// A process followed by all of its descendants.
    func tree(_ root: Process) -> [Process] {
        var members = [root], index = 0
        while index < members.count {
            members += children[members[index].pid] ?? []
            index += 1
        }
        return members
    }

    func ancestors(of pid: pid_t) -> [pid_t] {
        var result: [pid_t] = [], parent = byPID[pid]?.parent
        while let pid = parent, pid > 1 {
            result.append(pid)
            parent = byPID[pid]?.parent
        }
        return result
    }

    private static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()

    /// CPU time of a process and of the children it has reaped.
    static func cpuSeconds(_ pid: pid_t) -> Double {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard result == 0 else { return 0 }
        let ticks = usage.ri_user_time + usage.ri_system_time + usage.ri_child_user_time + usage.ri_child_system_time
        return Double(ticks) * secondsPerTick
    }

    static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
