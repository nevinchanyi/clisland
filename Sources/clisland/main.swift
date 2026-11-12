import CLIslandCore
import Darwin
import Foundation

let version = "0.1.1"

signal(SIGPIPE, SIG_IGN)
let args = Array(CommandLine.arguments.dropFirst())
let rest = Array(args.dropFirst())

func help() {
    print("""
    CLIsland \(version): your coding agents in the MacBook notch.

    Usage:
      clisland setup [--only claude,codex,gemini] [--no-statusline] [--no-launch] [--dry-run]
      clisland uninstall [--purge]
      clisland start | stop | status | doctor | peek
      clisland run -- <command>      notify when any long command finishes
      clisland demo [--fast]         play fake sessions to preview the UI
      clisland app                   run the notch app in the foreground

    Hook entry points (added by setup):
      clisland emit --agent claude|codex|gemini
      clisland statusline
    """)
}

switch args.first ?? "help" {
case "app": AppMain.run()
case "emit": exit(Emit.run(rest))
case "statusline": exit(Statusline.run())
case "run": exit(Runner.run(rest))
case "setup", "install": exit(Setup.install(rest))
case "uninstall": exit(Setup.uninstall(rest))
case "start": exit(Setup.start())
case "stop": exit(Setup.stop())
case "status": exit(Setup.status())
case "doctor": exit(Setup.doctor())
case "snapshot": exit(MainActor.assumeIsolated { Snapshot.run(rest) })
case "peek": exit(Setup.query("peek") == nil ? 1 : 0)
case "demo":
    if rest.contains("--clear") { Demo.clear(); exit(0) }
    exit(Demo.run(rest))
case "version", "--version", "-v": print(version)
default: help()
}
