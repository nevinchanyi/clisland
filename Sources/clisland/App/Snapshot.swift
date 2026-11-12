import AppKit
import CLIslandCore
import SwiftUI

/// `clisland snapshot <dir>`: renders notch states to transparent PNGs for docs.
enum Snapshot {
    @MainActor
    static func run(_ args: [String]) -> Int32 {
        let dir = URL(fileURLWithPath: args.first ?? "docs/images")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared

        let geo = NotchGeometry()
        geo.hasNotch = true
        geo.notchWidth = 185
        geo.notchHeight = 32

        func fresh() -> Store {
            let s = Store()
            s.config.sounds = false
            seed(s)
            s.toast = nil
            s.queue = []
            s.panelOpen = false
            return s
        }

        let shots: [(String, (Store) -> Void)] = [
            ("compact", { s in
                if let i = s.index("codex:web") { s.sessions[i].status = .idle; s.sessions[i].unread = false }
                if let i = s.index("gemini:infra") { s.sessions[i].status = .idle }
                if let i = s.index("run:build") { s.sessions.remove(at: i) }
            }),
            ("permission", { s in
                s.toast = .permission(PermissionRequest(requestId: "r", sessionKey: "claude:api", tool: "Bash",
                                                        detail: "pnpm prisma migrate reset --force",
                                                        deadline: Date().addingTimeInterval(24), createdAt: Date()))
            }),
            ("commands", { s in
                if let i = s.index("claude:api") {
                    s.sessions[i].status = .done
                    s.sessions[i].activity = nil
                    s.sessions[i].summary = "Added token-bucket rate limiting to /v1/orders. 4 tests pass. Run the migration to finish:"
                    s.sessions[i].commands = ["cd ~/code/api-server", "pnpm add @upstash/ratelimit",
                                              "pnpm prisma migrate dev --name add_rate_limits", "pnpm test orders"]
                    s.sessions[i].lastDuration = 192
                }
                s.toast = .done("claude:api")
            }),
            ("panel", { s in s.panelOpen = true }),
            ("run-failed", { s in s.toast = .run("run:build") }),
            ("context", { s in s.toast = .context("gemini:infra") }),
        ]

        for (name, configure) in shots {
            let store = fresh()
            configure(store)
            let view = NotchRoot(store: store, geo: geo) { _ in }
                .frame(width: NotchController.size.width, height: NotchController.size.height)
                .environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: view)
            r.scale = 2
            guard let cg = r.cgImage, let cropped = cropToContent(cg) else { continue }
            let rep = NSBitmapImageRep(cgImage: cropped)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent("\(name).png"))
                print("wrote \(dir.appendingPathComponent("\(name).png").path)")
            }
        }
        return 0
    }

    static func seed(_ s: Store) {
        let now = Date()
        func ev(_ agent: String, _ id: String, _ cwd: String, _ tty: String, _ prog: String, _ kind: EventKind, _ data: [(String, JSON?)]) {
            s.handle(Event(agent: agent, kind: kind, session: id, cwd: "/Users/dev/code/\(cwd)",
                           term: TermInfo(tty: tty, program: prog), data: .obj(data), time: now))
        }
        let reset = now.addingTimeInterval(4300).timeIntervalSince1970
        ev("claude", "api", "api-server", "ttys101", "ghostty", .turnStart, [])
        ev("claude", "api", "api-server", "ttys101", "ghostty", .usage, [("context_pct", .number(47)), ("cost_usd", .number(1.12)),
            ("limits", .array([.obj([("name", .string("5h")), ("pct", .number(46)), ("resets_at", .number(reset))])]))])
        ev("claude", "api", "api-server", "ttys101", "ghostty", .tasks, [("items", .array([
            .obj([("id", .string("1")), ("title", .string("Read orders route")), ("status", .string("completed"))]),
            .obj([("id", .string("2")), ("title", .string("Add rate limit middleware")), ("status", .string("completed"))]),
            .obj([("id", .string("3")), ("title", .string("Write tests")), ("status", .string("in_progress"))]),
            .obj([("id", .string("4")), ("title", .string("Update docs")), ("status", .string("pending"))]),
        ]))])
        ev("claude", "api", "api-server", "ttys101", "ghostty", .activity, [("label", .string("Running pnpm test orders"))])
        ev("codex", "web", "web-app", "ttys102", "iTerm.app", .usage, [("context_pct", .number(23)),
            ("limits", .array([.obj([("name", .string("5h")), ("pct", .number(12)), ("resets_at", .number(reset + 3000))])]))])
        ev("codex", "web", "web-app", "ttys102", "iTerm.app", .turnDone, [("summary", .string("Migrated the settings page to the new form components."))])
        ev("gemini", "infra", "infra", "ttys103", "Apple_Terminal", .turnStart, [])
        ev("gemini", "infra", "infra", "ttys103", "Apple_Terminal", .usage, [("context_pct", .number(91))])
        ev("gemini", "infra", "infra", "ttys103", "Apple_Terminal", .activity, [("label", .string("Reading files"))])
        ev("run", "build", "web-app", "ttys104", "ghostty", .runStart, [("command", .string("pnpm build"))])
        ev("run", "build", "web-app", "ttys104", "ghostty", .runDone, [("command", .string("pnpm build")), ("exit_code", .number(1)), ("duration", .number(47)),
            ("tail", JSON.strings(["src/pages/settings.tsx:42:7", "Type error: Property 'onSave' is missing", "  in type '{ form: Form }'", "Build failed in 47.2s"]))])
        if let i = s.index("claude:api") { s.sessions[i].turnStartedAt = now.addingTimeInterval(-134) }
    }

    static func cropToContent(_ img: CGImage) -> CGImage? {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var minX = w, minY = h, maxX = 0, maxY = 0
        for y in 0..<h {
            for x in 0..<w where data[(y * w + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        let pad = 24
        let rect = CGRect(x: max(0, minX - pad), y: max(0, minY - pad), width: min(w, maxX + pad) - max(0, minX - pad), height: min(h, maxY + pad) - max(0, minY - pad))
        return ctx.makeImage()?.cropping(to: rect)
    }
}
