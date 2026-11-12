import Foundation
import Testing
@testable import CLIslandCore

@Suite struct JSONTests {
    @Test func roundTripKeepsKeyOrder() {
        let text = #"{"zeta":1,"alpha":{"b":[true,null,"x\"y"],"a":2.5},"emoji":"✻ é é"}"#
        let j = JSON.parse(text)!
        #expect(j.serialized() == #"{"zeta":1,"alpha":{"b":[true,null,"x\"y"],"a":2.5},"emoji":"✻ é é"}"#)
        #expect(j["alpha"]?["a"]?.double == 2.5)
    }

    @Test func rejectsGarbage() {
        #expect(JSON.parse("{\"a\":}") == nil)
        #expect(JSON.parse("[1,2") == nil)
    }

    @Test func subscriptSetter() {
        var j = JSON.parse(#"{"a":1}"#)!
        j["b"] = .string("x")
        j["a"] = nil
        #expect(j.serialized() == #"{"b":"x"}"#)
    }
}

@Suite struct CommandTests {
    @Test func extractsBashBlocks() {
        let md = """
        Done. Run these:

        ```bash
        # install
        cd ~/api-server
        pnpm add @upstash/ratelimit
        docker run --rm \\
          -p 6379:6379 redis
        ```

        ```ts
        const x = 1
        ```
        """
        #expect(CommandExtractor.extract(from: md) == ["cd ~/api-server", "pnpm add @upstash/ratelimit", "docker run --rm -p 6379:6379 redis"])
    }

    @Test func consoleBlocksKeepOnlyPromptLines() {
        let md = "```console\n$ npm test\n> 4 passing\n$ npm run build\nok\n```"
        #expect(CommandExtractor.extract(from: md) == ["npm test", "npm run build"])
    }

    @Test func heredocStaysOneCommand() {
        let md = "```sh\ncat > .env <<EOF\nA=1\nB=2\nEOF\necho done\n```"
        #expect(CommandExtractor.extract(from: md) == ["cat > .env <<EOF\nA=1\nB=2\nEOF", "echo done"])
    }

    @Test func summarySkipsCodeAndMarkdown() {
        let md = "## Summary\n\n**Added** rate limiting to [orders](http://x).\n```bash\nls\n```"
        #expect(CommandExtractor.summary(of: md) == "Summary")
        #expect(CommandExtractor.summary(of: "```bash\nls\n```\nAdded `x` to [y](z).") == "Added x to y.")
    }
}

@Suite struct NormalizerTests {
    @Test func claudePreToolUseBecomesActivity() {
        let j = JSON.parse(#"{"session_id":"s1","cwd":"/p/api","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/p/api/src/orders.ts"}}"#)!
        let e = Normalizer.claude(j)
        #expect(e.count == 1)
        #expect(e[0].kind == .activity)
        #expect(e[0].data["label"]?.string == "Editing orders.ts")
        #expect(e[0].session == "s1")
    }

    @Test func claudeStopCarriesSummaryAndCommands() {
        let msg = "Fixed it.\n\n```bash\npnpm test\n```"
        let j = JSON.obj([("session_id", .string("s1")), ("hook_event_name", .string("Stop")), ("last_assistant_message", .string(msg))])
        let e = Normalizer.claude(j)[0]
        #expect(e.kind == .turnDone)
        #expect(e.data["summary"]?.string == "Fixed it.")
        #expect(e.data["commands"]?.array?.compactMap(\.string) == ["pnpm test"])
    }

    @Test func claudeTodoWriteBecomesTasks() {
        let j = JSON.parse(#"{"session_id":"s","hook_event_name":"PostToolUse","tool_name":"TodoWrite","tool_input":{"todos":[{"content":"A","status":"completed","activeForm":"Doing A"},{"content":"B","status":"in_progress","activeForm":"Doing B"}]}}"#)!
        let e = Normalizer.claude(j)[0]
        #expect(e.kind == .tasks)
        #expect(e.data["items"]?.array?.count == 2)
    }

    @Test func claudePermissionWantsReply() {
        let j = JSON.parse(#"{"session_id":"s","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf dist"}}"#)!
        let e = Normalizer.claude(j)[0]
        #expect(e.kind == .permission)
        #expect(e.wantsReply)
        #expect(e.data["detail"]?.string == "rm -rf dist")
    }

    @Test func claudeStatuslineUsage() {
        let j = JSON.parse(#"{"session_id":"s","model":{"display_name":"Opus"},"cost":{"total_cost_usd":0.42},"context_window":{"used_percentage":23,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":41.5,"resets_at":1738425600}}}"#)!
        let e = Normalizer.claudeStatusline(j)!
        #expect(e.kind == .usage)
        #expect(e.data["context_pct"]?.double == 23)
        #expect(e.data["cost_usd"]?.double == 0.42)
        #expect(e.data["limits"]?[0]?["name"]?.string == "5h")
    }

    @Test func geminiAfterAgentReadsTranscript() {
        let j = JSON.parse(#"{"session_id":"g","cwd":"/p","hook_event_name":"AfterAgent","prompt_response":"All good.","transcript_path":"/t"}"#)!
        let e = Normalizer.gemini(j) { _ in .obj([("context_pct", .number(12))]) }
        #expect(e.map(\.kind) == [.usage, .turnDone])
        #expect(e[0].data["context_pct"]?.double == 12)
    }

    @Test func codexNotify() {
        let j = JSON.parse(#"{"type":"agent-turn-complete","thread-id":"t1","cwd":"/w","last-assistant-message":"Done"}"#)!
        let e = Normalizer.codexNotify(j)
        #expect(e.first?.kind == .turnDone)
        #expect(e.first?.session == "t1")
    }
}

@Suite struct CodexRolloutTests {
    @Test func parsesRolloutLines() {
        var r = CodexRollout(fileName: "rollout-2026-11-12T10-00-00-0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b.jsonl")
        #expect(r.session == "0199a1b2-c3d4-7e5f-8a9b-0c1d2e3f4a5b")
        _ = r.ingest(line: #"{"type":"session_meta","payload":{"id":"abc","cwd":"/w/web"}}"#)
        #expect(r.session == "abc")
        let shell = r.ingest(line: #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"pnpm test\"]}"}}"#)
        #expect(shell.first?.data["label"]?.string == "Running pnpm test")
        let plan = r.ingest(line: #"{"type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"step\":\"A\",\"status\":\"completed\"},{\"step\":\"B\",\"status\":\"in_progress\"}]}"}}"#)
        #expect(plan.first?.kind == .tasks)
        let tokens = r.ingest(line: #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":54400},"model_context_window":272000},"rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_in_seconds":600},"secondary":{"used_percent":3.0,"window_minutes":10080}}}}"#)
        #expect(tokens.first?.data["context_pct"]?.double == 20)
        #expect(tokens.first?.data["limits"]?.array?.compactMap { $0["name"]?.string } == ["5h", "7d"])
        let done = r.ingest(line: #"{"type":"event_msg","payload":{"type":"task_complete","last_agent_message":"Shipped."}}"#)
        #expect(done.first?.kind == .turnDone)
        #expect(done.first?.cwd == "/w/web")
    }
}

@Suite struct InstallerTests {
    let settings = JSON.parse(#"""
    {"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]},"statusLine":{"type":"command","command":"bash ~/sl.sh","padding":0}}
    """#)!

    @Test func claudePatchIsIdempotentAndReversible() {
        var config = Config()
        let once = Installer.patchClaude(settings, bin: "/opt/homebrew/bin/clisland", config: &config)
        let twice = Installer.patchClaude(once, bin: "/opt/homebrew/bin/clisland", config: &config)
        #expect(once == twice)
        #expect(config.statuslineOriginal == "bash ~/sl.sh")
        #expect(once["hooks"]?["Stop"]?.array?.count == 2)
        #expect(once["statusLine"]?["command"]?.string == "/opt/homebrew/bin/clisland statusline")
        #expect(once["statusLine"]?["padding"]?.double == 0)
        #expect(once["hooks"]?["PermissionRequest"]?[0]?["hooks"]?[0]?["async"] == nil)
        #expect(once["hooks"]?["PreToolUse"]?[0]?["hooks"]?[0]?["async"]?.bool == true)
        let restored = Installer.unpatchClaude(twice, config: config)
        #expect(restored == settings)
    }

    @Test func geminiPatchRoundTrip() {
        let base = JSON.parse(#"{"ui":{"theme":"Default"}}"#)!
        let patched = Installer.patchGemini(base, bin: "/usr/local/bin/clisland")
        #expect(patched["hooks"]?["AfterAgent"]?[0]?["hooks"]?[0]?["timeout"]?.double == 5000)
        #expect(Installer.unpatchGemini(patched) == base)
    }

    @Test func codexNotifyPatchKeepsOriginal() {
        let toml = "model = \"gpt-5\"\nnotify = [\"terminal-notifier\", \"-title\", \"Codex\"]\n\n[tui]\nnotifications = true\n"
        let (patched, original) = Installer.patchCodex(toml, bin: "/opt/homebrew/bin/clisland")
        #expect(original == ["terminal-notifier", "-title", "Codex"])
        #expect(patched.contains(#"notify = ["/opt/homebrew/bin/clisland", "emit", "--agent", "codex"]"#))
        #expect(patched.contains("[tui]"))
        let back = Installer.unpatchCodex(patched, original: original)
        #expect(back == toml.replacingOccurrences(of: #"["terminal-notifier", "-title", "Codex"]"#, with: #"["terminal-notifier", "-title", "Codex"]"#))
    }

    @Test func codexNotifyInsertedAtTopWhenMissing() {
        let toml = "[profiles.fast]\nmodel = \"o4\"\n"
        let (patched, original) = Installer.patchCodex(toml, bin: "/b/clisland")
        #expect(original == nil)
        #expect(patched.hasPrefix("notify = [\"/b/clisland\""))
        #expect(Installer.unpatchCodex(patched, original: nil) == toml)
    }

    @Test func shellQuote() {
        #expect(Installer.shellQuote("/opt/bin/clisland") == "/opt/bin/clisland")
        #expect(Installer.shellQuote("/Users/a b/clisland") == "'/Users/a b/clisland'")
    }
}

@Suite struct EventTests {
    @Test func eventLineRoundTrip() {
        let e = Event(agent: "claude", kind: .activity, session: "s", cwd: "/p", term: TermInfo(tty: "ttys001", program: "iTerm.app", agentPid: 42),
                      data: .obj([("label", .string("Running ls"))]))
        let back = Event(json: JSON.parse(e.line.dropLast())!)!
        #expect(back.kind == .activity)
        #expect(back.term?.tty == "ttys001")
        #expect(back.term?.agentPid == 42)
        #expect(back.term?.label == "iTerm2 · ttys001")
    }
}
