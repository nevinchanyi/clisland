import CLIslandCore
import Darwin
import Foundation

/// `clisland demo`: plays a scripted set of fake sessions through the real socket.
enum Demo {
    static func run(_ args: [String]) -> Int32 {
        let fast = args.contains("--fast")
        guard Setup.query("ping") != nil else {
            print("CLIsland is not running. Start it with: clisland start")
            return 1
        }
        let home = Paths.home.path
        let claude = ("claude", "demo-claude", "\(home)/code/api-server", TermInfo(tty: "ttys101", program: "ghostty"))
        let codex = ("codex", "demo-codex", "\(home)/code/web-app", TermInfo(tty: "ttys102", program: "iTerm.app"))
        let gemini = ("gemini", "demo-gemini", "\(home)/code/infra", TermInfo(tty: "ttys103", program: "Apple_Terminal"))

        func send(_ s: (String, String, String, TermInfo), _ kind: EventKind, _ data: [(String, JSON?)] = []) {
            let e = Event(agent: s.0, kind: kind, session: s.1, cwd: s.2, term: s.3, data: .obj(data + [("demo", .bool(true))]))
            SocketClient.send(e.line, timeout: 1)
        }
        func wait(_ s: Double) { usleep(useconds_t((fast ? s / 3 : s) * 1_000_000)) }
        func task(_ id: String, _ title: String, _ status: String) -> JSON {
            .obj([("id", .string(id)), ("title", .string(title)), ("status", .string(status))])
        }

        print("Playing demo (about 60s). Hover the notch to see all sessions.")
        let fiveHour = Date().addingTimeInterval(4300).timeIntervalSince1970
        send(claude, .sessionStart)
        send(claude, .usage, [("context_pct", .number(41)), ("cost_usd", .number(0.84)),
                              ("limits", .array([.obj([("name", .string("5h")), ("pct", .number(46)), ("resets_at", .number(fiveHour))])]))])
        send(codex, .sessionStart)
        send(codex, .usage, [("context_pct", .number(23))])
        send(gemini, .sessionStart)
        send(gemini, .usage, [("context_pct", .number(79))])
        wait(1)

        send(claude, .turnStart, [("prompt", .string("add rate limiting to /v1/orders"))])
        send(claude, .tasks, [("items", .array([task("1", "Read orders route", "completed"), task("2", "Add rate limit middleware", "in_progress"),
                                                task("3", "Write tests", "pending"), task("4", "Update docs", "pending")]))])
        for label in ["Reading orders.ts", "Editing rateLimit.ts", "Running pnpm test orders"] {
            send(claude, .activity, [("label", .string(label))])
            wait(2.5)
        }
        send(claude, .tasks, [("items", .array([task("1", "Read orders route", "completed"), task("2", "Add rate limit middleware", "completed"),
                                                task("3", "Write tests", "completed"), task("4", "Update docs", "in_progress")]))])
        send(claude, .permission, [("tool", .string("Bash")), ("detail", .string("pnpm prisma migrate reset --force")),
                                   ("request", .string("demo-\(UUID().uuidString)"))])
        wait(6)
        send(claude, .activity, [("label", .string("Editing README.md"))])
        wait(2)
        send(claude, .usage, [("context_pct", .number(47)), ("cost_usd", .number(1.12))])
        send(claude, .turnDone, [("summary", .string("Added token-bucket rate limiting to /v1/orders. 4 tests pass. Run the migration to finish:")),
                                 ("commands", JSON.strings(["cd ~/code/api-server", "pnpm add @upstash/ratelimit",
                                                            "pnpm prisma migrate dev --name add_rate_limits", "pnpm test orders"]))])
        wait(9)

        send(codex, .turnStart)
        send(codex, .activity, [("label", .string("Editing SettingsForm.tsx"))])
        wait(3)
        send(gemini, .turnStart)
        send(gemini, .activity, [("label", .string("Reading files"))])
        send(gemini, .usage, [("context_pct", .number(91))])
        wait(5)
        send(codex, .turnDone, [("summary", .string("Migrated the settings page to the new form components."))])
        wait(6)
        send(gemini, .error, [("message", .string("Quota exceeded for gemini-2.5-pro. Retry after 30s."))])
        wait(6)

        let runTerm = TermInfo(tty: "ttys104", program: "ghostty")
        let runE = ("run", "demo-run", "\(home)/code/web-app", runTerm)
        send(runE, .runStart, [("command", .string("pnpm build"))])
        wait(4)
        send(runE, .runDone, [("command", .string("pnpm build")), ("exit_code", .number(1)), ("duration", .number(47)),
                              ("tail", JSON.strings(["src/pages/settings.tsx:42:7", "Type error: Property 'onSave' is missing", "  in type '{ form: Form }'", "Build failed in 47.2s"]))])
        wait(8)
        print("Demo sessions clear themselves in 2 minutes. Run `clisland demo --clear` to remove them now.")
        if args.contains("--clear-after") { clear() }
        return 0
    }

    static func clear() {
        SocketClient.send(Event(agent: "demo", kind: .demo, session: "demo", data: .obj([("cmd", .string("clear"))])).line, timeout: 1)
    }
}
