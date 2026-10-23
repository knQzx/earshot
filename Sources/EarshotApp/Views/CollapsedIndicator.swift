import EarshotCore
import SwiftUI

struct IslandContent: View {
    @ObservedObject var state: NotchState
    var layout: IslandLayout

    var body: some View {
        let board = state.board
        let mode = state.mode
        let ears = IslandLayout.of(.ears, metrics: state.metrics, board: board)
        ZStack(alignment: .top) {
            if board.isEmpty {
                if !state.metrics.hasNotch {
                    SparkBadge(look: SparkLook(color: NSColor(white: 1, alpha: 0.35)), size: 16, glyph: 9, fill: Theme.notchWell)
                        .frame(width: layout.bodyWidth, height: layout.bodyHeight)
                }
            } else {
                Ears(board: board, metrics: state.metrics, missed: state.missed.count)
                    .frame(width: ears.bodyWidth, height: ears.bodyHeight)
                    .opacity(mode == .ears ? 1 : 0)
                    .environment(\.sparkHidden, mode != .ears)
                    .environment(\.sparkLayerBacked, true)
                    .allowsHitTesting(mode == .ears)
            }
            if case .memory(let alert) = mode {
                MemoryPill(alert: alert, sessions: board.items.map(\.session), metrics: state.metrics, actions: state.actions,
                           simulated: state.memorySimulated)
                    .frame(width: layout.bodyWidth, height: layout.bodyHeight)
                    .transition(.pillContent)
            }
            if case .blocked(let b) = mode {
                BlockedPill(alert: b, group: board.groupOf(b.session), metrics: state.metrics, actions: state.actions)
                    .id(b.id)
                    .frame(width: layout.bodyWidth, height: layout.bodyHeight)
                    .transition(.pillContent)
            }
            if case .finished(let info, let more) = mode {
                FinishedPill(info: info, more: more, metrics: state.metrics, actions: state.actions,
                             simulated: state.forcedFinished.contains(info.id))
                    .id(info.id)
                    .frame(width: layout.bodyWidth, height: layout.bodyHeight)
                    .transition(.pillContent)
            }
            if case .approval(let item) = mode {
                InlineApproval(item: item, group: board.groupOf(item.session), more: 0,
                               metrics: state.metrics, actions: state.actions, width: layout.bodyWidth)
                    .id(item.id)
                    .frame(width: layout.bodyWidth, height: layout.bodyHeight)
                    .transition(.pillContent)
            }
        }
        .frame(width: layout.bodyWidth, height: layout.bodyHeight, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { state.actions.toggle() }
    }
}

private struct PillSlide: ViewModifier {
    var amount: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
            .offset(y: -22 * amount)
    }
}

extension AnyTransition {
    static var pillContent: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PillSlide(amount: 1), identity: PillSlide(amount: 0))
                .animation(.spring(response: 0.38, dampingFraction: 0.78).delay(0.06)),
            removal: .modifier(active: PillSlide(amount: 1), identity: PillSlide(amount: 0))
                .animation(.easeIn(duration: 0.18)))
    }

}

struct Ears: View {
    var board: Board
    var metrics: NotchMetrics
    var missed = 0

    var body: some View {
        if metrics.hasNotch {
            HStack(spacing: 0) {
                SparkBadge(look: .brand(needsYou: board.needsYou > 0), size: 22, glyph: 12, fill: Theme.notchWell)
                    .overlay(alignment: .bottomTrailing) {
                        if missed > 0 {
                            Text("\(missed)")
                                .font(.system(size: 8.5, weight: .bold).monospacedDigit())
                                .foregroundStyle(Color.black)
                                .padding(.horizontal, 3)
                                .frame(minWidth: 12, minHeight: 12)
                                .background(Capsule().fill(Color(nsColor: Theme.clayOnBlack)))
                                .background(Capsule().fill(Color.black).padding(-1.5))
                                .offset(x: 4, y: 3)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                Spacer(minLength: 0)
                AvatarStack(items: board.items)
            }
            .padding(.horizontal, 12)
        } else {
            HStack(spacing: 6) {
                SparkBadge(look: .brand(needsYou: board.needsYou > 0), size: 16, glyph: 9, fill: Theme.notchWell)
                AvatarStack(items: board.items, avatar: 16)
            }
        }
    }
}

struct AvatarStack: View {
    var items: [SessionInfo]
    var avatar: CGFloat = IslandLayout.avatar
    var onBlack = true
    var separator = Color.black

    var body: some View {
        HStack(spacing: -IslandLayout.overlap) {
            ForEach(items.prefix(IslandLayout.maxAvatars)) { item in
                SparkBadge(look: item.look(onBlack: onBlack), size: avatar, glyph: avatar / 2, fill: Theme.notchWell, separator: separator)
            }
            if items.count > IslandLayout.maxAvatars {
                Text("+\(items.count - IslandLayout.maxAvatars)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.6))
                    .padding(.leading, 4 + IslandLayout.overlap)
            }
        }
    }
}

struct InlineApproval: View {
    var item: RequestItem
    var group: SessionGroup?
    var more: Int
    var metrics: NotchMetrics
    var actions: NotchActions
    var width: CGFloat = 460
    @State private var armed = false
    @Environment(\.staticRendering) private var staticRendering

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    SparkBadge(look: SparkLook(color: Theme.clayOnBlack, hop: true, ring: true), size: 22, glyph: 12, fill: Theme.notchWell)
                    Text(item.session.chipName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(nsColor: Theme.rgb(0xF5F5F7)))
                        .lineLimit(1)
                        .fixedSize()
                    if let group { GroupCapsule(group: group, compact: true) }
                }
                .padding(.leading, 12)
                Spacer(minLength: metrics.hasNotch ? metrics.notchWidth : 12)
                if item.simulated {
                    SimulatedTag().padding(.trailing, more > 0 ? 6 : 14)
                }
                if more > 0 {
                    Text("+\(more)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.clayLabel)
                        .padding(.trailing, 14)
                }
            }
            .frame(height: metrics.hasNotch ? metrics.height : 32)
            HStack(spacing: 8) {
                if let rule = item.request.policyRule {
                    PolicyLabel(rule: rule).fixedSize()
                }
                HStack(spacing: 6) {
                    Text(firstLine)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let marker {
                        Text(marker)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.clayLabel)
                            .padding(.horizontal, 6)
                            .frame(height: 17)
                            .background(Capsule().fill(Color(nsColor: Theme.clayOnBlack).opacity(0.18)))
                            .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if item.simulated {
                        Button("Dismiss") { act(.deny) }
                            .buttonStyle(PillButtonStyle(kind: .ghost, height: 26))
                    } else {
                        Button("Deny") { act(.deny) }
                            .buttonStyle(PillButtonStyle(kind: .ghost, height: 26))
                        if marker != nil {
                            Button("Review") { if actions.isArmed(item.id) { actions.expand() } }
                                .buttonStyle(PillButtonStyle(kind: .primary, height: 26))
                        } else {
                            Button("Allow") { act(.allow) }
                                .buttonStyle(PillButtonStyle(kind: .primary, height: 26))
                        }
                    }
                }
                .opacity(armed || staticRendering ? 1 : 0.45)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 4)
        }
        .onAppear {
            actions.cardAppeared(item.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.easeOut(duration: 0.18)) { armed = true }
            }
        }
    }

    private var fullCommand: String {
        let r = item.request
        if r.toolName == "Bash", let c = r.toolInput["command"]?.string { return c }
        return r.summary.short
    }

    private var lines: [Substring] {
        fullCommand.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var firstLine: String {
        lines.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    private var marker: String? {
        let extra = lines.count - 1
        if extra > 0 { return extra == 1 ? "+1 line" : "+\(extra) lines" }
        let room = width - 14 - 10 - 8 - 150 - (item.request.policyRule == nil ? 0 : 110)
        let w = (firstLine as NSString).size(withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width
        return w > room ? "more" : nil
    }

    private func act(_ d: Decision) {
        guard actions.isArmed(item.id) else { return }
        actions.decide(item.id, d)
    }
}

struct FinishedPill: View {
    var info: SessionInfo
    var more: Int
    var metrics: NotchMetrics
    var actions: NotchActions
    var simulated = false
    @State private var appearedAt = Date()
    @State private var armed = false
    @Environment(\.staticRendering) private var staticRendering

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    SparkBadge(look: SparkLook(color: Theme.clayOnBlack, hop: true), size: 22, glyph: 12, fill: Theme.notchWell)
                    Text(info.session.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(nsColor: Theme.rgb(0xF5F5F7)))
                        .lineLimit(1)
                    if let group = info.group { GroupCapsule(group: group, compact: true) }
                }
                .padding(.leading, 12)
                Spacer(minLength: metrics.hasNotch ? metrics.notchWidth : 12)
                HStack(spacing: 8) {
                    if simulated { SimulatedTag() }
                    if more > 0 {
                        Text("+\(more)")
                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    }
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text("Done · \(StatusPhrase.duration(ctx.date.timeIntervalSince(info.session.statusSince)))")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .foregroundStyle(Theme.clayLabel)
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 14)
            }
            .frame(height: metrics.hasNotch ? metrics.height : 32)
            HStack(spacing: 8) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Button("Later") { act(actions.finishedLater) }
                        .buttonStyle(PillButtonStyle(kind: .ghost, height: 26))
                    Button("Open") { act { actions.finishedOpen(info.session) } }
                        .buttonStyle(PillButtonStyle(kind: .primary, height: 26))
                }
                .opacity(armed || staticRendering ? 1 : 0.45)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 4)
        }
        .onAppear {
            appearedAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.easeOut(duration: 0.18)) { armed = true }
            }
        }
    }

    private var message: String {
        let line = info.session.lastMessage.map(ToolSummary.firstLine) ?? ""
        return line.isEmpty ? "Ready for review" : line
    }

    private func act(_ body: () -> Void) {
        guard Date().timeIntervalSince(appearedAt) >= 0.4 else { return }
        body()
    }
}

struct ClayGlow<S: Shape>: View {
    var shape: S
    @State private var strength = 0.0
    @Environment(\.staticRendering) private var staticRendering

    var body: some View {
        shape
            .stroke(Color(nsColor: Theme.clayOnGlass), lineWidth: 2.5)
            .blur(radius: 7)
            .opacity(staticRendering ? 0.55 : strength)
            .allowsHitTesting(false)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation(.easeOut(duration: 0.12)) { strength = 0.9 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        withAnimation(.easeOut(duration: 0.8)) { strength = 0 }
                    }
                }
            }
    }
}

struct MemoryPill: View {
    var alert: MemoryAlert
    var sessions: [Session]
    var metrics: NotchMetrics
    var actions: NotchActions
    var simulated = false
    @State private var appearedAt = Date()
    @State private var armed = false
    @State private var confirming = false
    @Environment(\.staticRendering) private var staticRendering

    static func title(_ a: MemoryAlert) -> String {
        a.level == .critical ? "Memory is almost full" : "Memory is running low"
    }

    static func figures(_ a: MemoryAlert) -> String {
        let used = Double(a.ramUsed) / 1_073_741_824, total = Double(a.ramTotal) / 1_073_741_824
        var s = String(format: "%.1f of %.0f GB", used, total)
        if a.swapUsed > 0 { s += " · swap " + UsageSampler.bytes(a.swapUsed) }
        return s
    }

    var body: some View {
        let entry = alert.top.first
        let session = entry.flatMap { e in sessions.first { $0.pid == e.sessionPID } }
        let child = entry?.children.first
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    MemoryBadge(critical: alert.level == .critical)
                    Text(Self.title(alert))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(nsColor: Theme.rgb(0xF5F5F7)))
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.leading, 12)
                Spacer(minLength: metrics.hasNotch ? metrics.notchWidth : 12)
                HStack(spacing: 8) {
                    if simulated { SimulatedTag() }
                    Text(Self.figures(alert))
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.clayLabel)
                    Button(action: actions.memoryDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.white.opacity(0.1)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 12)
            }
            .frame(height: metrics.hasNotch ? metrics.height : 32)
            HStack(spacing: 8) {
                Text(detail(session: session, entry: entry, child: child))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if let child {
                        Button(confirming ? "Confirm" : "Stop \(Self.short(child.name))") {
                            act {
                                if confirming {
                                    actions.memoryStop(child.pid)
                                    confirming = false
                                } else {
                                    withAnimation(.easeOut(duration: 0.15)) { confirming = true }
                                }
                            }
                        }
                        .buttonStyle(PillButtonStyle(kind: .ghost, height: 26))
                    }
                    if let session {
                        Button("Open") { act { actions.memoryOpen(session) } }
                            .buttonStyle(PillButtonStyle(kind: .primary, height: 26))
                    }
                }
                .opacity(armed || staticRendering ? 1 : 0.45)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 4)
        }
        .onAppear {
            appearedAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.easeOut(duration: 0.18)) { armed = true }
            }
        }
    }

    private func detail(session: Session?, entry: MemoryAlert.Entry?, child: MemoryAlert.Child?) -> String {
        guard let entry else { return "No Claude session is using much memory" }
        var s = "\(session?.name ?? "Claude") uses \(UsageSampler.bytes(entry.rss))"
        if let child { s += " · \(child.name) \(UsageSampler.bytes(child.rss))" }
        return s
    }

    static func short(_ name: String) -> String {
        name.count > 14 ? String(name.prefix(13)) + "…" : name
    }

    private func act(_ body: () -> Void) {
        guard Date().timeIntervalSince(appearedAt) >= 0.4 else { return }
        body()
    }
}

struct MemoryBadge: View {
    var critical: Bool
    @Environment(\.staticRendering) private var staticRendering

    var body: some View {
        ZStack {
            Circle().fill(Theme.notchWell)
            ChipIcon()
                .stroke(Color(nsColor: Theme.clayOnBlack), style: StrokeStyle(lineWidth: 1.9 * 12 / 24, lineCap: .round))
                .frame(width: 12, height: 12)
            if critical {
                if staticRendering {
                    Circle().strokeBorder(Color(nsColor: Theme.clayOnGlass).opacity(0.9), lineWidth: 1.5)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 30)) { ctx in
                        let p = SparkPhase.at(ctx.date.timeIntervalSinceReferenceDate, SparkLook(color: Theme.clayOnBlack, ring: true))
                        Circle()
                            .strokeBorder(Color(nsColor: Theme.clayOnGlass), lineWidth: 1.5)
                            .scaleEffect(p.ringScale)
                            .opacity(p.ringAlpha)
                    }
                }
            }
        }
        .frame(width: 22, height: 22)
    }
}

struct BlockedPill: View {
    var alert: BlockedAlert
    var group: SessionGroup?
    var metrics: NotchMetrics
    var actions: NotchActions
    @State private var appearedAt = Date()
    @State private var armed = false
    @Environment(\.staticRendering) private var staticRendering

    static func title(_ b: BlockedAlert) -> String { "Blocked · \(b.rule)" }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    StopBadge()
                    (Text("Blocked").foregroundColor(Theme.clayLabel) + Text(" · \(alert.rule)").foregroundColor(Color(nsColor: Theme.rgb(0xF5F5F7))))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize()
                }
                .padding(.leading, 12)
                Spacer(minLength: metrics.hasNotch ? metrics.notchWidth : 12)
                HStack(spacing: 7) {
                    if alert.simulated { SimulatedTag() }
                    Text(alert.session.chipName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.7))
                    if let group { GroupCapsule(group: group, compact: true) }
                }
                .lineLimit(1)
                .fixedSize()
                .padding(.trailing, 14)
            }
            .frame(height: metrics.hasNotch ? metrics.height : 32)
            HStack(spacing: 8) {
                Text(ToolSummary.firstLine(alert.command))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Button("Details") { act { actions.blockedDetails(alert) } }
                        .buttonStyle(PillButtonStyle(kind: .ghost, height: 26))
                    Button("OK") { act { actions.blockedDismiss(alert.id) } }
                        .buttonStyle(PillButtonStyle(kind: .primary, height: 26))
                }
                .opacity(armed || staticRendering ? 1 : 0.45)
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .frame(maxHeight: .infinity)
            .padding(.bottom, 4)
        }
        .onAppear {
            appearedAt = Date()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.easeOut(duration: 0.18)) { armed = true }
            }
        }
    }

    private func act(_ body: () -> Void) {
        guard Date().timeIntervalSince(appearedAt) >= 0.4 else { return }
        body()
    }
}

struct StopBadge: View {
    var body: some View {
        ZStack {
            Circle().fill(Theme.notchWell)
            Circle()
                .strokeBorder(Color(nsColor: Theme.clayOnBlack), lineWidth: 1.6)
                .frame(width: 12, height: 12)
            Path { p in
                p.move(to: CGPoint(x: 7.2, y: 7.2))
                p.addLine(to: CGPoint(x: 14.8, y: 14.8))
            }
            .stroke(Color(nsColor: Theme.clayOnBlack), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
        }
        .frame(width: 22, height: 22)
    }
}

struct SimulatedTag: View {
    var body: some View {
        Text("Simulated")
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.75))
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Capsule().strokeBorder(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .fixedSize()
    }
}
