import AppKit
import CLIslandCore
import SwiftUI

private struct FrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

struct NotchShape: Shape {
    var bottomRadius: CGFloat
    var topRadius: CGFloat = 6

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let t = topRadius, b = min(bottomRadius, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchRoot: View {
    var store: Store
    var geo: NotchGeometry
    var onFrame: (CGRect) -> Void

    private enum Mode: Equatable { case hidden, compact, panel, toast(String) }

    private var mode: Mode {
        if let t = store.toast { return .toast(t.id) }
        if store.sessions.isEmpty { return .hidden }
        return store.panelOpen ? .panel : .compact
    }

    private var expanded: Bool { mode != .hidden && mode != .compact }

    private var wing: CGFloat {
        let n = min(store.sessions.count, 4)
        return max(geo.hasNotch ? 58 : 44, CGFloat(n) * 22 + 26)
    }

    private var width: CGFloat {
        switch mode {
        case .hidden: return max(geo.notchWidth, 120)
        case .compact: return geo.notchWidth + wing * 2 + 12
        case .panel: return max(geo.notchWidth + 180, 560)
        case .toast: return max(geo.notchWidth + 150, 500)
        }
    }

    private var showLive: Bool {
        mode == .compact && store.config.activityLine && store.focus?.status == .working && store.focus?.liveLine != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            island
                .background(GeometryReader { g in Color.clear.preference(key: FrameKey.self, value: g.frame(in: .global)) })
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(FrameKey.self) { rect in onFrame(mode == .hidden ? .zero : rect) }
        .onChange(of: mode) { _, m in if m == .hidden { onFrame(.zero) } }
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.42, dampingFraction: 0.78), value: mode)
        .animation(.easeInOut(duration: 0.25), value: showLive)
        .preferredColorScheme(.dark)
    }

    private var island: some View {
        VStack(spacing: 0) {
            header
            if showLive, let s = store.focus { LiveLine(session: s).transition(.opacity) }
            if expanded {
                Group {
                    if let t = store.toast { ToastView(store: store, toast: t) }
                    else if mode == .panel { PanelView(store: store) }
                }
                .padding(.horizontal, 18)
                .padding(.top, 4)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .frame(width: width)
        .background(Color.black)
        .overlay(alignment: .bottom) {
            if mode == .compact, let s = store.working.first { Shimmer(color: Theme.color(s.agent)).padding(.horizontal, 24) }
        }
        .clipShape(NotchShape(bottomRadius: expanded ? 24 : (showLive ? 14 : 11)))
        .shadow(color: .black.opacity(expanded ? 0.55 : 0), radius: 18, y: 10)
        .opacity(mode == .hidden ? 0 : 1)
        .modifier(Shake(trigger: store.shakeTick))
    }

    private var header: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(store.sessions.prefix(4)) { s in Glyph(session: s) }
                if store.sessions.count > 4 {
                    Text("+\(store.sessions.count - 4)").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                }
            }
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: geo.notchWidth)
            RightWing(store: store)
                .padding(.trailing, 16)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: geo.notchHeight)
    }
}

// MARK: Compact pieces

struct Glyph: View {
    var session: Session
    var size: CGFloat = 13
    @State private var pulse = false

    var body: some View {
        Text(Theme.glyph(session.agent))
            .font(.system(size: session.agent == "codex" ? size - 3 : size, weight: .bold, design: session.agent == "codex" ? .monospaced : .default))
            .foregroundStyle(Theme.color(session.agent))
            .opacity(session.status == .idle ? 0.5 : 1)
            .scaleEffect(pulse ? 1.2 : 1)
            .overlay(alignment: .topTrailing) {
                if let dot = dotColor {
                    Circle().fill(dot).frame(width: 6, height: 6).offset(x: 4, y: -2)
                }
            }
            .id(session.status)
            .onAppear {
                guard session.status == .working, !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
            }
            .help("\(Theme.name(session.agent)) · \(session.project)")
    }

    private var dotColor: Color? {
        switch session.status {
        case .done: return session.unread ? Theme.ok : nil
        case .attention: return Theme.warn
        case .error: return Theme.err
        default: return nil
        }
    }
}

struct RightWing: View {
    var store: Store

    var body: some View {
        if let s = store.focus {
            HStack(spacing: 5) {
                if let pct = s.contextPct {
                    Ring(pct: pct, size: 14)
                    Text("\(Int(pct))%").font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(Color(white: 0.85))
                } else if s.status == .working, let start = s.turnStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(Theme.duration(Date().timeIntervalSince(start))).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }
}

struct Ring: View {
    var pct: Double
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Color(white: 0.2), lineWidth: 2.5)
            Circle().trim(from: 0, to: min(1, pct / 100))
                .stroke(Theme.contextColor(pct), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.5), value: pct)
    }
}

struct LiveLine: View {
    var session: Session

    var body: some View {
        HStack(spacing: 6) {
            Text(Theme.glyph(session.agent)).font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.color(session.agent))
            Text(session.liveLine ?? "").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Color(white: 0.88)).lineLimit(1).truncationMode(.middle)
            if let p = session.taskProgress {
                Text("· \(p.done)/\(p.total)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 20)
        .padding(.bottom, 6)
    }
}

struct Shimmer: View {
    var color: Color

    var body: some View {
        if reduceMotion {
            color.opacity(0.6).frame(height: 2)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                let phase = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                LinearGradient(colors: [.clear, color, .clear],
                               startPoint: UnitPoint(x: phase * 2 - 1, y: 0.5), endPoint: UnitPoint(x: phase * 2, y: 0.5))
                    .frame(height: 2)
            }
        }
    }
}

struct Shake: ViewModifier {
    var trigger: Int

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { view, x in
                view.offset(x: x)
            } keyframes: { _ in
                KeyframeTrack {
                    LinearKeyframe(-7, duration: 0.06)
                    LinearKeyframe(7, duration: 0.08)
                    LinearKeyframe(-5, duration: 0.08)
                    LinearKeyframe(4, duration: 0.07)
                    LinearKeyframe(0, duration: 0.06)
                }
            }
        }
    }
}

// MARK: Shared controls

struct PillButton: View {
    var title: String
    var primary = false
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(primary ? Color.black : Color.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(Capsule().fill(primary ? Color.white.opacity(hover ? 0.85 : 1) : Color.white.opacity(hover ? 0.16 : 0.1)))
                .overlay(Capsule().stroke(Color.white.opacity(primary ? 0 : 0.12)))
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct CopyButton: View {
    var title: String
    var text: String
    var primary = false
    var store: Store
    @State private var copied = false

    var body: some View {
        PillButton(title: copied ? "Copied" : title, primary: primary && !copied) {
            store.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
    }
}

struct Badge: View {
    var symbol: String
    var color: Color
    @State private var ripple = false

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.16))
            Circle().stroke(color, lineWidth: 2).scaleEffect(ripple ? 1.7 : 1).opacity(ripple ? 0 : 0.8)
            Text(symbol).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(color)
        }
        .frame(width: 32, height: 32)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.1).delay(0.15).repeatCount(2, autoreverses: false)) { ripple = true }
        }
    }
}

struct ContextBar: View {
    var pct: Double

    var body: some View {
        HStack(spacing: 8) {
            Text("context").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.muted)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(white: 0.16))
                    Capsule().fill(Theme.contextColor(pct)).frame(width: g.size.width * min(1, pct / 100))
                }
            }
            .frame(height: 4)
            Text("\(Int(pct))%").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.muted)
        }
    }
}

struct TaskProgressView: View {
    var session: Session

    var body: some View {
        if let p = session.taskProgress {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2) {
                    ForEach(session.tasks) { t in
                        Capsule().fill(t.done ? Theme.color(session.agent) : (t.status == "in_progress" ? Theme.color(session.agent).opacity(0.45) : Color(white: 0.18)))
                            .frame(height: 4)
                    }
                }
                HStack {
                    Text("\(p.done)/\(p.total) tasks").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.muted)
                    if let a = session.activeTask {
                        Text(a).font(.system(size: 11)).foregroundStyle(Color(white: 0.8)).lineLimit(1)
                    }
                }
            }
        }
    }
}

struct ToastHeader<Trailing: View>: View {
    var badge: Badge
    var agent: String?
    var title: String
    var subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let agent {
                        Text(Theme.glyph(agent)).font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.color(agent))
                    }
                    Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                }
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { trailing }
        }
    }
}

// MARK: Toasts

struct ToastView: View {
    var store: Store
    var toast: Toast

    var body: some View {
        switch toast {
        case .done(let k): if let s = store.session(k) { DoneToast(store: store, s: s) }
        case .permission(let p): PermissionToast(store: store, p: p)
        case .attention(let k, let msg): if let s = store.session(k) { SimpleToast(store: store, s: s, symbol: "!", color: Theme.warn, title: "\(Theme.name(s.agent)) needs you", message: msg) }
        case .context(let k):
            if let s = store.session(k) {
                SimpleToast(store: store, s: s, symbol: "\(Int(s.contextPct ?? 0))", color: Theme.err, title: "Context is almost full",
                            message: s.agent == "gemini" ? "Run /compress or start a fresh session soon." : "Run /compact or start a fresh session soon.",
                            footer: AnyView(ContextBar(pct: s.contextPct ?? 0)))
            }
        case .limit(let agent, let l): LimitToast(agent: agent, limit: l, store: store)
        case .stuck(let k):
            if let s = store.session(k) {
                SimpleToast(store: store, s: s, symbol: "…", color: Theme.warn, title: "\(s.project) is quiet",
                            message: "No activity for \(Theme.duration(Date().timeIntervalSince(s.lastEventAt))). Last: \(s.liveLine ?? "thinking").")
            }
        case .error(let k, let msg): if let s = store.session(k) { SimpleToast(store: store, s: s, symbol: "!", color: Theme.err, title: "\(Theme.name(s.agent)) stopped with an error", message: msg) }
        case .run(let k): if let s = store.session(k) { RunToast(store: store, s: s) }
        }
    }
}

struct DoneToast: View {
    var store: Store
    var s: Session

    var subtitle: String {
        [s.project, s.term?.label, s.lastDuration.map(Theme.duration)].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToastHeader(badge: Badge(symbol: s.commands.isEmpty ? "✓" : "$", color: Theme.ok), agent: s.agent,
                        title: s.commands.isEmpty ? "\(Theme.name(s.agent)) finished" : "\(s.commands.count) command\(s.commands.count == 1 ? "" : "s") to run",
                        subtitle: subtitle) {
                if !s.commands.isEmpty { PillButton(title: "Dismiss") { store.dismissCommands(s.id) } }
                PillButton(title: "Open", primary: s.commands.isEmpty) { store.open(s.id) }
            }
            if let sum = s.summary, !sum.isEmpty {
                Text(sum).font(.system(size: 12.5)).foregroundStyle(Color(white: 0.86)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            if !s.commands.isEmpty { CommandsList(store: store, commands: s.commands) }
            TaskProgressView(session: s)
            if let pct = s.contextPct { ContextBar(pct: pct) }
        }
    }
}

struct CommandsList: View {
    var store: Store
    var commands: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(commands.prefix(8).enumerated()), id: \.offset) { i, cmd in
                HStack(spacing: 8) {
                    Text("\(i + 1)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color(white: 0.45)).frame(width: 14)
                    Text("$ ").font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(white: 0.45))
                        + Text(cmd).font(.system(size: 12, design: .monospaced)).foregroundStyle(Color(white: 0.92))
                    Spacer(minLength: 6)
                    CopyButton(title: "Copy", text: cmd, store: store)
                }
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.vertical, 4)
                .padding(.leading, 8)
                .padding(.trailing, 5)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
            }
            if commands.count > 8 {
                Text("+\(commands.count - 8) more, included in Copy all").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            HStack {
                Text("Copy one by one, or all at once").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                Spacer()
                CopyButton(title: "Copy as one line (&&)", text: commands.joined(separator: " && "), store: store)
                CopyButton(title: "Copy all \(commands.count)", text: commands.joined(separator: "\n"), primary: true, store: store)
            }
            .padding(.top, 4)
        }
    }
}

struct PermissionToast: View {
    var store: Store
    var p: PermissionRequest

    var body: some View {
        let s = store.session(p.sessionKey)
        VStack(alignment: .leading, spacing: 10) {
            ToastHeader(badge: Badge(symbol: "?", color: Theme.warn), agent: s?.agent,
                        title: "\(Theme.name(s?.agent ?? "claude")) wants to use \(p.tool)",
                        subtitle: [s?.project, s?.term?.label].compactMap { $0 }.joined(separator: " · ")) { EmptyView() }
            Text(p.detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(red: 0.95, green: 0.84, blue: 0.63))
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
            HStack {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text("Answer here, or in the terminal in \(max(0, Int(p.deadline.timeIntervalSinceNow)))s")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                }
                Spacer()
                PillButton(title: "In terminal") { store.answer(p.requestId, "ask") }
                PillButton(title: "Deny") { store.answer(p.requestId, "deny") }
                PillButton(title: "Allow once", primary: true) { store.answer(p.requestId, "allow") }
            }
        }
    }
}

struct SimpleToast: View {
    var store: Store
    var s: Session
    var symbol: String
    var color: Color
    var title: String
    var message: String
    var footer: AnyView? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToastHeader(badge: Badge(symbol: symbol, color: color), agent: s.agent, title: title,
                        subtitle: [s.project, s.term?.label].compactMap { $0 }.joined(separator: " · ")) {
                PillButton(title: "Dismiss") { store.dismissToast() }
                PillButton(title: "Open", primary: true) { store.open(s.id) }
            }
            Text(message).font(.system(size: 12.5)).foregroundStyle(Color(white: 0.86)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let footer { footer }
        }
    }

}

struct LimitToast: View {
    var agent: String
    var limit: Limit
    var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToastHeader(badge: Badge(symbol: "\(Int(limit.pct))", color: limit.pct >= 95 ? Theme.err : Theme.warn), agent: agent,
                        title: "\(Theme.name(agent)) \(limit.name) limit at \(Int(limit.pct))%",
                        subtitle: Theme.until(limit.resetsAt).map { "Resets in \($0)" } ?? "Usage window") {
                PillButton(title: "Dismiss") { store.dismissToast() }
            }
            ContextBar(pct: limit.pct)
        }
    }
}

struct RunToast: View {
    var store: Store
    var s: Session

    var ok: Bool { s.exitCode == 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToastHeader(badge: Badge(symbol: ok ? "✓" : "✗", color: ok ? Theme.ok : Theme.err), agent: nil,
                        title: "\(s.runCommand?.clipped(40) ?? "Command") \(ok ? "finished" : "failed")",
                        subtitle: ["exit \(s.exitCode ?? -1)", s.lastDuration.map(Theme.duration), s.cwd?.lastPathComponent, s.term?.label].compactMap { $0 }.joined(separator: " · ")) {
                if !ok && !s.tail.isEmpty { CopyButton(title: "Copy output", text: s.tail.joined(separator: "\n"), store: store) }
                PillButton(title: "Open", primary: true) { store.open(s.id) }
            }
            if !ok && !s.tail.isEmpty {
                Text(s.tail.suffix(6).joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(white: 0.8))
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
            }
        }
    }
}

// MARK: Panel

struct PanelView: View {
    var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(store.sessions.count) session\(store.sessions.count == 1 ? "" : "s") · \(store.working.count) working")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                Spacer()
                ForEach(Array(store.allLimits.prefix(3).enumerated()), id: \.offset) { _, item in
                    LimitChip(agent: item.agent, limit: item.limit)
                }
            }
            .padding(.bottom, 4)
            Rectangle().fill(Theme.line).frame(height: 1)
            if store.sessions.count <= 6 {
                rows
            } else {
                ScrollView(.vertical, showsIndicators: false) { rows }.frame(height: 330)
            }
        }
    }
}

extension PanelView {
    var rows: some View {
        VStack(spacing: 2) {
            ForEach(store.sessions.sorted(by: { $0.lastEventAt > $1.lastEventAt })) { s in SessionRow(store: store, s: s) }
        }
    }
}

struct LimitChip: View {
    var agent: String
    var limit: Limit

    var body: some View {
        HStack(spacing: 4) {
            Text(Theme.glyph(agent)).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.color(agent))
            Text("\(limit.name) \(Int(limit.pct))%").foregroundStyle(limit.pct >= 80 ? Theme.warn : Color(white: 0.85))
            if let r = Theme.until(limit.resetsAt) { Text("· \(r)").foregroundStyle(Theme.muted) }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.white.opacity(0.07)))
    }
}

struct SessionRow: View {
    var store: Store
    var s: Session
    @State private var hover = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Glyph(session: s, size: 14).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.project).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text([Theme.name(s.agent), s.term?.label].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                if s.status == .working, let live = s.liveLine {
                    Text(live).font(.system(size: 11)).foregroundStyle(Theme.color(s.agent)).lineLimit(1).truncationMode(.middle)
                } else if let msg = s.status == .error ? s.errorMessage : s.summary, !msg.isEmpty {
                    Text(msg).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    if !s.commands.isEmpty {
                        Button { store.showCommands(s.id) } label: {
                            Text("\(s.commands.count) cmd\(s.commands.count == 1 ? "" : "s")")
                                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Color.white.opacity(0.14)))
                        }
                        .buttonStyle(.plain)
                        .help("Show commands to copy")
                    }
                    StatusPill(s: s)
                }
                HStack(spacing: 6) {
                    if let p = s.taskProgress { Text("\(p.done)/\(p.total)").foregroundStyle(Color(white: 0.75)) }
                    if let c = s.costUSD { Text(String(format: "$%.2f", c)).foregroundStyle(Theme.muted) }
                    if let pct = s.contextPct {
                        Ring(pct: pct, size: 10)
                        Text("\(Int(pct))%").foregroundStyle(Theme.muted)
                    }
                }
                .font(.system(size: 10.5, design: .monospaced))
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(hover ? 0.06 : 0)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { store.open(s.id) }
    }
}

struct StatusPill: View {
    var s: Session

    var color: Color {
        switch s.status {
        case .working: return Theme.color(s.agent)
        case .done: return Theme.ok
        case .attention: return Theme.warn
        case .error: return Theme.err
        case .idle: return Theme.muted
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            Text(label)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(color)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .overlay(Capsule().stroke(color.opacity(0.55)))
        }
    }

    var label: String {
        if s.status == .working, let start = s.turnStartedAt { return "working \(Theme.duration(Date().timeIntervalSince(start)))" }
        if s.agent == "run", let code = s.exitCode, s.status != .working { return code == 0 ? "done" : "exit \(code)" }
        return s.status.label
    }
}
