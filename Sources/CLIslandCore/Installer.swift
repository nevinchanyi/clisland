import Foundation

/// Adds and removes CLIsland hooks in each CLI's config, keeping everything else intact.
public enum Installer {
    public static let marker = "clisland"

    // MARK: Binary path

    public static func binaryPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let b = env["CLISLAND_BIN"], !b.isEmpty { return b }
        for dir in (env["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/clisland"
            if FileManager.default.isExecutableFile(atPath: p), !p.contains("/.build/") { return p }
        }
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return URL(fileURLWithPath: exe).resolvingSymlinksInPath().path
    }

    public static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+@")
        if s.unicodeScalars.allSatisfy({ safe.contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Claude Code

    public static let claudeEvents = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                      "Stop", "StopFailure", "Notification", "TaskCreated", "TaskCompleted", "PermissionRequest"]

    public static func patchClaude(_ settings: JSON, bin: String, config: inout Config, statusline: Bool = true) -> JSON {
        var s = unpatchClaude(settings, config: config, restoreStatusline: false)
        if case .null = s { s = .object([]) }
        var hooks = s["hooks"] ?? .object([])
        let cmd = "\(shellQuote(bin)) emit --agent claude"
        for event in claudeEvents {
            var hook: [(String, JSON?)] = [("type", .string("command")), ("command", .string(cmd))]
            if event == "PermissionRequest" {
                hook.append(("timeout", .number(config.approvalTimeout + 15)))
            } else {
                hook.append(("async", .bool(true)))
                hook.append(("timeout", .number(10)))
            }
            var group: [(String, JSON?)] = []
            if event == "PostToolUse" { group.append(("matcher", .string("TodoWrite|TaskUpdate"))) }
            group.append(("hooks", .array([.obj(hook)])))
            var list = hooks[event]?.array ?? []
            list.append(.obj(group))
            hooks[event] = .array(list)
        }
        s["hooks"] = hooks

        if statusline {
            let current = s["statusLine"]?["command"]?.string
            if let current, !current.contains("\(marker) statusline") { config.statuslineOriginal = current }
            var line = s["statusLine"] ?? .object([])
            if line.members == nil { line = .object([]) }
            line["type"] = .string("command")
            line["command"] = .string("\(shellQuote(bin)) statusline")
            s["statusLine"] = line
        }
        return s
    }

    public static func unpatchClaude(_ settings: JSON, config: Config, restoreStatusline: Bool = true) -> JSON {
        var s = settings
        if var hooks = s["hooks"], let members = hooks.members {
            for m in members {
                guard let groups = m.value.array else { continue }
                let cleaned: [JSON] = groups.compactMap { group in
                    guard let list = group["hooks"]?.array else { return group }
                    let kept = list.filter { !($0["command"]?.string?.contains("\(marker) emit") ?? false) }
                    if kept.isEmpty { return nil }
                    var g = group
                    g["hooks"] = .array(kept)
                    return g
                }
                hooks[m.key] = cleaned.isEmpty ? nil : .array(cleaned)
            }
            s["hooks"] = (hooks.members?.isEmpty ?? true) ? nil : hooks
        }
        if restoreStatusline, let cmd = s["statusLine"]?["command"]?.string, cmd.contains("\(marker) statusline") {
            if let original = config.statuslineOriginal {
                var line = s["statusLine"]!
                line["command"] = .string(original)
                s["statusLine"] = line
            } else {
                s["statusLine"] = nil
            }
        }
        return s
    }

    // MARK: Gemini CLI

    public static let geminiEvents = ["SessionStart", "SessionEnd", "BeforeAgent", "AfterAgent", "BeforeTool", "Notification"]

    public static func patchGemini(_ settings: JSON, bin: String) -> JSON {
        var s = unpatchGemini(settings)
        if case .null = s { s = .object([]) }
        var hooks = s["hooks"] ?? .object([])
        for event in geminiEvents {
            let hook = JSON.obj([("name", .string("clisland")), ("type", .string("command")),
                                 ("command", .string("\(shellQuote(bin)) emit --agent gemini")), ("timeout", .number(5000))])
            var group: [(String, JSON?)] = []
            if event == "BeforeTool" { group.append(("matcher", .string("*"))) }
            group.append(("hooks", .array([hook])))
            var list = hooks[event]?.array ?? []
            list.append(.obj(group))
            hooks[event] = .array(list)
        }
        s["hooks"] = hooks
        return s
    }

    public static func unpatchGemini(_ settings: JSON) -> JSON {
        unpatchClaude(settings, config: Config(), restoreStatusline: false)
    }

    // MARK: Codex CLI (config.toml, line based)

    public static func patchCodex(_ toml: String, bin: String) -> (text: String, original: [String]?) {
        var lines = toml.components(separatedBy: "\n")
        let ours = "notify = [\(([bin, "emit", "--agent", "codex"]).map { "\"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", "))]"
        var original: [String]?
        if let (start, end) = topLevelKeyRange(lines, key: "notify") {
            let text = lines[start...end].joined(separator: "\n")
            if !text.contains(marker) { original = stringArray(text) }
            lines.replaceSubrange(start...end, with: [ours])
        } else {
            lines.insert(ours, at: 0)
        }
        return (lines.joined(separator: "\n"), original)
    }

    public static func unpatchCodex(_ toml: String, original: [String]?) -> String {
        var lines = toml.components(separatedBy: "\n")
        guard let (start, end) = topLevelKeyRange(lines, key: "notify"),
              lines[start...end].joined().contains(marker) else { return toml }
        if let original, !original.isEmpty {
            let restored = "notify = [\(original.map { "\"\($0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", "))]"
            lines.replaceSubrange(start...end, with: [restored])
        } else {
            lines.removeSubrange(start...end)
        }
        return lines.joined(separator: "\n")
    }

    static func topLevelKeyRange(_ lines: [String], key: String) -> (Int, Int)? {
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { return nil }
            guard t.range(of: "^\(key)\\s*=", options: .regularExpression) != nil else { continue }
            var depth = 0
            var j = i
            while j < lines.count {
                for ch in lines[j] { if ch == "[" { depth += 1 } else if ch == "]" { depth -= 1 } }
                if depth <= 0 { return (i, j) }
                j += 1
            }
            return (i, i)
        }
        return nil
    }

    static func stringArray(_ text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
        }
    }

    // MARK: Launch agent

    public static func launchAgentPlist(bin: String) -> String {
        let esc: (String) -> String = { $0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(Config.launchLabel)</string>
          <key>ProgramArguments</key>
          <array><string>\(esc(bin))</string><string>app</string></array>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
          <key>ProcessType</key><string>Interactive</string>
          <key>StandardErrorPath</key><string>\(esc(Paths.log.path))</string>
          <key>StandardOutPath</key><string>\(esc(Paths.log.path))</string>
        </dict>
        </plist>

        """
    }

    // MARK: File helpers

    public static func backup(_ url: URL, stamp: String) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let dir = Paths.backups.appendingPathComponent(stamp)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = url.deletingLastPathComponent().lastPathComponent.replacingOccurrences(of: ".", with: "") + "-" + url.lastPathComponent
        try? FileManager.default.copyItem(at: url, to: dir.appendingPathComponent(name))
    }

    public static func readJSON(_ url: URL) throws -> JSON {
        guard let data = FileManager.default.contents(atPath: url.path) else { return .object([]) }
        if data.allSatisfy({ [0x20, 0x0A, 0x0D, 0x09].contains($0) }) { return .object([]) }
        guard let j = JSON.parse(data) else {
            throw NSError(domain: "clisland", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.path) is not valid JSON (comments are not supported). Fix it or pass --only to skip."])
        }
        return j
    }

    public static func writeJSON(_ j: JSON, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((j.serialized(pretty: true) + "\n").utf8).write(to: url, options: .atomic)
    }

    public static var stamp: String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}
