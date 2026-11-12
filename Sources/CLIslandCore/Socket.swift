import Darwin
import Foundation

public enum SocketClient {
    /// Sends one newline-terminated message; returns the reply line when `waitReply` is set.
    @discardableResult
    public static func send(_ payload: Data, waitReply: Bool = false, timeout: TimeInterval = 2, path: String = Paths.socket.path) -> Data? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard var addr = unixAddress(path) else { return nil }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return nil }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var data = payload
        if data.last != 0x0A { data.append(0x0A) }
        let written = data.withUnsafeBytes { writeAll(fd, $0.baseAddress!, data.count) }
        guard written else { return nil }
        guard waitReply else { return Data() }
        return readLine(fd)
    }

    public static func unixAddress(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        return addr
    }

    public static func writeAll(_ fd: Int32, _ ptr: UnsafeRawPointer, _ count: Int) -> Bool {
        var off = 0
        while off < count {
            let n = write(fd, ptr + off, count - off)
            if n <= 0 { return false }
            off += n
        }
        return true
    }

    public static func readLine(_ fd: Int32, max: Int = 4 << 20) -> Data? {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 8192)
        while out.count < max {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
            if let nl = out.firstIndex(of: 0x0A) { return out.prefix(upTo: nl) }
        }
        return out.isEmpty ? nil : out
    }
}

/// Process-tree helpers used to find the agent's terminal.
public enum ProcInfo {
    public struct Entry { public var pid: Int32; public var ppid: Int32; public var tty: String?; public var name: String }

    public static func entry(_ pid: Int32) -> Entry? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let dev = info.kp_eproc.e_tdev
        var tty: String?
        if dev != -1, let c = devname(dev, S_IFCHR) { tty = String(cString: c) }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
        return Entry(pid: pid, ppid: info.kp_eproc.e_ppid, tty: tty, name: name)
    }

    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "fish", "env", "clisland", "timeout"]

    /// Walks up from this process: first TTY found, and the first non-shell ancestor (the agent).
    public static func locate() -> (tty: String?, agentPid: Int32?) {
        var pid = getpid()
        var tty: String?
        var agent: Int32?
        for _ in 0..<12 {
            guard let e = entry(pid) else { break }
            if tty == nil, let t = e.tty, t != "??" { tty = t }
            if agent == nil, pid != getpid(), !shells.contains(e.name) { agent = pid }
            if e.ppid <= 1 { break }
            pid = e.ppid
            if tty != nil && agent != nil { break }
        }
        return (tty, agent)
    }

    public static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    public static func currentTerm() -> TermInfo {
        let env = ProcessInfo.processInfo.environment
        let loc = locate()
        return TermInfo(
            tty: loc.tty,
            program: env["TERM_PROGRAM"],
            bundleId: env["__CFBundleIdentifier"],
            sessionId: env["ITERM_SESSION_ID"] ?? env["TERM_SESSION_ID"] ?? env["KITTY_WINDOW_ID"] ?? env["WEZTERM_PANE"],
            tmuxPane: env["TMUX"] != nil ? env["TMUX_PANE"] : nil,
            agentPid: loc.agentPid
        )
    }
}
