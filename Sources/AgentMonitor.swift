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
    private static let toolAge = 30 * 60
    private static let busyCPU = 0.1
    /// A model served on this Mac counts once it streams real data, unlike the keep-alive chatter of an IDE link.
    private static let busyLoopbackBytes: UInt64 = 4096

    private struct Process {
        let pid: pid_t
        let parent: pid_t
        let name: String
        let started: Int
    }

    private struct Connection {
        let key: UInt32
        let isLoopback: Bool
    }

    /// Interpreted and version-named processes need their arguments read to be told apart, so that happens once per process.
    private var identified: [pid_t: (started: Int, agent: String?)] = [:]
    private var projects: [pid_t: String] = [:]
    private var cpu: [pid_t: (seconds: Double, at: Date)] = [:]
    private var traffic: [UInt32: UInt64] = [:]
    private var lastScan: Date?
    private var lastBusy: [pid_t: Date] = [:]
    private let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()

    func scan(now: Date = .now) -> [Agent] {
        // Traffic only counts between back-to-back scans: work done while nobody watched is not work now.
        let continuous = lastScan.map { now.timeIntervalSince($0) < 60 } ?? false
        lastScan = now

        var byPID: [pid_t: Process] = [:], children: [pid_t: [Process]] = [:], names: [pid_t: String] = [:]
        for process in Self.processes() {
            byPID[process.pid] = process
            children[process.parent, default: []].append(process)
            if let name = agentName(of: process) { names[process.pid] = name }
        }
        identified = identified.filter { byPID[$0.key] != nil }

        let roots = names.keys.filter { pid in
            var parent = byPID[pid]?.parent
            while let pid = parent, pid > 1 {
                if names[pid] != nil { return false }
                parent = byPID[pid]?.parent
            }
            return true
        }
        let trees = roots.map { root in
            var members = [byPID[root]!], index = 0
            while index < members.count {
                members += children[members[index].pid] ?? []
                index += 1
            }
            return members
        }
        let connections = trees.map { $0.filter { names[$0.pid] != nil }.flatMap { Self.connections(of: $0.pid) } }
        let previousTraffic = traffic
        traffic = connections.contains { !$0.isEmpty } ? Self.trafficByConnection() : [:]

        var found: [Agent] = []
        for (index, root) in roots.enumerated() {
            let members = trees[index]
            let runningTool = members.dropFirst().contains {
                Self.shells.contains($0.name) && Int(now.timeIntervalSince1970) - $0.started < Self.toolAge
            }
            var remote: UInt64 = 0, local: UInt64 = 0
            for connection in connections[index] {
                let total = traffic[connection.key] ?? 0
                let moved = total - min(total, previousTraffic[connection.key] ?? 0)
                if connection.isLoopback { local += moved } else { remote += moved }
            }
            let talking = continuous && (remote > 0 || local > Self.busyLoopbackBytes)
            if talking || runningTool || isBusy(root, members, now: now) { lastBusy[root] = now }
            if projects[root] == nil { projects[root] = Self.project(of: root) }
            let working = lastBusy[root].map { now.timeIntervalSince($0) < 45 } ?? false
            found.append(Agent(pid: root, name: names[root]!, project: projects[root]!, isWorking: working))
        }

        let alive = Set(roots)
        lastBusy = lastBusy.filter { alive.contains($0.key) }
        projects = projects.filter { alive.contains($0.key) }
        cpu = cpu.filter { alive.contains($0.key) }
        return found.sorted { ($0.project, $0.name, $0.pid) < ($1.project, $1.name, $1.pid) }
    }

    private func isBusy(_ root: pid_t, _ members: [Process], now: Date) -> Bool {
        let seconds = members.reduce(0) { $0 + cpuSeconds($1.pid) }
        let elapsed = cpu[root].map { now.timeIntervalSince($0.at) } ?? .infinity
        // A blip in a short window is no load, so short windows keep the older baseline.
        guard elapsed >= 2 else { return false }
        defer { cpu[root] = (seconds, now) }
        return elapsed < 60 && (seconds - cpu[root]!.seconds) / elapsed > Self.busyCPU
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

    private func agentName(of process: Process) -> String? {
        if let name = Self.agents[process.name] { return name }
        // Scripts run through an interpreter, and native installs may be named after their version.
        guard Self.interpreters.contains(process.name) || process.name.hasPrefix("python") || process.name.first?.isNumber == true
        else { return nil }
        if let known = identified[process.pid], known.started == process.started { return known.agent }
        var arguments = Self.arguments(of: process.pid)[...]
        var tool = arguments.popFirst().map(Self.lastComponent) ?? ""
        if Self.interpreters.contains(tool) || tool.hasPrefix("python") {
            tool = arguments.first { !$0.hasPrefix("-") }.map(Self.lastComponent) ?? ""
        }
        identified[process.pid] = (process.started, Self.agents[tool])
        return Self.agents[tool]
    }

    /// All processes of this user in one call.
    private static func processes() -> [Process] {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        var list = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = list.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &list, &size, nil, 0) == 0 else { return [] }
        return list.prefix(size / MemoryLayout<kinfo_proc>.stride).map {
            Process(pid: $0.kp_proc.p_pid, parent: $0.kp_eproc.e_ppid, name: string($0.kp_proc.p_comm),
                    started: $0.kp_proc.p_un.__p_starttime.tv_sec)
        }
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

    /// Established TCP connections, keyed like trafficByConnection().
    private static func connections(of pid: pid_t) -> [Connection] {
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
            guard tcp.tcpsi_state == TSI_S_ESTABLISHED else { return nil }
            let key = UInt32(UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_fport))
                | UInt32(UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)) << 16
            return Connection(key: key, isLoopback: isLoopback(tcp.tcpsi_ini))
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
