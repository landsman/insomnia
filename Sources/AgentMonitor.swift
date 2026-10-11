import Darwin
import Foundation

struct Agent: Equatable {
    let pid: pid_t
    let name: String
    let project: String
    let isWorking: Bool
}

/// Finds coding agents and decides which of them are working. Burning CPU is not a usable signal:
/// an agent streaming from its model or waiting on a tool looks as quiet as an idle one. What gives
/// work away is data moving over its connections, a shell running a tool, or a busy process tree.
/// Open connections alone are not enough, since an idle agent keeps them alive for minutes.
final class AgentMonitor {
    private static let agents = [
        "claude": "Claude Code", "codex": "Codex", "gemini": "Gemini CLI", "aider": "Aider",
        "opencode": "OpenCode", "cursor-agent": "Cursor Agent", "amp": "Amp", "goose": "Goose",
        "droid": "Droid", "copilot": "Copilot CLI", "qwen": "Qwen Code", "crush": "Crush",
        "cline": "Cline", "auggie": "Auggie", "kiro-cli": "Kiro",
    ]
    private static let interpreters: Set = ["node", "bun", "deno", "python", "python3", "ruby"]
    private static let shells: Set = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "nu"]

    /// Shells older than this are taken for background servers rather than tools in progress.
    private static let toolAge: TimeInterval = 30 * 60
    private static let busyCPU = 0.1

    private struct Process {
        let pid: pid_t
        let parent: pid_t
        let name: String
        let started: TimeInterval
    }

    private var cpu: [pid_t: Double] = [:]
    private var traffic: [UInt32: UInt64] = [:]
    private var lastScan: Date?
    private var lastBusy: [pid_t: Date] = [:]
    private let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()

    func scan(now: Date = .now) -> [Agent] {
        // Counters only compare across back-to-back scans: work done while nobody watched is not work now.
        let elapsed = lastScan.map { now.timeIntervalSince($0) } ?? .infinity
        let continuous = elapsed < 20
        lastScan = now
        let previousTraffic = traffic
        traffic = Self.trafficByConnection()
        let processes = Self.processes()
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var children: [pid_t: [Process]] = [:]
        for process in processes { children[process.parent, default: []].append(process) }

        var names: [pid_t: String] = [:]
        for process in processes {
            if let name = Self.agentName(of: process) { names[process.pid] = name }
        }

        func hasAgentAncestor(_ pid: pid_t) -> Bool {
            var parent = byPID[pid]?.parent
            while let pid = parent, pid > 1 {
                if names[pid] != nil { return true }
                parent = byPID[pid]?.parent
            }
            return false
        }

        func tree(_ root: Process) -> [Process] {
            var result = [root], index = 0
            while index < result.count {
                result += children[result[index].pid] ?? []
                index += 1
            }
            return result
        }

        var found: [Agent] = []
        for (pid, name) in names where !hasAgentAncestor(pid) {
            guard let root = byPID[pid] else { continue }
            let members = tree(root)
            var transferred: UInt64 = 0
            for member in members where names[member.pid] != nil {
                for connection in Self.connections(of: member.pid) {
                    let total = traffic[connection] ?? 0
                    transferred += total - min(total, previousTraffic[connection] ?? 0)
                }
            }
            let runningTool = members.contains {
                $0.pid != pid && Self.shells.contains($0.name) && now.timeIntervalSince1970 - $0.started < Self.toolAge
            }
            let seconds = members.reduce(0) { $0 + cpuSeconds($1.pid) }
            let busyCPU = continuous && (seconds - (cpu[pid] ?? seconds)) / elapsed > Self.busyCPU
            cpu[pid] = seconds
            if continuous && transferred > 0 || runningTool || busyCPU { lastBusy[pid] = now }
            let working = lastBusy[pid].map { now.timeIntervalSince($0) < 30 } ?? false
            found.append(Agent(pid: pid, name: name, project: Self.project(of: pid), isWorking: working))
        }

        let alive = Set(found.map(\.pid))
        lastBusy = lastBusy.filter { alive.contains($0.key) }
        cpu = cpu.filter { alive.contains($0.key) }
        return found.sorted { ($0.project, $0.name, $0.pid) < ($1.project, $1.name, $1.pid) }
    }

    private func cpuSeconds(_ pid: pid_t) -> Double {
        var usage = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
        }
        guard result == 0 else { return 0 }
        let ticks = usage.ri_user_time + usage.ri_system_time + usage.ri_child_user_time + usage.ri_child_system_time
        return Double(ticks) * secondsPerTick
    }

    private static func processes() -> [Process] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let bytes = proc_listpids(UInt32(PROC_UID_ONLY), getuid(), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).compactMap { pid in
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            let name = string(info.pbi_name)
            return Process(pid: pid, parent: pid_t(info.pbi_ppid), name: name.isEmpty ? string(info.pbi_comm) : name,
                           started: TimeInterval(info.pbi_start_tvsec))
        }
    }

    private static func agentName(of process: Process) -> String? {
        if let name = agents[process.name] { return name }
        // Scripts run through an interpreter, and native installs may be named after their version.
        guard interpreters.contains(process.name) || process.name.hasPrefix("python") || process.name.first?.isNumber == true
        else { return nil }
        var arguments = Self.arguments(of: process.pid)[...]
        guard var tool = arguments.popFirst().map(lastComponent) else { return nil }
        if interpreters.contains(tool) || tool.hasPrefix("python") {
            tool = arguments.first { !$0.hasPrefix("-") }.map(lastComponent) ?? ""
        }
        return agents[tool]
    }

    private static func arguments(of pid: pid_t) -> [String] {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
        let count = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        // argc, then the executable path and its padding, then argv.
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < min(Int(count), 3), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    private static func project(of pid: pid_t) -> String {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return "" }
        let path = string(info.pvi_cdir.vip_path)
        return path == NSHomeDirectory() ? "~" : lastComponent(path)
    }

    /// Established TCP connections to anything but this Mac, keyed like trafficByConnection().
    private static func connections(of pid: pid_t) -> [UInt32] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
        let filled = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, bytes)
        guard filled > 0 else { return [] }
        return descriptors.prefix(Int(filled) / MemoryLayout<proc_fdinfo>.stride).compactMap { descriptor in
            guard descriptor.proc_fdtype == PROX_FDTYPE_SOCKET else { return nil }
            var socket = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &socket, size) == size,
                  socket.psi.soi_kind == SOCKINFO_TCP else { return nil }
            let tcp = socket.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_ESTABLISHED, !isLoopback(tcp.tcpsi_ini) else { return nil }
            return UInt32(UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_fport))
                | UInt32(UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)) << 16
        }
    }

    /// Bytes each TCP connection has moved so far, keyed by its foreign and local port, from the
    /// kernel table netstat -b reads. The records are private kernel structures with a stable layout:
    /// xinpcb_n carries the ports at offset 16, xsockstat_n four traffic classes of packet and byte counts.
    private static func trafficByConnection() -> [UInt32: UInt64] {
        var size = 0
        guard sysctlbyname("net.inet.tcp.pcblist_n", nil, &size, nil, 0) == 0 else { return [:] }
        size += size / 4
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("net.inet.tcp.pcblist_n", &buffer, &size, nil, 0) == 0, size >= 24 else { return [:] }
        var traffic: [UInt32: UInt64] = [:]
        buffer.withUnsafeBytes { bytes in
            func u32(_ offset: Int) -> UInt32 { bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            func u64(_ offset: Int) -> UInt64 { bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self) }
            func padded(_ length: Int) -> Int { (length + 7) & ~7 }
            var offset = padded(Int(u32(0))), ports: UInt32 = 0
            while offset + 8 <= size {
                let length = Int(u32(offset)), kind = u32(offset + 4)
                // The list ends with another xinpgen header.
                guard length > 24, offset + length <= size else { break }
                if kind == 0x10 { ports = u32(offset + 16) }
                if kind == 0x08 {
                    traffic[ports] = (0..<4).reduce(0) { $0 + u64(offset + 16 + $1 * 32) + u64(offset + 32 + $1 * 32) }
                }
                offset += padded(length)
            }
        }
        return traffic
    }

    private static func isLoopback(_ socket: in_sockinfo) -> Bool {
        if socket.insi_vflag & UInt8(INI_IPV4) != 0 {
            return UInt32(bigEndian: socket.insi_faddr.ina_46.i46a_addr4.s_addr) >> 24 == 127
        }
        let bytes = withUnsafeBytes(of: socket.insi_faddr.ina_6) { Array($0) }
        return bytes == Array(repeating: 0, count: 15) + [1] || (bytes[10] == 0xFF && bytes[11] == 0xFF && bytes[12] == 127)
    }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    private static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
