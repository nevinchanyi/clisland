import Foundation

public enum Paths {
    public static var home: URL {
        if let h = ProcessInfo.processInfo.environment["HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var root: URL {
        if let r = ProcessInfo.processInfo.environment["CLISLAND_DIR"], !r.isEmpty { return URL(fileURLWithPath: r) }
        return home.appendingPathComponent(".clisland")
    }

    public static var socket: URL { root.appendingPathComponent("clisland.sock") }
    public static var config: URL { root.appendingPathComponent("config.json") }
    public static var backups: URL { root.appendingPathComponent("backups") }
    public static var log: URL { root.appendingPathComponent("app.log") }

    public static var claudeSettings: URL {
        if let d = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !d.isEmpty {
            return URL(fileURLWithPath: d).appendingPathComponent("settings.json")
        }
        return home.appendingPathComponent(".claude/settings.json")
    }

    public static var codexHome: URL {
        if let d = ProcessInfo.processInfo.environment["CODEX_HOME"], !d.isEmpty { return URL(fileURLWithPath: d) }
        return home.appendingPathComponent(".codex")
    }

    public static var codexConfig: URL { codexHome.appendingPathComponent("config.toml") }
    public static var codexSessions: URL { codexHome.appendingPathComponent("sessions") }
    public static var geminiSettings: URL { home.appendingPathComponent(".gemini/settings.json") }
    public static var launchAgent: URL { home.appendingPathComponent("Library/LaunchAgents/\(Config.launchLabel).plist") }

    public static func ensureRoot() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

/// User settings in ~/.clisland/config.json, plus what setup replaced so uninstall can restore it.
public struct Config: Equatable {
    public static let launchLabel = "dev.clisland.app"

    public var sounds = true
    public var activityLine = true
    public var stuckMinutes = 5.0
    public var approveFromNotch = true
    public var approvalTimeout = 30.0
    public var contextWarnPct = 85.0
    public var limitWarnPct = 80.0
    public var doneToastSeconds = 6.0
    public var statuslineOriginal: String?
    public var codexNotifyOriginal: [String]?

    public init() {}

    public static func load() -> Config {
        var c = Config()
        guard let data = FileManager.default.contents(atPath: Paths.config.path), let j = JSON.parse(data) else { return c }
        c.sounds = j["sounds"]?.bool ?? c.sounds
        c.activityLine = j["activity_line"]?.bool ?? c.activityLine
        c.stuckMinutes = j["stuck_minutes"]?.double ?? c.stuckMinutes
        c.approveFromNotch = j["approve_from_notch"]?.bool ?? c.approveFromNotch
        c.approvalTimeout = j["approval_timeout"]?.double ?? c.approvalTimeout
        c.contextWarnPct = j["context_warn_pct"]?.double ?? c.contextWarnPct
        c.limitWarnPct = j["limit_warn_pct"]?.double ?? c.limitWarnPct
        c.doneToastSeconds = j["done_toast_seconds"]?.double ?? c.doneToastSeconds
        c.statuslineOriginal = j["statusline_original"]?.string
        c.codexNotifyOriginal = j["codex_notify_original"]?.array?.compactMap(\.string)
        return c
    }

    public func save() throws {
        Paths.ensureRoot()
        let j = JSON.obj([
            ("sounds", .bool(sounds)),
            ("activity_line", .bool(activityLine)),
            ("stuck_minutes", .number(stuckMinutes)),
            ("approve_from_notch", .bool(approveFromNotch)),
            ("approval_timeout", .number(approvalTimeout)),
            ("context_warn_pct", .number(contextWarnPct)),
            ("limit_warn_pct", .number(limitWarnPct)),
            ("done_toast_seconds", .number(doneToastSeconds)),
            ("statusline_original", .str(statuslineOriginal)),
            ("codex_notify_original", codexNotifyOriginal.map(JSON.strings)),
        ])
        try Data((j.serialized(pretty: true) + "\n").utf8).write(to: Paths.config, options: .atomic)
    }
}
