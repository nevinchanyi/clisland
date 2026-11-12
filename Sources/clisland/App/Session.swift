import CLIslandCore
import Foundation
import SwiftUI

struct TaskItem: Equatable, Identifiable {
    var id: String
    var title: String
    var status: String
    var active: String?
    var done: Bool { status == "completed" }
}

struct Limit: Equatable, Identifiable {
    var name: String
    var pct: Double
    var resetsAt: Date?
    var id: String { name }
}

enum SessionStatus: String {
    case idle, working, done, attention, error

    var label: String {
        switch self {
        case .idle: return "idle"
        case .working: return "working"
        case .done: return "done"
        case .attention: return "needs you"
        case .error: return "error"
        }
    }
}

struct Session: Identifiable, Equatable {
    var id: String
    var agent: String
    var sessionId: String
    var cwd: String?
    var term: TermInfo?
    var status: SessionStatus = .idle
    var activity: String?
    var tasks: [TaskItem] = []
    var contextPct: Double?
    var costUSD: Double?
    var model: String?
    var limits: [Limit] = []
    var commands: [String] = []
    var summary: String?
    var turnStartedAt: Date?
    var lastDuration: TimeInterval?
    var lastEventAt = Date()
    var lastDoneAt: Date?
    var unread = false
    var stuckNotified = false
    var contextWarned = false
    var runCommand: String?
    var exitCode: Int?
    var tail: [String] = []
    var errorMessage: String?
    var isDemo = false

    var project: String {
        if let runCommand, agent == "run" { return runCommand.firstLine.clipped(28) }
        if let cwd, !cwd.isEmpty { return cwd.lastPathComponent }
        return Theme.name(agent)
    }

    var taskProgress: (done: Int, total: Int)? {
        guard !tasks.isEmpty else { return nil }
        return (tasks.filter(\.done).count, tasks.count)
    }

    var activeTask: String? {
        tasks.first(where: { $0.status == "in_progress" }).map { $0.active ?? $0.title }
    }

    var liveLine: String? {
        if let activity { return activity }
        if let activeTask { return activeTask }
        if agent == "run", status == .working, let runCommand { return "Running \(runCommand.clipped(40))" }
        return status == .working ? "Thinking" : nil
    }
}

enum Theme {
    static func color(_ agent: String) -> Color {
        switch agent {
        case "claude": return Color(red: 0.886, green: 0.502, blue: 0.373)
        case "codex": return Color(red: 0.247, green: 0.784, blue: 0.635)
        case "gemini": return Color(red: 0.541, green: 0.592, blue: 1.0)
        default: return Color(white: 0.86)
        }
    }

    static func glyph(_ agent: String) -> String {
        switch agent {
        case "claude": return "✻"
        case "codex": return ">_"
        case "gemini": return "✦"
        default: return "▸"
        }
    }

    static func name(_ agent: String) -> String { Agent(rawValue: agent)?.displayName ?? agent }

    static let ok = Color(red: 0.29, green: 0.87, blue: 0.5)
    static let warn = Color(red: 0.98, green: 0.75, blue: 0.14)
    static let err = Color(red: 0.97, green: 0.44, blue: 0.44)
    static let muted = Color(white: 0.6)
    static let panel = Color(white: 0.09)
    static let line = Color(white: 0.17)

    static func contextColor(_ pct: Double) -> Color {
        pct >= 85 ? err : pct >= 70 ? warn : ok
    }

    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }

    static func until(_ d: Date?) -> String? {
        guard let d else { return nil }
        let s = Int(d.timeIntervalSinceNow)
        if s <= 0 { return "now" }
        if s < 3600 { return "\(max(1, s / 60))m" }
        if s < 86400 { return "\(s / 3600)h \((s % 3600) / 60)m" }
        return "\(s / 86400)d \((s % 86400) / 3600)h"
    }
}
