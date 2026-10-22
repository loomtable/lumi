import Darwin

/// Read-only process facts from libproc and sysctl (no permissions needed for our own user's
/// processes). Constants are from `sys/proc_info.h` in the macOS 26 SDK.
enum Processes {
    struct Info: Sendable, Equatable {
        var pid: Int32
        var ppid: Int32
        /// Controlling tty device, or nil when there is none.
        var tty: UInt32?
        /// Foreground process group of that tty.
        var ttyForegroundGroup: Int32?
        var name: String

        init(pid: Int32, ppid: Int32, tty: UInt32?, ttyForegroundGroup: Int32?, name: String) {
            self.pid = pid
            self.ppid = ppid
            self.tty = tty
            self.ttyForegroundGroup = ttyForegroundGroup
            self.name = name
        }

        init(_ k: kinfo_proc) {
            let dev = UInt32(bitPattern: k.kp_eproc.e_tdev)
            // NODEV is all ones; 0 also means no tty.
            let tty: UInt32? = dev == UInt32.max || dev == 0 ? nil : dev
            let name = withUnsafeBytes(of: k.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            self.init(
                pid: k.kp_proc.p_pid, ppid: k.kp_eproc.e_ppid, tty: tty,
                ttyForegroundGroup: tty == nil || k.kp_eproc.e_tpgid <= 0 ? nil : k.kp_eproc.e_tpgid, name: name)
        }
    }

    /// PIDs whose real user is us. Real, not effective: `login` (between iTerm2's server and the
    /// shell) runs setuid root but keeps our real uid.
    static func userPIDs() -> [Int32] {
        let uid = getuid()
        let count = proc_listpids(UInt32(PROC_RUID_ONLY), uid, nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) / MemoryLayout<Int32>.size + 64)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_RUID_ONLY), uid, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return [] }
        return Array(pids.prefix(Int(bytes) / MemoryLayout<Int32>.size)).filter { $0 > 0 }
    }

    /// Every process whose real user is us, in one sysctl (KERN_PROC_RUID). Unlike
    /// proc_pidinfo, this also covers setuid processes such as `login`.
    static func userProcesses() -> [Info] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_RUID, Int32(bitPattern: getuid())]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        // The table can grow between the two calls.
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 16)
        size = procs.count * stride
        guard procs.withUnsafeMutableBytes({ sysctl(&mib, 4, $0.baseAddress, &size, nil, 0) }) == 0 else { return [] }
        return procs.prefix(size / stride).map(Info.init)
    }

    static func info(_ pid: Int32) -> Info? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var proc = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &proc, &size, nil, 0) == 0, size > 0 else { return nil }
        return Info(proc)
    }

    static func cwd(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return path.isEmpty ? nil : path
    }

    /// argv of `pid` (KERN_PROCARGS2), or nil.
    static func arguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        // Layout: argc (Int32), exec path, NUL padding up to pointer alignment after argc, then
        // argc NUL-terminated arguments, then the environment. Measured on macOS 26.6 (447
        // processes): arguments always start where (offset - 4) is a multiple of 8. Starting
        // there, rather than at the first non-NUL byte, reads an empty argv[0] as "" instead of
        // treating it as padding, which would shift the list into the environment.
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        var start = index + 1
        while (start - MemoryLayout<Int32>.size) % 8 != 0 { start += 1 }
        guard start <= size, buffer[index..<min(start, size)].allSatisfy({ $0 == 0 }) else { return nil }
        index = start
        var args: [String] = []
        while args.count < argc, index < size {
            let begin = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[begin..<index], as: UTF8.self))
            index += 1
        }
        return args.count == Int(argc) ? args : nil
    }

    /// A short, readable command line: the program's basename plus its arguments, capped. For
    /// interpreters (node, python, ruby, bun, deno) the script's basename replaces the
    /// interpreter, so `node …/next dev` reads `next dev`.
    static func command(_ pid: Int32, maxLength: Int = 160) -> String? {
        guard var args = arguments(pid).map(Redact.arguments), !args.isEmpty else { return nil }
        args[0] = basename(args[0])
        let interpreters: Set<String> = ["node", "python", "python3", "ruby", "bun", "deno", "perl"]
        // Case-insensitive: macOS's python3 execs the framework binary named "Python".
        if interpreters.contains(args[0].lowercased()), args.count > 1, !args[1].hasPrefix("-") {
            args.removeFirst()
            args[0] = basename(args[0])
        }
        let line = args.joined(separator: " ")
        return line.count > maxLength ? String(line.prefix(maxLength)) + "…" : line
    }

    static func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    /// PID of a process owned by us listening on TCP `port` (IPv4 or IPv6).
    static func listeningPID(port: Int) -> Int32? {
        for pid in userPIDs() where listens(pid, port: port) { return pid }
        return nil
    }

    static func listens(_ pid: Int32, port: Int) -> Bool {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return false }
        let socketSize = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, socketSize) == socketSize,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            // insi_lport holds the port in network byte order in its low 16 bits.
            let local = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if local == port { return true }
        }
        return false
    }
}
