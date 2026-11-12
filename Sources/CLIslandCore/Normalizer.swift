import Foundation

/// Turns raw hook payloads from each CLI into CLIsland events.
public enum Normalizer {

    // MARK: Claude Code

    public static func claude(_ hook: JSON) -> [Event] {
        let session = hook["session_id"]?.string ?? "claude"
        let cwd = hook["cwd"]?.string
        func ev(_ kind: EventKind, _ data: [(String, JSON?)] = [], reply: Bool = false) -> Event {
            Event(agent: "claude", kind: kind, session: session, cwd: cwd, data: .obj(data), wantsReply: reply)
        }
        let tool = hook["tool_name"]?.string ?? ""
        let input = hook["tool_input"] ?? .object([])

        switch hook["hook_event_name"]?.string ?? "" {
        case "SessionStart":
            return [ev(.sessionStart, [("source", .str(hook["source"]?.string)), ("model", .str(hook["model"]?.string))])]
        case "SessionEnd":
            return [ev(.sessionEnd, [("reason", .str(hook["reason"]?.string))])]
        case "UserPromptSubmit":
            return [ev(.turnStart, [("prompt", .str(hook["prompt"]?.string.map { $0.clipped(200) }))])]
        case "PreToolUse":
            var out = [Event]()
            if let label = ToolLabel.claude(tool: tool, input: input) {
                out.append(ev(.activity, [("label", .string(label)), ("tool", .string(tool))]))
            }
            return out
        case "PostToolUse":
            if tool == "TodoWrite", let todos = input["todos"]?.array {
                let items: [JSON] = todos.enumerated().map { i, t in
                    .obj([("id", .string(String(i))),
                          ("title", .str(t["content"]?.string)),
                          ("active", .str(t["activeForm"]?.string)),
                          ("status", .str(t["status"]?.string))])
                }
                return [ev(.tasks, [("items", .array(items))])]
            }
            if tool == "TaskUpdate" {
                let id = input["taskId"]?.string ?? input["task_id"]?.string ?? input["id"]?.string
                guard let id else { return [] }
                return [ev(.taskUpdate, [("id", .string(id)),
                                         ("status", .str(input["status"]?.string)),
                                         ("title", .str(input["subject"]?.string)),
                                         ("active", .str(input["activeForm"]?.string))])]
            }
            return []
        case "TaskCreated":
            guard let id = hook["task_id"]?.string else { return [] }
            return [ev(.taskUpdate, [("id", .string(id)), ("title", .str(hook["task_subject"]?.string)), ("status", .string("pending"))])]
        case "TaskCompleted":
            guard let id = hook["task_id"]?.string else { return [] }
            return [ev(.taskUpdate, [("id", .string(id)), ("title", .str(hook["task_subject"]?.string)), ("status", .string("completed"))])]
        case "Stop":
            let msg = hook["last_assistant_message"]?.string ?? ""
            return [ev(.turnDone, doneData(msg))]
        case "StopFailure":
            let msg = hook["last_assistant_message"]?.string ?? hook["error_details"]?.string ?? hook["error"]?.string ?? "API error"
            return [ev(.error, [("message", .string(msg.clipped(200))), ("code", .str(hook["error"]?.string))])]
        case "Notification":
            let type = hook["notification_type"]?.string ?? ""
            if ["idle_prompt", "auth_success", "elicitation_complete", "elicitation_response", "agent_completed"].contains(type) { return [] }
            if type == "permission_prompt" { return [] }
            return [ev(.attention, [("message", .str(hook["message"]?.string)), ("type", .string(type))])]
        case "PermissionRequest":
            let detail = ToolLabel.detail(tool: tool, input: input)
            return [ev(.permission, [("tool", .string(tool)), ("detail", .string(detail)),
                                     ("request", .string(UUID().uuidString))], reply: true)]
        default:
            return []
        }
    }

    static func doneData(_ message: String) -> [(String, JSON?)] {
        let commands = CommandExtractor.extract(from: message)
        return [("summary", .string(CommandExtractor.summary(of: message))),
                ("commands", commands.isEmpty ? nil : JSON.strings(commands))]
    }

    /// Claude Code status line payload: context, cost, model and plan limits.
    public static func claudeStatusline(_ s: JSON) -> Event? {
        guard let session = s["session_id"]?.string else { return nil }
        let cw = s["context_window"]
        var limits = [JSON]()
        if let rl = s["rate_limits"] {
            for (key, name) in [("five_hour", "5h"), ("seven_day", "7d"), ("spend_limit", "spend")] {
                if let w = rl[key], let pct = w["used_percentage"]?.double {
                    limits.append(.obj([("name", .string(name)), ("pct", .number(pct)), ("resets_at", .num(w["resets_at"]?.double))]))
                }
            }
        }
        let data = JSON.obj([
            ("context_pct", .num(cw?["used_percentage"]?.double)),
            ("context_window", .num(cw?["context_window_size"]?.double)),
            ("cost_usd", .num(s["cost"]?["total_cost_usd"]?.double)),
            ("model", .str(s["model"]?["display_name"]?.string)),
            ("limits", limits.isEmpty ? nil : .array(limits)),
        ])
        return Event(agent: "claude", kind: .usage, session: session, cwd: s["workspace"]?["current_dir"]?.string ?? s["cwd"]?.string, data: data)
    }

    // MARK: Gemini CLI

    public static func gemini(_ hook: JSON, transcriptReader: (String) -> JSON? = GeminiTranscript.usage(path:)) -> [Event] {
        let session = hook["session_id"]?.string ?? "gemini"
        let cwd = hook["cwd"]?.string
        func ev(_ kind: EventKind, _ data: [(String, JSON?)] = []) -> Event {
            Event(agent: "gemini", kind: kind, session: session, cwd: cwd, data: .obj(data))
        }
        switch hook["hook_event_name"]?.string ?? "" {
        case "SessionStart": return [ev(.sessionStart, [("source", .str(hook["source"]?.string))])]
        case "SessionEnd": return [ev(.sessionEnd, [("reason", .str(hook["reason"]?.string))])]
        case "BeforeAgent": return [ev(.turnStart, [("prompt", .str(hook["prompt"]?.string.map { $0.clipped(200) }))])]
        case "BeforeTool":
            let tool = hook["tool_name"]?.string ?? ""
            guard let label = ToolLabel.gemini(tool: tool, input: hook["tool_input"] ?? .object([])) else { return [] }
            return [ev(.activity, [("label", .string(label)), ("tool", .string(tool))])]
        case "AfterAgent":
            var out = [ev(.turnDone, doneData(hook["prompt_response"]?.string ?? ""))]
            if let path = hook["transcript_path"]?.string, let usage = transcriptReader(path) {
                out.insert(ev(.usage, usage.members?.map { ($0.key, $0.value) } ?? []), at: 0)
            }
            return out
        case "Notification":
            return [ev(.attention, [("message", .str(hook["message"]?.string)), ("type", .str(hook["notification_type"]?.string))])]
        default:
            return []
        }
    }

    // MARK: Codex CLI

    /// Codex `notify` passes one JSON argument, currently only `agent-turn-complete`.
    public static func codexNotify(_ payload: JSON) -> [Event] {
        guard payload["type"]?.string == "agent-turn-complete" else { return [] }
        let session = payload["thread-id"]?.string ?? payload["thread_id"]?.string ?? "codex"
        let msg = payload["last-assistant-message"]?.string ?? payload["last_assistant_message"]?.string ?? ""
        return [Event(agent: "codex", kind: .turnDone, session: session, cwd: payload["cwd"]?.string, data: .obj(doneData(msg)))]
    }
}

/// Short, human labels for the live activity line.
public enum ToolLabel {
    static func file(_ input: JSON, _ keys: [String]) -> String? {
        for k in keys { if let p = input[k]?.string, !p.isEmpty { return p.lastPathComponent } }
        return nil
    }

    static func cmd(_ s: String) -> String { s.firstLine.trimmingCharacters(in: .whitespaces).clipped(48) }

    public static func claude(tool: String, input: JSON) -> String? {
        switch tool {
        case "Bash": return input["command"]?.string.map { "Running \(cmd($0))" }
        case "Edit", "MultiEdit": return "Editing \(file(input, ["file_path"]) ?? "file")"
        case "Write": return "Writing \(file(input, ["file_path"]) ?? "file")"
        case "NotebookEdit": return "Editing \(file(input, ["notebook_path"]) ?? "notebook")"
        case "Read": return "Reading \(file(input, ["file_path"]) ?? "file")"
        case "Grep": return input["pattern"]?.string.map { "Searching “\($0.clipped(32))”" } ?? "Searching"
        case "Glob": return "Finding files"
        case "WebFetch": return "Fetching \(input["url"]?.string.flatMap { URL(string: $0)?.host } ?? "page")"
        case "WebSearch": return "Searching the web"
        case "Agent", "Task": return "Running subagent"
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet": return nil
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                if parts.count >= 3 { return "Using \(parts[1]) › \(parts[2...].joined(separator: "_"))" }
            }
            return tool.isEmpty ? nil : "Using \(tool)"
        }
    }

    public static func gemini(tool: String, input: JSON) -> String? {
        switch tool {
        case "run_shell_command": return input["command"]?.string.map { "Running \(cmd($0))" }
        case "replace", "edit": return "Editing \(file(input, ["file_path", "absolute_path"]) ?? "file")"
        case "write_file": return "Writing \(file(input, ["file_path", "absolute_path"]) ?? "file")"
        case "read_file": return "Reading \(file(input, ["absolute_path", "file_path"]) ?? "file")"
        case "read_many_files": return "Reading files"
        case "glob", "list_directory": return "Finding files"
        case "search_file_content", "grep", "grep_search": return input["pattern"]?.string.map { "Searching “\($0.clipped(32))”" } ?? "Searching"
        case "web_fetch": return "Fetching page"
        case "google_web_search": return "Searching the web"
        default: return tool.isEmpty ? nil : "Using \(tool)"
        }
    }

    public static func codex(name: String, arguments: JSON) -> String? {
        switch name {
        case "shell", "exec_command", "local_shell", "container.exec":
            if let a = arguments["command"]?.array?.compactMap(\.string), !a.isEmpty {
                let joined = (a.count >= 3 && ["bash", "zsh", "sh"].contains(a[0].lastPathComponent) && a[1].hasPrefix("-")) ? a[2...].joined(separator: " ") : a.joined(separator: " ")
                return "Running \(cmd(joined))"
            }
            if let s = arguments["command"]?.string ?? arguments["cmd"]?.string { return "Running \(cmd(s))" }
            return "Running command"
        case "apply_patch":
            if let text = arguments["input"]?.string ?? arguments.string,
               let r = text.range(of: #"\*\*\* (Update|Add) File: (.+)"#, options: .regularExpression) {
                let path = text[r].replacingOccurrences(of: #"\*\*\* (Update|Add) File: "#, with: "", options: .regularExpression)
                return "Editing \(path.lastPathComponent)"
            }
            return "Editing files"
        case "update_plan": return nil
        case "web_search": return "Searching the web"
        case "view_image": return "Viewing image"
        default: return name.isEmpty ? nil : "Using \(name)"
        }
    }

    /// Full text shown in the approval toast.
    public static func detail(tool: String, input: JSON) -> String {
        if let c = input["command"]?.string { return c.clipped(300) }
        if let p = input["file_path"]?.string { return "\(tool) \(p)" }
        if let u = input["url"]?.string { return "\(tool) \(u)" }
        return tool
    }
}

public enum GeminiTranscript {
    /// Context usage from the last model message in a Gemini session file.
    public static func usage(path: String) -> JSON? {
        guard let data = FileManager.default.contents(atPath: path), let root = JSON.parse(data),
              let messages = root["messages"]?.array else { return nil }
        guard let last = messages.last(where: { $0["tokens"]?["input"]?.double != nil }),
              let input = last["tokens"]?["input"]?.double else { return nil }
        let model = last["model"]?.string ?? ""
        let window = contextWindow(model: model)
        return .obj([
            ("context_pct", .number((input / window * 100).rounded())),
            ("context_window", .number(window)),
            ("model", .string(model)),
        ])
    }

    public static func contextWindow(model: String) -> Double { 1_048_576 }
}
