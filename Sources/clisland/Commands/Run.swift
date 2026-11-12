import CLIslandCore
import Darwin
import Foundation

/// `clisland run -- <cmd>`: runs any command in a PTY, then reports exit code, duration and output tail.
enum Runner {
    static func run(_ args: [String]) -> Int32 {
        var argv = args
        if argv.first == "--" { argv.removeFirst() }
        guard !argv.isEmpty else {
            FileHandle.standardError.write(Data("usage: clisland run -- <command> [args...]\n".utf8))
            return 2
        }
        let display = argv.map { Installer.shellQuote($0) }.joined(separator: " ")
        let session = "run-\(getpid())-\(Int(Date().timeIntervalSince1970))"
        var term = ProcInfo.currentTerm()
        term.agentPid = getpid()
        let cwd = FileManager.default.currentDirectoryPath
        SocketClient.send(Event(agent: "run", kind: .runStart, session: session, cwd: cwd, term: term,
                                data: .obj([("command", .string(display))])).line, timeout: 0.5)

        let start = Date()
        var tail = TailBuffer()
        let status = isatty(STDOUT_FILENO) != 0 ? runPTY(argv, &tail) : runPipe(argv, &tail)
        let duration = Date().timeIntervalSince(start)

        SocketClient.send(Event(agent: "run", kind: .runDone, session: session, cwd: cwd, term: term,
                                data: .obj([("command", .string(display)), ("exit_code", .number(Double(status))),
                                            ("duration", .number(duration.rounded())), ("tail", JSON.strings(tail.lines()))])).line, timeout: 0.5)
        return status
    }

    private static func decode(_ st: Int32) -> Int32 {
        let sig = st & 0x7f
        return sig == 0 ? (st >> 8) & 0xff : 128 + sig
    }

    private static func runPTY(_ argv: [String], _ tail: inout TailBuffer) -> Int32 {
        var ws = winsize()
        _ = ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws)
        var orig = termios()
        let stdinTTY = isatty(STDIN_FILENO) != 0 && tcgetattr(STDIN_FILENO, &orig) == 0
        let cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer { cargs.forEach { free($0) } }

        var master: Int32 = -1
        let pid = stdinTTY ? forkpty(&master, nil, &orig, &ws) : forkpty(&master, nil, nil, &ws)
        if pid < 0 { return runPipe(argv, &tail) }
        if pid == 0 {
            execvp(cargs[0]!, cargs)
            let msg = "clisland: command not found: \(argv[0])\n"
            _ = msg.withCString { write(STDERR_FILENO, $0, strlen($0)) }
            _exit(127)
        }

        if stdinTTY {
            var raw = orig
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        defer { if stdinTTY { tcsetattr(STDIN_FILENO, TCSANOW, &orig) } }

        var buf = [UInt8](repeating: 0, count: 16384)
        var stdinOpen = true
        var lastSize = ws
        while true {
            var fds = [pollfd(fd: master, events: Int16(POLLIN), revents: 0)]
            if stdinOpen { fds.append(pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)) }
            let r = poll(&fds, nfds_t(fds.count), 250)
            if r < 0 { if errno == EINTR { continue } else { break } }

            var now = winsize()
            if ioctl(STDOUT_FILENO, TIOCGWINSZ, &now) == 0, now.ws_col != lastSize.ws_col || now.ws_row != lastSize.ws_row {
                _ = ioctl(master, TIOCSWINSZ, &now)
                lastSize = now
            }
            if fds[0].revents & Int16(POLLIN | POLLHUP) != 0 {
                let n = read(master, &buf, buf.count)
                if n <= 0 { break }
                _ = buf.withUnsafeBytes { SocketClient.writeAll(STDOUT_FILENO, $0.baseAddress!, n) }
                tail.append(buf[0..<n])
            }
            if stdinOpen, fds.count > 1, fds[1].revents & Int16(POLLIN | POLLHUP) != 0 {
                let n = read(STDIN_FILENO, &buf, buf.count)
                if n <= 0 { stdinOpen = false } else { _ = buf.withUnsafeBytes { SocketClient.writeAll(master, $0.baseAddress!, n) } }
            }
        }
        close(master)
        var st: Int32 = 0
        while waitpid(pid, &st, 0) < 0 && errno == EINTR {}
        return decode(st)
    }

    private static func runPipe(_ argv: [String], _ tail: inout TailBuffer) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return 127 }
        let h = pipe.fileHandleForReading
        while true {
            let d = h.availableData
            if d.isEmpty { break }
            FileHandle.standardOutput.write(d)
            tail.append(d)
        }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

struct TailBuffer {
    private var data = Data()

    mutating func append<S: Sequence>(_ bytes: S) where S.Element == UInt8 {
        data.append(contentsOf: bytes)
        if data.count > 64_000 { data = Data(data.suffix(32_000)) }
    }

    func lines(_ n: Int = 20) -> [String] {
        var text = String(decoding: data, as: UTF8.self)
        text = text.replacingOccurrences(of: #"\u{1B}\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\u{1B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\u{1B}[()][A-Za-z0-9]"#, with: "", options: .regularExpression)
        let out = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map { line -> String in
            let parts = line.components(separatedBy: "\r")
            return (parts.last(where: { !$0.isEmpty }) ?? "").trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return Array(out.suffix(n)).map { $0.clipped(200) }
    }
}
