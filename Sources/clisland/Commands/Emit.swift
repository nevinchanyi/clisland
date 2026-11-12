import CLIslandCore
import Darwin
import Foundation

/// `clisland emit`: called by agent hooks. Never fails the caller, always exits 0.
enum Emit {
    static func run(_ args: [String]) -> Int32 {
        var agent = "claude"
        var kind: String?
        var session: String?
        var message: String?
        var positional: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
            switch a {
            case "--agent": agent = next() ?? agent
            case "--event", "--kind": kind = next()
            case "--session": session = next()
            case "--message": message = next()
            default: positional.append(a)
            }
            i += 1
        }

        let input = isatty(STDIN_FILENO) == 0 && agent != "codex" ? FileHandle.standardInput.readDataToEndOfFile() : Data()
        var events: [Event] = []
        let config = Config.load()

        switch agent {
        case "claude":
            if let j = JSON.parse(input) { events = Normalizer.claude(j) }
        case "gemini":
            if let j = JSON.parse(input) { events = Normalizer.gemini(j) }
        case "codex":
            let raw = positional.last ?? ""
            if let original = config.codexNotifyOriginal, !original.isEmpty { chain(original + [raw]) }
            if let j = JSON.parse(raw) { events = Normalizer.codexNotify(j) }
        default:
            break
        }
        if events.isEmpty, let kind, let k = EventKind(rawValue: kind) {
            events = [Event(agent: agent, kind: k, session: session ?? "manual-\(getppid())",
                            data: .obj([("summary", .str(message)), ("message", .str(message)), ("label", .str(message))]))]
        }

        let term = ProcInfo.currentTerm()
        let cwd = FileManager.default.currentDirectoryPath
        for var e in events {
            e.term = term
            if e.cwd == nil { e.cwd = cwd }
            if e.kind == .permission {
                permission(e, config: config)
            } else {
                SocketClient.send(e.line, timeout: 1)
            }
        }
        if agent == "gemini" { print("{}") }
        return 0
    }

    private static func permission(_ e: Event, config: Config) {
        guard config.approveFromNotch,
              let reply = SocketClient.send(e.line, waitReply: true, timeout: config.approvalTimeout + 5),
              let j = JSON.parse(reply), let decision = j["decision"]?.string else { return }
        let out: JSON
        switch decision {
        case "allow":
            out = .obj([("hookSpecificOutput", .obj([("hookEventName", .string("PermissionRequest")),
                                                    ("decision", .obj([("behavior", .string("allow"))]))]))])
        case "deny":
            out = .obj([("hookSpecificOutput", .obj([("hookEventName", .string("PermissionRequest")),
                                                    ("decision", .obj([("behavior", .string("deny")),
                                                                       ("message", .string("Denied from CLIsland"))]))]))])
        default:
            return
        }
        print(out.serialized())
    }

    private static func chain(_ argv: [String]) {
        guard let exe = argv.first else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe.hasPrefix("/") ? exe : "/usr/bin/env")
        p.arguments = exe.hasPrefix("/") ? Array(argv.dropFirst()) : argv
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

/// `clisland statusline`: forwards Claude's status line JSON, then prints the user's own status line.
enum Statusline {
    static func run() -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let json = JSON.parse(input)
        if let j = json, var e = Normalizer.claudeStatusline(j) {
            e.term = ProcInfo.currentTerm()
            SocketClient.send(e.line, timeout: 0.3)
        }
        let config = Config.load()
        if let original = config.statuslineOriginal, !original.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", original]
            let pipe = Pipe()
            p.standardInput = pipe
            do {
                try p.run()
                pipe.fileHandleForWriting.write(input)
                try? pipe.fileHandleForWriting.close()
                p.waitUntilExit()
                return p.terminationStatus
            } catch { return 0 }
        }
        guard let j = json else { return 0 }
        var parts: [String] = []
        if let m = j["model"]?["display_name"]?.string { parts.append(m) }
        if let pct = j["context_window"]?["used_percentage"]?.double { parts.append("ctx \(Int(pct))%") }
        if let c = j["cost"]?["total_cost_usd"]?.double { parts.append(String(format: "$%.2f", c)) }
        if let five = j["rate_limits"]?["five_hour"]?["used_percentage"]?.double { parts.append("5h \(Int(five))%") }
        print(parts.joined(separator: " · "))
        return 0
    }
}
