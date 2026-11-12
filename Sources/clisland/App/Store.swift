import AppKit
import CLIslandCore
import Foundation
import Observation

struct PermissionRequest: Equatable {
    var requestId: String
    var sessionKey: String
    var tool: String
    var detail: String
    var deadline: Date
    var createdAt: Date
}

enum Toast: Equatable, Identifiable {
    case done(String)
    case permission(PermissionRequest)
    case attention(String, String)
    case context(String)
    case limit(String, Limit)
    case stuck(String)
    case error(String, String)
    case run(String)

    var id: String {
        switch self {
        case .done(let s): return "done-\(s)"
        case .permission(let p): return "perm-\(p.requestId)"
        case .attention(let s, let m): return "att-\(s)-\(m.hashValue)"
        case .context(let s): return "ctx-\(s)"
        case .limit(let a, let l): return "lim-\(a)-\(l.name)"
        case .stuck(let s): return "stuck-\(s)"
        case .error(let s, _): return "err-\(s)"
        case .run(let s): return "run-\(s)"
        }
    }

    var sessionKey: String? {
        switch self {
        case .done(let s), .attention(let s, _), .context(let s), .stuck(let s), .error(let s, _), .run(let s): return s
        case .permission(let p): return p.sessionKey
        case .limit: return nil
        }
    }
}

@Observable
final class Store {
    var sessions: [Session] = []
    var toast: Toast?
    var queue: [Toast] = []
    var hovering = false
    var panelOpen = false
    var shakeTick = 0
    var config = Config.load()

    @ObservationIgnored var replyHandler: ((String, JSON) -> Void)?
    @ObservationIgnored private var toastTimer: Timer?
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var aliases: [String: String] = [:]
    @ObservationIgnored private var warnedLimits: Set<String> = []

    init() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.tick() }
    }

    // MARK: Lookup

    func index(_ key: String) -> Int? { sessions.firstIndex { $0.id == key } }
    func session(_ key: String?) -> Session? { key.flatMap { k in sessions.first { $0.id == k } } }

    var working: [Session] { sessions.filter { $0.status == .working } }

    /// Most relevant session for the compact notch: working first, then most recent.
    var focus: Session? {
        working.max(by: { $0.lastEventAt < $1.lastEventAt }) ?? sessions.max(by: { $0.lastEventAt < $1.lastEventAt })
    }

    var allLimits: [(agent: String, limit: Limit)] {
        var seen = Set<String>()
        var out: [(String, Limit)] = []
        for s in sessions.sorted(by: { $0.lastEventAt > $1.lastEventAt }) {
            for l in s.limits where !seen.contains("\(s.agent)-\(l.name)") {
                seen.insert("\(s.agent)-\(l.name)")
                out.append((s.agent, l))
            }
        }
        return out
    }

    private func resolveKey(_ e: Event) -> String {
        let key = "\(e.agent):\(e.session)"
        if let alias = aliases[key] { return alias }
        if index(key) != nil { return key }
        if e.agent == "codex", let cwd = e.cwd,
           let match = sessions.first(where: { $0.agent == "codex" && $0.cwd == cwd && Date().timeIntervalSince($0.lastEventAt) < 600 }) {
            aliases[key] = match.id
            return match.id
        }
        return key
    }

    // MARK: Events

    func handle(_ e: Event, replay: Bool = false) {
        let key = resolveKey(e)
        if e.kind == .sessionEnd {
            remove(key)
            return
        }
        if e.kind == .demo, e.data["cmd"]?.string == "clear" {
            for s in sessions where s.isDemo { remove(s.id) }
            return
        }

        if [.activity, .turnStart, .turnDone, .error].contains(e.kind) { cancelPermissions(for: key, before: e.time.addingTimeInterval(-1)) }

        var s = session(key) ?? Session(id: key, agent: e.agent, sessionId: e.session)
        let isNew = index(key) == nil
        if let cwd = e.cwd, !cwd.isEmpty, s.cwd == nil || e.agent != "run" { s.cwd = cwd }
        if let t = e.term, t.tty != nil || s.term == nil { s.term = t }
        if e.data["demo"]?.bool == true { s.isDemo = true }
        if !replay { s.lastEventAt = e.time }
        if e.kind != .usage { s.stuckNotified = false }

        var newToast: Toast?
        switch e.kind {
        case .sessionStart:
            break
        case .turnStart:
            s.status = .working
            s.turnStartedAt = e.time
            s.activity = nil
            s.unread = false
            s.errorMessage = nil
        case .activity:
            s.status = .working
            if s.turnStartedAt == nil { s.turnStartedAt = e.time }
            s.activity = e.data["label"]?.string
        case .tasks:
            s.tasks = (e.data["items"]?.array ?? []).map {
                TaskItem(id: $0["id"]?.string ?? UUID().uuidString, title: $0["title"]?.string ?? "Task",
                         status: $0["status"]?.string ?? "pending", active: $0["active"]?.string)
            }
        case .taskUpdate:
            guard let id = e.data["id"]?.string else { break }
            if let i = s.tasks.firstIndex(where: { $0.id == id }) {
                if let st = e.data["status"]?.string {
                    if st == "deleted" { s.tasks.remove(at: i) } else { s.tasks[i].status = st }
                }
                if i < s.tasks.count, let t = e.data["title"]?.string { s.tasks[i].title = t }
                if i < s.tasks.count, let a = e.data["active"]?.string { s.tasks[i].active = a }
            } else if e.data["status"]?.string != "deleted" {
                s.tasks.append(TaskItem(id: id, title: e.data["title"]?.string ?? "Task #\(id)",
                                        status: e.data["status"]?.string ?? "pending", active: e.data["active"]?.string))
            }
            if s.tasks.count > 0, s.tasks.allSatisfy(\.done), s.status != .working { s.tasks = [] }
        case .turnDone:
            if let last = s.lastDoneAt, e.time.timeIntervalSince(last) < 15, s.status != .working {
                if let cmds = e.data["commands"]?.array?.compactMap(\.string), s.commands.isEmpty { s.commands = cmds }
                break
            }
            if e.data["aborted"]?.bool == true {
                s.status = .idle
                s.activity = nil
                break
            }
            s.status = .done
            s.unread = true
            s.activity = nil
            s.lastDoneAt = e.time
            s.lastDuration = s.turnStartedAt.map { e.time.timeIntervalSince($0) }
            s.turnStartedAt = nil
            s.summary = e.data["summary"]?.string
            s.commands = e.data["commands"]?.array?.compactMap(\.string) ?? []
            if s.tasks.allSatisfy(\.done) { s.tasks = [] }
            newToast = .done(key)
        case .attention:
            s.status = .attention
            newToast = .attention(key, e.data["message"]?.string ?? "Waiting for your input")
        case .permission:
            s.status = .attention
            if let req = e.data["request"]?.string {
                let p = PermissionRequest(requestId: req, sessionKey: key, tool: e.data["tool"]?.string ?? "Tool",
                                          detail: e.data["detail"]?.string ?? "", deadline: Date().addingTimeInterval(config.approvalTimeout), createdAt: e.time)
                newToast = .permission(p)
            }
        case .usage:
            if let pct = e.data["context_pct"]?.double { s.contextPct = pct }
            if let c = e.data["cost_usd"]?.double { s.costUSD = c }
            if let m = e.data["model"]?.string { s.model = m }
            if let ls = e.data["limits"]?.array {
                s.limits = ls.compactMap { l in
                    guard let n = l["name"]?.string, let p = l["pct"]?.double else { return nil }
                    return Limit(name: n, pct: p, resetsAt: l["resets_at"]?.double.map { Date(timeIntervalSince1970: $0) })
                }
            }
            if let pct = s.contextPct {
                if pct >= config.contextWarnPct, !s.contextWarned {
                    s.contextWarned = true
                    if !replay { newToast = .context(key) }
                } else if pct < config.contextWarnPct - 10 {
                    s.contextWarned = false
                }
            }
            for l in s.limits where l.pct >= config.limitWarnPct {
                let mark = "\(s.agent)-\(l.name)-\(Int(l.resetsAt?.timeIntervalSince1970 ?? 0) / 600)"
                if !warnedLimits.contains(mark) {
                    warnedLimits.insert(mark)
                    if !replay && newToast == nil { newToast = .limit(s.agent, l) }
                }
            }
        case .error:
            s.status = .error
            s.activity = nil
            s.errorMessage = e.data["message"]?.string ?? "Error"
            newToast = .error(key, s.errorMessage!)
        case .runStart:
            s.status = .working
            s.runCommand = e.data["command"]?.string
            s.turnStartedAt = e.time
            s.exitCode = nil
            s.tail = []
        case .runDone:
            s.exitCode = e.data["exit_code"]?.int
            s.lastDuration = e.data["duration"]?.double
            s.tail = e.data["tail"]?.array?.compactMap(\.string) ?? []
            s.status = s.exitCode == 0 ? .done : .error
            s.unread = true
            s.lastDoneAt = e.time
            newToast = .run(key)
        case .status, .demo, .sessionEnd:
            break
        }

        if isNew { sessions.append(s) } else if let i = index(key) { sessions[i] = s }
        if let newToast, !replay { enqueue(newToast) }
    }

    func remove(_ key: String) {
        sessions.removeAll { $0.id == key }
        queue.removeAll { $0.sessionKey == key }
        cancelPermissions(for: key)
        if toast?.sessionKey == key { advance() }
    }

    // MARK: Toast queue

    func enqueue(_ t: Toast) {
        playSound(for: t)
        if case .error = t { shakeTick += 1 }
        queue.removeAll { $0.id == t.id }
        if toast == nil {
            show(t)
        } else if case .permission = t {
            if let current = toast, !isPermission(current) { queue.insert(current, at: 0); show(t) } else { queue.insert(t, at: 0) }
        } else if toast?.id == t.id {
            show(t)
        } else {
            queue.append(t)
        }
    }

    private func isPermission(_ t: Toast) -> Bool { if case .permission = t { return true }; return false }

    private func show(_ t: Toast) {
        toast = t
        panelOpen = false
        scheduleHide()
    }

    func scheduleHide() {
        toastTimer?.invalidate()
        guard let t = toast, !hovering else { return }
        let secs: TimeInterval
        switch t {
        case .permission(let p): secs = max(0.5, p.deadline.timeIntervalSinceNow)
        case .done(let k): secs = (session(k)?.commands.isEmpty ?? true) ? config.doneToastSeconds : 20
        case .run(let k): secs = session(k)?.exitCode == 0 ? config.doneToastSeconds : 12
        case .context, .limit: secs = 7
        default: secs = 9
        }
        toastTimer = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in self?.expire() }
    }

    private func expire() {
        if case .permission(let p) = toast { answer(p.requestId, "ask") ; return }
        advance()
    }

    func advance() {
        toastTimer?.invalidate()
        if !queue.isEmpty {
            show(queue.removeFirst())
        } else {
            toast = nil
            panelOpen = hovering
        }
    }

    func dismissToast() { advance() }

    func setHovering(_ h: Bool) {
        guard h != hovering else { return }
        hovering = h
        if h {
            toastTimer?.invalidate()
            if toast == nil { panelOpen = true }
        } else {
            panelOpen = false
            if toast != nil { toastTimer?.invalidate(); toastTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in self?.expire() } }
        }
    }

    func peek(seconds: Double = 6) {
        guard toast == nil, !sessions.isEmpty else { return }
        panelOpen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, !self.hovering else { return }
            self.panelOpen = false
        }
    }

    func showCommands(_ key: String) {
        guard session(key) != nil else { return }
        queue.removeAll { $0.id == Toast.done(key).id }
        toast = .done(key)
        panelOpen = false
    }

    // MARK: Permissions

    func answer(_ requestId: String, _ decision: String) {
        replyHandler?(requestId, .obj([("decision", .string(decision))]))
        if case .permission(let p) = toast, p.requestId == requestId {
            if let i = index(p.sessionKey) { sessions[i].status = decision == "deny" ? .idle : .working }
            advance()
        } else {
            queue.removeAll { if case .permission(let p) = $0 { return p.requestId == requestId }; return false }
        }
    }

    func permissionAbandoned(_ requestId: String) {
        if case .permission(let p) = toast, p.requestId == requestId {
            if let i = index(p.sessionKey), sessions[i].status == .attention { sessions[i].status = .working }
            advance()
        }
        queue.removeAll { if case .permission(let p) = $0 { return p.requestId == requestId }; return false }
    }

    private func cancelPermissions(for key: String, before: Date = .distantFuture) {
        var ids: [String] = []
        if case .permission(let p) = toast, p.sessionKey == key, p.createdAt < before { ids.append(p.requestId) }
        for case .permission(let p) in queue where p.sessionKey == key && p.createdAt < before { ids.append(p.requestId) }
        for id in ids { answer(id, "ask") }
    }

    // MARK: Actions

    func open(_ key: String) {
        guard let i = index(key) else { return }
        sessions[i].unread = false
        if sessions[i].status == .done || sessions[i].status == .error { sessions[i].status = .idle }
        let s = sessions[i]
        if toast?.sessionKey == key { advance() }
        Focus.focus(s)
    }

    func dismissCommands(_ key: String) {
        if let i = index(key) { sessions[i].commands = [] }
        if toast?.sessionKey == key { advance() }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Timers

    private func tick() {
        let now = Date()
        for i in sessions.indices {
            let s = sessions[i]
            if s.status == .working, !s.stuckNotified, now.timeIntervalSince(s.lastEventAt) > config.stuckMinutes * 60 {
                sessions[i].stuckNotified = true
                enqueue(.stuck(s.id))
            }
        }
        let dead = sessions.filter { s in
            let idle = now.timeIntervalSince(s.lastEventAt)
            if let pid = s.term?.agentPid, s.agent != "run", !ProcInfo.isAlive(pid) { return true }
            if s.agent == "run" { return s.status != .working && idle > 600 }
            if s.isDemo { return idle > 120 }
            if s.term?.agentPid == nil { return idle > (s.status == .working ? 3 * 3600 : 1800) }
            return idle > 6 * 3600
        }
        for s in dead { remove(s.id) }
    }

    private func playSound(for t: Toast) {
        guard config.sounds else { return }
        let name: String
        switch t {
        case .done: name = "Glass"
        case .permission, .attention: name = "Submarine"
        case .error: name = "Basso"
        case .run(let k): name = session(k)?.exitCode == 0 ? "Glass" : "Basso"
        case .context, .limit, .stuck: name = "Tink"
        }
        NSSound(named: NSSound.Name(name))?.play()
    }

    // MARK: Status query

    func statusJSON() -> JSON {
        .obj([("sessions", .array(sessions.map { s in
            .obj([("id", .string(s.id)), ("agent", .string(s.agent)), ("project", .string(s.project)),
                  ("status", .string(s.status.rawValue)), ("activity", .str(s.liveLine)),
                  ("context_pct", .num(s.contextPct)), ("cost_usd", .num(s.costUSD)),
                  ("tasks", s.taskProgress.map { .string("\($0.done)/\($0.total)") }),
                  ("terminal", .str(s.term?.label))])
        }))])
    }
}
