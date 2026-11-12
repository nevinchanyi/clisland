import Foundation

/// Incremental parser for one Codex rollout file (~/.codex/sessions/**/rollout-*.jsonl).
public struct CodexRollout {
    public var session: String
    public var cwd: String?
    public var lastUsage: JSON?

    public init(fileName: String) {
        let base = (fileName as NSString).deletingPathExtension
        let uuid = base.range(of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .regularExpression).map { String(base[$0]) }
        session = uuid ?? base
    }

    public mutating func ingest(line: String) -> [Event] {
        guard let j = JSON.parse(line), let type = j["type"]?.string else { return [] }
        let p = j["payload"] ?? .object([])
        func ev(_ kind: EventKind, _ data: [(String, JSON?)] = []) -> Event {
            Event(agent: "codex", kind: kind, session: session, cwd: cwd, data: .obj(data))
        }

        switch type {
        case "session_meta":
            if let id = p["id"]?.string { session = id }
            cwd = p["cwd"]?.string ?? cwd
            return [ev(.sessionStart)]
        case "turn_context":
            cwd = p["cwd"]?.string ?? cwd
            return []
        case "event_msg":
            switch p["type"]?.string ?? "" {
            case "task_started", "turn_started":
                return [ev(.turnStart)]
            case "user_message":
                return [ev(.turnStart, [("prompt", .str(p["message"]?.string?.clipped(200)))])]
            case "token_count":
                return usage(p).map { [ev(.usage, $0)] } ?? []
            case "task_complete", "turn_complete":
                let msg = p["last_agent_message"]?.string ?? ""
                return [ev(.turnDone, Normalizer.doneData(msg))]
            case "error", "stream_error":
                return [ev(.error, [("message", .str((p["message"]?.string ?? "Codex error").clipped(200)))])]
            case "turn_aborted":
                return [ev(.turnDone, [("summary", .string("Turn interrupted")), ("aborted", .bool(true))])]
            default:
                return []
            }
        case "response_item":
            let itemType = p["type"]?.string ?? ""
            guard ["function_call", "custom_tool_call", "local_shell_call"].contains(itemType) else { return [] }
            let name = p["name"]?.string ?? (itemType == "local_shell_call" ? "local_shell" : "")
            var args: JSON = .object([])
            if let s = p["arguments"]?.string { args = JSON.parse(s) ?? .string(s) }
            else if let s = p["input"]?.string { args = .obj([("input", .string(s))]) }
            else if let a = p["action"] { args = a }
            if name == "update_plan", let plan = args["plan"]?.array {
                let items: [JSON] = plan.enumerated().map { i, step in
                    .obj([("id", .string(String(i))), ("title", .str(step["step"]?.string)), ("status", .str(step["status"]?.string))])
                }
                return [ev(.tasks, [("items", .array(items))])]
            }
            guard let label = ToolLabel.codex(name: name, arguments: args) else { return [] }
            return [ev(.activity, [("label", .string(label)), ("tool", .string(name))])]
        default:
            return []
        }
    }

    func usage(_ p: JSON) -> [(String, JSON?)]? {
        var out: [(String, JSON?)] = []
        if let info = p["info"], !info.isNull {
            let window = info["model_context_window"]?.double
            let last = info["last_token_usage"]
            let input = last?["input_tokens"]?.double ?? last?["total_tokens"]?.double
            if let window, let input, window > 0 {
                out.append(("context_pct", .number((input / window * 100).rounded())))
                out.append(("context_window", .number(window)))
            }
        }
        if let rl = p["rate_limits"], !rl.isNull {
            var limits = [JSON]()
            for key in ["primary", "secondary"] {
                guard let w = rl[key], let pct = w["used_percent"]?.double else { continue }
                let minutes = w["window_minutes"]?.double ?? 0
                let name = minutes >= 1440 ? "\(Int(minutes / 1440))d" : minutes > 0 ? "\(Int(minutes / 60))h" : key
                var resets = w["resets_at"]?.double
                if resets == nil, let inSec = w["resets_in_seconds"]?.double { resets = Date().timeIntervalSince1970 + inSec }
                limits.append(.obj([("name", .string(name)), ("pct", .number(pct)), ("resets_at", .num(resets))]))
            }
            if !limits.isEmpty { out.append(("limits", .array(limits))) }
        }
        return out.isEmpty ? nil : out
    }
}
