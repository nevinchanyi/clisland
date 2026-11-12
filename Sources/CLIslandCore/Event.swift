import Foundation

public enum Agent: String, CaseIterable, Sendable {
    case claude, codex, gemini, run

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .gemini: return "Gemini CLI"
        case .run: return "clisland run"
        }
    }
}

public enum EventKind: String, Sendable {
    case sessionStart = "session_start"
    case sessionEnd = "session_end"
    case turnStart = "turn_start"
    case activity
    case tasks
    case taskUpdate = "task_update"
    case turnDone = "turn_done"
    case attention
    case permission
    case usage
    case error
    case runStart = "run_start"
    case runDone = "run_done"
    case status
    case demo
}

/// Where a session lives, so the app can focus the right terminal tab.
public struct TermInfo: Equatable, Sendable {
    public var tty: String?
    public var program: String?
    public var bundleId: String?
    public var sessionId: String?
    public var tmuxPane: String?
    public var agentPid: Int32?

    public init(tty: String? = nil, program: String? = nil, bundleId: String? = nil, sessionId: String? = nil, tmuxPane: String? = nil, agentPid: Int32? = nil) {
        self.tty = tty; self.program = program; self.bundleId = bundleId
        self.sessionId = sessionId; self.tmuxPane = tmuxPane; self.agentPid = agentPid
    }

    public var json: JSON {
        .obj([
            ("tty", .str(tty)), ("program", .str(program)), ("bundle_id", .str(bundleId)),
            ("session_id", .str(sessionId)), ("tmux_pane", .str(tmuxPane)),
            ("agent_pid", agentPid.map { .number(Double($0)) }),
        ])
    }

    public init(json: JSON) {
        tty = json["tty"]?.string
        program = json["program"]?.string
        bundleId = json["bundle_id"]?.string
        sessionId = json["session_id"]?.string
        tmuxPane = json["tmux_pane"]?.string
        agentPid = json["agent_pid"]?.int.map { Int32($0) }
    }

    /// Short human label such as "iTerm2 · ttys003".
    public var label: String {
        let app = TermInfo.appName(program: program, bundleId: bundleId)
        if let tty { return "\(app) · \(tty)" }
        return app
    }

    public static func appName(program: String?, bundleId: String?) -> String {
        let p = program ?? "", b = bundleId ?? ""
        let table: [(String?, String?, String)] = [
            ("iTerm.app", "com.googlecode.iterm2", "iTerm2"), ("Apple_Terminal", "com.apple.Terminal", "Terminal"),
            ("ghostty", "com.mitchellh.ghostty", "Ghostty"), ("WarpTerminal", "dev.warp", "Warp"),
            (nil, "com.microsoft.VSCode", "VS Code"), (nil, "com.todesktop", "Cursor"), ("vscode", nil, "VS Code"),
            ("kitty", "net.kovidgoyal.kitty", "kitty"), ("alacritty", "org.alacritty", "Alacritty"),
            ("WezTerm", "com.github.wez.wezterm", "WezTerm"), ("tmux", nil, "tmux"),
        ]
        for (prog, bundle, name) in table {
            if let bundle, !b.isEmpty, b.hasPrefix(bundle) { return name }
            if let prog, p == prog { return name }
        }
        return program ?? "Terminal"
    }
}

public struct Event: Sendable {
    public var agent: String
    public var kind: EventKind
    public var session: String
    public var cwd: String?
    public var term: TermInfo?
    public var data: JSON
    public var wantsReply: Bool
    public var time: Date

    public init(agent: String, kind: EventKind, session: String, cwd: String? = nil, term: TermInfo? = nil,
                data: JSON = .object([]), wantsReply: Bool = false, time: Date = Date()) {
        self.agent = agent; self.kind = kind; self.session = session; self.cwd = cwd
        self.term = term; self.data = data; self.wantsReply = wantsReply; self.time = time
    }

    public var json: JSON {
        .obj([
            ("v", .number(1)),
            ("agent", .string(agent)),
            ("kind", .string(kind.rawValue)),
            ("session", .string(session)),
            ("cwd", .str(cwd)),
            ("term", term?.json),
            ("data", data),
            ("reply", wantsReply ? .bool(true) : nil),
            ("time", .number(time.timeIntervalSince1970)),
        ])
    }

    public init?(json: JSON) {
        guard let agent = json["agent"]?.string,
              let kindRaw = json["kind"]?.string, let kind = EventKind(rawValue: kindRaw) else { return nil }
        self.agent = agent
        self.kind = kind
        self.session = json["session"]?.string ?? "default"
        self.cwd = json["cwd"]?.string
        self.term = json["term"].map(TermInfo.init(json:))
        self.data = json["data"] ?? .object([])
        self.wantsReply = json["reply"]?.bool ?? false
        self.time = json["time"]?.double.map { Date(timeIntervalSince1970: $0) } ?? Date()
    }

    public var line: Data { Data((json.serialized() + "\n").utf8) }
}

public extension String {
    func clipped(_ n: Int) -> String {
        count > n ? String(prefix(n - 1)) + "…" : self
    }

    var firstLine: String {
        split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? self
    }

    var lastPathComponent: String { (self as NSString).lastPathComponent }
}
