import CLIslandCore
import Darwin
import Foundation

enum Setup {
    struct Options {
        var only: Set<String>?
        var statusline = true
        var launch = true
        var dryRun = false
    }

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--only":
                i += 1
                if i < args.count { o.only = Set(args[i].split(separator: ",").map { String($0).lowercased() }) }
            case "--no-statusline": o.statusline = false
            case "--no-launch": o.launch = false
            case "--dry-run": o.dryRun = true
            default: break
            }
            i += 1
        }
        return o
    }

    static func detected() -> [String: Bool] {
        let fm = FileManager.default
        return [
            "claude": fm.fileExists(atPath: Paths.claudeSettings.deletingLastPathComponent().path) || onPath("claude"),
            "codex": fm.fileExists(atPath: Paths.codexHome.path) || onPath("codex"),
            "gemini": fm.fileExists(atPath: Paths.geminiSettings.deletingLastPathComponent().path) || onPath("gemini"),
        ]
    }

    static func onPath(_ name: String) -> Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains {
            FileManager.default.isExecutableFile(atPath: "\($0)/\(name)")
        }
    }

    static func wants(_ agent: String, _ o: Options, _ found: [String: Bool]) -> Bool {
        if let only = o.only { return only.contains(agent) }
        return found[agent] ?? false
    }

    static func install(_ args: [String]) -> Int32 {
        let o = parse(args)
        let bin = Installer.binaryPath()
        let stamp = Installer.stamp
        let found = detected()
        var config = Config.load()
        var failed = false
        Paths.ensureRoot()
        print("CLIsland setup\(o.dryRun ? " (dry run)" : "")")
        print("  binary: \(bin)")

        if wants("claude", o, found) {
            do {
                let url = Paths.claudeSettings
                let before = try Installer.readJSON(url)
                let after = Installer.patchClaude(before, bin: bin, config: &config, statusline: o.statusline)
                if !o.dryRun {
                    Installer.backup(url, stamp: stamp)
                    try Installer.writeJSON(after, to: url)
                }
                print("  ✓ Claude Code   \(url.path)  (\(Installer.claudeEvents.count) hooks\(o.statusline ? " + statusLine" : ""))")
                if o.statusline, let orig = config.statuslineOriginal { print("                  your status line is kept: \(orig.clipped(60))") }
            } catch { print("  ✗ Claude Code   \(error.localizedDescription)"); failed = true }
        } else { print("  – Claude Code   not found, skipped") }

        if wants("codex", o, found) {
            do {
                let url = Paths.codexConfig
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let (patched, original) = Installer.patchCodex(text, bin: bin)
                if let original { config.codexNotifyOriginal = original }
                if !o.dryRun {
                    Installer.backup(url, stamp: stamp)
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try patched.write(to: url, atomically: true, encoding: .utf8)
                }
                print("  ✓ Codex CLI     \(url.path)  (notify + session watcher)")
                if let original { print("                  your notify program still runs: \(original.joined(separator: " ").clipped(60))") }
            } catch { print("  ✗ Codex CLI     \(error.localizedDescription)"); failed = true }
        } else { print("  – Codex CLI     not found, skipped") }

        if wants("gemini", o, found) {
            do {
                let url = Paths.geminiSettings
                let after = Installer.patchGemini(try Installer.readJSON(url), bin: bin)
                if !o.dryRun {
                    Installer.backup(url, stamp: stamp)
                    try Installer.writeJSON(after, to: url)
                }
                print("  ✓ Gemini CLI    \(url.path)  (\(Installer.geminiEvents.count) hooks)")
            } catch { print("  ✗ Gemini CLI    \(error.localizedDescription)"); failed = true }
        } else { print("  – Gemini CLI    not found, skipped") }

        if !o.dryRun {
            try? config.save()
            if o.launch {
                installLaunchAgent(bin: bin)
                print("  ✓ Launch agent  starts CLIsland at login and now")
            }
            print("  backups: \(Paths.backups.appendingPathComponent(stamp).path)")
            print("\nDone. Restart running agent sessions so they pick up the hooks. Try: clisland demo")
        }
        return failed ? 1 : 0
    }

    static func uninstall(_ args: [String]) -> Int32 {
        let purge = args.contains("--purge")
        let config = Config.load()
        let stamp = Installer.stamp
        if let j = try? Installer.readJSON(Paths.claudeSettings), FileManager.default.fileExists(atPath: Paths.claudeSettings.path) {
            Installer.backup(Paths.claudeSettings, stamp: stamp)
            try? Installer.writeJSON(Installer.unpatchClaude(j, config: config), to: Paths.claudeSettings)
            print("  ✓ Claude Code hooks removed")
        }
        if let text = try? String(contentsOf: Paths.codexConfig, encoding: .utf8) {
            let restored = Installer.unpatchCodex(text, original: config.codexNotifyOriginal)
            if restored != text {
                Installer.backup(Paths.codexConfig, stamp: stamp)
                try? restored.write(to: Paths.codexConfig, atomically: true, encoding: .utf8)
                print("  ✓ Codex notify restored")
            }
        }
        if let j = try? Installer.readJSON(Paths.geminiSettings), FileManager.default.fileExists(atPath: Paths.geminiSettings.path) {
            Installer.backup(Paths.geminiSettings, stamp: stamp)
            try? Installer.writeJSON(Installer.unpatchGemini(j), to: Paths.geminiSettings)
            print("  ✓ Gemini CLI hooks removed")
        }
        stopApp()
        launchctl(["bootout", "gui/\(getuid())/\(Config.launchLabel)"])
        try? FileManager.default.removeItem(at: Paths.launchAgent)
        print("  ✓ Launch agent removed")
        if purge {
            try? FileManager.default.removeItem(at: Paths.root)
            print("  ✓ ~/.clisland deleted")
        } else {
            print("  backups kept in \(Paths.backups.path)")
        }
        return 0
    }

    static func installLaunchAgent(bin: String) {
        let url = Paths.launchAgent
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Installer.launchAgentPlist(bin: bin).write(to: url, atomically: true, encoding: .utf8)
        stopApp()
        launchctl(["bootout", "gui/\(getuid())/\(Config.launchLabel)"])
        launchctl(["bootstrap", "gui/\(getuid())", url.path])
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func query(_ cmd: String) -> JSON? {
        let req = JSON.obj([("agent", .string("cli")), ("kind", .string("status")), ("data", .obj([("cmd", .string(cmd))]))])
        return SocketClient.send(req.data, waitReply: true, timeout: 1).flatMap { JSON.parse($0) }
    }

    static func stopApp() {
        _ = query("quit")
        usleep(300_000)
    }

    static func start() -> Int32 {
        if query("ping") != nil { print("CLIsland is already running."); return 0 }
        if FileManager.default.fileExists(atPath: Paths.launchAgent.path) {
            launchctl(["bootstrap", "gui/\(getuid())", Paths.launchAgent.path])
            launchctl(["kickstart", "gui/\(getuid())/\(Config.launchLabel)"])
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: Installer.binaryPath())
            p.arguments = ["app"]
            Paths.ensureRoot()
            FileManager.default.createFile(atPath: Paths.log.path, contents: nil)
            let log = FileHandle(forWritingAtPath: Paths.log.path)
            p.standardOutput = log
            p.standardError = log
            try? p.run()
        }
        for _ in 0..<20 {
            if query("ping") != nil { print("CLIsland started."); return 0 }
            usleep(150_000)
        }
        print("CLIsland did not start. See \(Paths.log.path)")
        return 1
    }

    static func stop() -> Int32 {
        launchctl(["bootout", "gui/\(getuid())/\(Config.launchLabel)"])
        stopApp()
        print("CLIsland stopped.")
        return 0
    }

    static func status() -> Int32 {
        guard let j = query("sessions") else { print("CLIsland is not running. Start it with: clisland start"); return 1 }
        let sessions = j["sessions"]?.array ?? []
        if sessions.isEmpty { print("No agent sessions."); return 0 }
        for s in sessions {
            let ctx = s["context_pct"]?.double.map { "\(Int($0))%" } ?? "–"
            let line = [s["agent"]?.string ?? "", s["project"]?.string ?? "", s["status"]?.string ?? "",
                        "ctx \(ctx)", s["tasks"]?.string.map { "tasks \($0)" }, s["activity"]?.string, s["terminal"]?.string]
                .compactMap { $0 }.joined(separator: "  ")
            print(line)
        }
        return 0
    }

    static func doctor() -> Int32 {
        let bin = Installer.binaryPath()
        print("binary        \(bin)")
        print("app           \(query("ping") != nil ? "running" : "not running")")
        print("socket        \(Paths.socket.path)")
        let claude = (try? String(contentsOf: Paths.claudeSettings, encoding: .utf8)) ?? ""
        print("claude hooks  \(claude.contains("clisland emit") ? "installed" : "missing")  statusLine \(claude.contains("clisland statusline") ? "wrapped" : "not wrapped")")
        let codex = (try? String(contentsOf: Paths.codexConfig, encoding: .utf8)) ?? ""
        print("codex notify  \(codex.contains("clisland") ? "installed" : "missing")  sessions dir \(FileManager.default.fileExists(atPath: Paths.codexSessions.path) ? "found" : "not found")")
        let gemini = (try? String(contentsOf: Paths.geminiSettings, encoding: .utf8)) ?? ""
        print("gemini hooks  \(gemini.contains("clisland emit") ? "installed" : "missing")")
        print("launch agent  \(FileManager.default.fileExists(atPath: Paths.launchAgent.path) ? "installed" : "missing")")
        return 0
    }
}
