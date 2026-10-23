import EarshotCore
import SwiftUI
import UniformTypeIdentifiers

struct PanelCard: View {
    @ObservedObject var state: NotchState

    static let maxListHeight: CGFloat = 520

    var body: some View {
        let b = state.board
        VStack(spacing: 6) {
            if let problem = state.jumpProblem {
                JumpHint(problem: problem, fix: state.actions.fixAutomation, dismiss: state.actions.dismissJumpProblem)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
            if let r = b.requests.first {
                RequestCard(item: r, group: b.groupOf(r.session), actions: state.actions)
                    .id(r.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                if b.requests.count > 1 {
                    Text(moreText(b.requests))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .frame(height: 22)
                }
                if !state.missed.isEmpty {
                    MissedModule(items: state.missed, actions: state.actions)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
                VStack(spacing: 0) {
                    ForEach(b.items.filter { $0.id != r.session.id }) { item in
                        CompactRow(item: item) { state.actions.open(item.session) }
                    }
                }
            } else {
                if !state.missed.isEmpty {
                    MissedModule(items: state.missed, actions: state.actions)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
                PanelHeader(count: b.items.count, needsYou: b.needsYou)
                if let id = state.naming, let g = b.group(id) {
                    GroupNaming(group: g, isNew: state.namingIsNew, actions: state.actions)
                        .id(id)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
                if !state.hooks.isActive {
                    OnboardingCard(outdated: state.hooks == .outdated, install: state.actions.installHooks)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
                if b.isEmpty {
                    EmptyModule()
                } else {
                    let h = estimatedHeight(b.sections)
                    Scrollable(height: min(h, Self.maxListHeight), enabled: h > Self.maxListHeight) {
                        VStack(spacing: 6) {
                            ForEach(b.sections) { section in
                                GroupModule(section: section, showHeader: b.hasGroups, state: state)
                                    .transition(.opacity)
                            }
                        }
                    }
                }
                if state.usageOpen {
                    UsageModule(usage: b.usage)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .bottom)),
                            removal: .opacity.animation(.easeIn(duration: 0.12))))
                }
            }
            PanelFooter(memory: footerMemory, usageOpen: state.usageOpen, toggleUsage: state.actions.toggleUsage,
                        prefetch: state.actions.prefetchUsage, showMenu: state.actions.showMenu)
        }
        .padding(8)
        .background(GlassBackground(radius: 26))
        .sessionDrop(state, .ungroup)
    }

    private var footerMemory: String {
        if let u = state.board.usage { return MemoryLine(used: u.ramUsed, total: u.ramTotal).text }
        return state.board.memory?.text ?? "Memory"
    }

    private func moreText(_ reqs: [RequestItem]) -> String {
        let n = reqs.count - 1
        return "\(n) more request\(n == 1 ? "" : "s") · \(reqs[1].session.chipName)"
    }

    private func estimatedHeight(_ sections: [SessionSection]) -> CGFloat {
        sections.reduce(CGFloat(0)) { acc, s in
            let open = !(s.group?.collapsed ?? false)
            let header: CGFloat = state.board.hasGroups ? 26 : 0
            return acc + 8 + header + (open ? CGFloat(s.items.count) * SessionRow.height : 0) + 6
        } - 6
    }
}

struct Scrollable<Content: View>: View {
    var height: CGFloat
    var enabled: Bool
    var indicators = false
    @ViewBuilder var content: Content
    @Environment(\.staticRendering) private var staticRendering

    var body: some View {
        if !enabled {
            content
        } else if staticRendering {
            content.frame(height: height, alignment: .top).clipped()
        } else {
            ScrollView(.vertical) { content }
                .scrollIndicators(indicators ? .visible : .never)
                .frame(height: height)
        }
    }
}

struct EmptyModule: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("No Claude Code sessions")
                .font(.system(size: 13, weight: .semibold))
            Text("Run claude in a terminal and it shows up here")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.module))
    }
}

enum DropTarget: Equatable {
    case session(String)
    case group(UUID)
    case ungroup
}

struct SessionDrop: DropDelegate {
    var state: NotchState
    var target: DropTarget

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [UTType.text]) }

    func dropEntered(info: DropInfo) {
        if case .session(let id) = target { MainActor.assumeIsolated { state.dropTarget = id } }
    }

    func dropExited(info: DropInfo) {
        if case .session(let id) = target {
            MainActor.assumeIsolated { if state.dropTarget == id { state.dropTarget = nil } }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        let state = self.state
        let target = self.target
        MainActor.assumeIsolated { state.dropTarget = nil }
        guard let provider = info.itemProviders(for: [UTType.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let dragged = obj as? NSString else { return }
            let id = dragged as String
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch target {
                    case .session(let t): state.actions.groupTogether(id, t)
                    case .group(let g): state.actions.moveToGroup(id, g)
                    case .ungroup: state.actions.moveToGroup(id, nil)
                    }
                }
            }
        }
        return true
    }
}

private struct SessionDropModifier: ViewModifier {
    var state: NotchState
    var target: DropTarget
    @Environment(\.staticRendering) private var staticRendering

    func body(content: Content) -> some View {
        if staticRendering {
            content
        } else {
            content.onDrop(of: [UTType.text], delegate: SessionDrop(state: state, target: target))
        }
    }
}

extension View {
    func sessionDrop(_ state: NotchState, _ target: DropTarget) -> some View {
        modifier(SessionDropModifier(state: state, target: target))
    }
}

struct MissedModule: View {
    var items: [MissedItem]
    var actions: NotchActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Text("Missed").font(.system(size: 12, weight: .semibold))
                Text("\(items.count)")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.45))
                Spacer()
                Button("Clear", action: actions.missedClear)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.6))
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            ForEach(items) { item in
                MissedRow(item: item, action: { actions.missedAction(item) })
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity))
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.module))
    }
}

struct MissedRow: View {
    var item: MissedItem
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 9) {
            icon.frame(width: 18, height: 18)
            Text(item.text)
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(StatusPhrase.duration(ctx.date.timeIntervalSince(item.at)))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize()
            }
            Button(item.action, action: action)
                .buttonStyle(PillButtonStyle(kind: .ghost, height: 22))
        }
        .padding(.horizontal, 8)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? Theme.hover : .clear))
        .onHover { hover = $0 }
    }

    @ViewBuilder private var icon: some View {
        switch item.kind {
        case .finished:
            SparkBadge(look: SparkLook(color: Theme.clayOnGlass), size: 18, glyph: 9)
        case .memory:
            ZStack {
                Circle().fill(Theme.well)
                ChipIcon()
                    .stroke(Color(nsColor: Theme.clayOnGlass), style: StrokeStyle(lineWidth: 1.9 * 10 / 24, lineCap: .round))
                    .frame(width: 10, height: 10)
            }
        case .blocked:
            StopBadge().scaleEffect(18 / 22)
        }
    }
}
