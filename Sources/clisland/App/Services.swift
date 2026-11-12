import AppKit
import CLIslandCore
import Darwin
import Foundation

/// Unix socket server: one JSON line per connection, optional reply for permission requests.
final class SocketServer {
    private let path: String
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "clisland.socket")
    private var pending: [String: (fd: Int32, watch: DispatchSourceRead)] = [:]
    private let lock = NSLock()

    var onEvent: ((Event) -> Void)?
    var onAbandon: ((String) -> Void)?
    var onQuery: ((JSON) -> JSON)?

    init(path: String) { self.path = path }

    static func isRunning(path: String) -> Bool {
        SocketClient.send(Data(#"{"agent":"cli","kind":"status","data":{"cmd":"ping"}}"#.utf8), waitReply: true, timeout: 0.5, path: path) != nil
    }

    func start() throws {
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var addr = SocketClient.unixAddress(path) else { throw POSIXError(.EINVAL) }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else { throw POSIXError(.EIO) }
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptOne() }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        if fd >= 0 { close(fd) }
        unlink(path)
    }

    private func acceptOne() {
        let c = accept(fd, nil, nil)
        guard c >= 0 else { return }
        var on: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.handle(c) }
    }

    private func handle(_ c: Int32) {
        guard let line = SocketClient.readLine(c), let j = JSON.parse(line) else { close(c); return }
        if j["kind"]?.string == "status" {
            let reply = DispatchQueue.main.sync { onQuery?(j) ?? .object([]) }
            let out = Data((reply.serialized() + "\n").utf8)
            _ = out.withUnsafeBytes { SocketClient.writeAll(c, $0.baseAddress!, out.count) }
            close(c)
            return
        }
        guard let e = Event(json: j) else { close(c); return }
        if e.wantsReply, let req = e.data["request"]?.string {
            watch(c, requestId: req)
        } else {
            close(c)
        }
        DispatchQueue.main.async { [weak self] in self?.onEvent?(e) }
    }

    private func watch(_ c: Int32, requestId: String) {
        let w = DispatchSource.makeReadSource(fileDescriptor: c, queue: queue)
        w.setEventHandler { [weak self] in
            var byte: UInt8 = 0
            if recv(c, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0 {
                self?.finish(requestId, reply: nil)
                DispatchQueue.main.async { self?.onAbandon?(requestId) }
            }
        }
        lock.lock(); pending[requestId] = (c, w); lock.unlock()
        w.resume()
    }

    /// Writes the decision back to the waiting hook process and closes the connection.
    func finish(_ requestId: String, reply: JSON?) {
        lock.lock()
        let entry = pending.removeValue(forKey: requestId)
        lock.unlock()
        guard let entry else { return }
        entry.watch.cancel()
        if let reply {
            let out = Data((reply.serialized() + "\n").utf8)
            _ = out.withUnsafeBytes { SocketClient.writeAll(entry.fd, $0.baseAddress!, out.count) }
        }
        close(entry.fd)
    }
}

/// Polls Codex rollout files for live activity, plan steps, tokens and rate limits.
final class CodexWatcher {
    private var files: [String: (offset: UInt64, parser: CodexRollout, remainder: Data)] = [:]
    private let queue = DispatchQueue(label: "clisland.codex")
    private var timer: DispatchSourceTimer?
    var onEvent: ((Event, Bool) -> Void)?

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1.5)
        t.setEventHandler { [weak self] in self?.scan() }
        t.resume()
        timer = t
    }

    private func dayDirs() -> [URL] {
        let cal = Calendar.current
        let root = Paths.codexSessions
        return [0, -1].compactMap { cal.date(byAdding: .day, value: $0, to: Date()) }.map { d in
            let c = cal.dateComponents([.year, .month, .day], from: d)
            return root.appendingPathComponent(String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        }
    }

    private func scan() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Paths.codexSessions.path) else { return }
        let now = Date()
        for dir in dayDirs() {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") {
                let path = dir.appendingPathComponent(name).path
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let size = (attrs[.size] as? NSNumber)?.uint64Value,
                      let mtime = attrs[.modificationDate] as? Date else { continue }
                if files[path] == nil {
                    guard now.timeIntervalSince(mtime) < 1800 else { continue }
                    files[path] = (0, CodexRollout(fileName: name), Data())
                    read(path, upTo: size, replay: now.timeIntervalSince(mtime) > 5)
                } else if size > files[path]!.offset {
                    read(path, upTo: size, replay: false)
                }
            }
        }
        files = files.filter { fm.fileExists(atPath: $0.key) }
    }

    private func read(_ path: String, upTo size: UInt64, replay: Bool) {
        guard var entry = files[path], let h = FileHandle(forReadingAtPath: path) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: entry.offset)
        let chunk = (try? h.read(upToCount: Int(size - entry.offset))) ?? Data()
        entry.offset += UInt64(chunk.count)
        var buf = entry.remainder + chunk
        var events: [Event] = []
        while let nl = buf.firstIndex(of: 0x0A) {
            let lineData = buf[buf.startIndex..<nl]
            buf = Data(buf[buf.index(after: nl)...])
            events += entry.parser.ingest(line: String(decoding: lineData, as: UTF8.self))
        }
        entry.remainder = buf
        files[path] = entry
        if replay {
            events = condense(events)
        }
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in events.forEach { self?.onEvent?($0, replay) } }
    }

    /// On first sight of an older file, keep only state, not toasts.
    private func condense(_ events: [Event]) -> [Event] {
        var out: [Event] = []
        if let start = events.last(where: { $0.kind == .sessionStart }) { out.append(start) }
        if let usage = events.last(where: { $0.kind == .usage }) { out.append(usage) }
        if let tasks = events.last(where: { $0.kind == .tasks }) { out.append(tasks) }
        let lastStart = events.lastIndex(where: { $0.kind == .turnStart }) ?? -1
        let lastDone = events.lastIndex(where: { $0.kind == .turnDone }) ?? -1
        if lastStart > lastDone { out.append(events[lastStart]) }
        return out
    }
}

/// Brings the session's terminal tab to the front.
enum Focus {
    static func focus(_ s: Session) {
        guard let t = s.term else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            if let pane = t.tmuxPane, let tmux = which("tmux") {
                run(tmux, ["select-window", "-t", pane])
                run(tmux, ["select-pane", "-t", pane])
            }
            let app = TermInfo.appName(program: t.program, bundleId: t.bundleId)
            if let tty = t.tty, app == "iTerm2" {
                osascript("""
                tell application "iTerm2"
                  activate
                  repeat with w in windows
                    repeat with tb in tabs of w
                      repeat with se in sessions of tb
                        if tty of se is "/dev/\(tty)" then
                          select w
                          tell tb to select
                          tell se to select
                          return
                        end if
                      end repeat
                    end repeat
                  end repeat
                end tell
                """)
            } else if let tty = t.tty, app == "Terminal" {
                osascript("""
                tell application "Terminal"
                  activate
                  repeat with w in windows
                    repeat with tb in tabs of w
                      if tty of tb is "/dev/\(tty)" then
                        set selected of tb to true
                        set index of w to 1
                        return
                      end if
                    end repeat
                  end repeat
                end tell
                """)
            } else {
                activate(bundleId: t.bundleId ?? bundleId(for: app))
            }
        }
    }

    static func bundleId(for app: String) -> String? {
        ["iTerm2": "com.googlecode.iterm2", "Terminal": "com.apple.Terminal", "Ghostty": "com.mitchellh.ghostty",
         "Warp": "dev.warp.Warp-Stable", "VS Code": "com.microsoft.VSCode", "kitty": "net.kovidgoyal.kitty",
         "Alacritty": "org.alacritty", "WezTerm": "com.github.wez.wezterm"][app]
    }

    static func activate(bundleId: String?) {
        guard let bundleId else { return }
        run("/usr/bin/open", ["-b", bundleId])
    }

    static func osascript(_ script: String) { run("/usr/bin/osascript", ["-e", script]) }

    static func which(_ name: String) -> String? {
        ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"].map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}
