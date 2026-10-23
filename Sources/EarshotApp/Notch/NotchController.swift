import AppKit
import Carbon.HIToolbox
import Combine
import EarshotCore
import SwiftUI

@MainActor
final class NotchController {
    let state = NotchState(metrics: .builtInSample)
    var onOpenSettings: (() -> Void)?
    var pointer: () -> NSPoint = { NSEvent.mouseLocation }

    private let panel = NotchPanel()
    private let model: AppModel
    private let prefs: Preferences
    private let hooks: HookControl
    private let sampler = UsageSampler()
    private var hosting: NotchHostingView<IslandView>?
    private var centerX: CGFloat = 0
    private var top: CGFloat = 0
    private var maxPanelHeight: CGFloat = 600
    private var memory: MemoryLine?
    private var prefetched: UsageInfo?
    private var sampledAt = Date.distantPast
    private var rebuildPending = false
    private var shrinkWork: DispatchWorkItem?
    private var leaveWork: DispatchWorkItem?
    private var autoCloseWork: DispatchWorkItem?
    private var hoverPoll: Timer?
    private var proximityMonitors: [Any] = []
    private var dwellStart: Date?
    private var reopenAfter = Date.distantPast
    var hoverLog: ((String) -> Void)?
    private var frontWork: DispatchWorkItem?
    private var frontID: String?
    private var monitors: [Any] = []
    private var mouseWasInside = false
    private var menuOpen = false
    private var dragging = false
    private var shownAt: [UUID: Date] = [:]
    private var bag = Set<AnyCancellable>()

    private static let panelPad = CGSize(width: 40, height: 64)
    private static let islandPad = CGSize(width: 30, height: 36)

    init(model: AppModel, prefs: Preferences, hooks: HookControl) {
        self.model = model
        self.prefs = prefs
        self.hooks = hooks
        state.hooks = hooks.status()
        wireActions()

        let host = NotchHostingView(rootView: IslandView(state: state))
        host.sizingOptions = []
        host.onRightClick = { [weak self] p in self?.rightClick(at: p) ?? false }
        host.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        panel.contentView = host
        hosting = host

        model.objectWillChange
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRebuild() }
            }
            .store(in: &bag)
        model.$memoryAlert.removeDuplicates().dropFirst()
            .sink { [weak self] alert in
                MainActor.assumeIsolated { self?.memoryAlertChanged(alert) }
            }
            .store(in: &bag)
        model.$jumpProblem.removeDuplicates().dropFirst()
            .sink { [weak self] problem in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    withAnimation(IslandView.spring) { self.state.jumpProblem = problem }
                    if problem != nil, !self.state.expanded { self.expand(focus: false) } else { self.updateFrame() }
                }
            }
            .store(in: &bag)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.relayout() }
            }
            .store(in: &bag)
        prefs.$islandStyle
            .sink { [weak self] style in
                MainActor.assumeIsolated { self?.state.glass = style == .glass && IslandGlass<Rectangle>.supported }
            }
            .store(in: &bag)
        prefs.$screen.dropFirst()
            .sink { [weak self] choice in
                MainActor.assumeIsolated { self?.relayout(choice) }
            }
            .store(in: &bag)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.hoverTick() }
            }
            .store(in: &bag)

        rebuild()
        relayout()
        installProximityMonitors()
        hoverTick()
    }

    private func installProximityMonitors() {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { proximityMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return e
        }) { proximityMonitors.append(m) }
    }

    private func pointerMoved() {
        guard hoverPoll == nil, !state.expanded, nearNotch(pointer()) else { return }
        hoverTick()
    }

    private func nearNotch(_ p: NSPoint) -> Bool {
        p.y >= top - 60 && p.y <= top + 1 && abs(p.x - centerX) <= hoverZone.width / 2 + 60
    }

    func toggle() {
        if state.expanded {
            collapse()
            return
        }
        let fromMemory: Bool
        if case .memory = state.mode { fromMemory = true } else { fromMemory = false }
        expand(focus: true)
        if fromMemory, !state.usageOpen { toggleUsage() }
    }

    private func memoryAlertChanged(_ alert: MemoryAlert?) {
        state.memorySimulated = alert != nil && model.memoryAlertSimulated
        guard let alert else {
            withAnimation(IslandView.spring) { state.memoryAlert = nil }
            updateFrame()
            frontChanged()
            return
        }
        let fresh = state.memoryAlert == nil || state.memoryAlert?.level != alert.level
        if !state.expanded {
            growCollapsed(for: state.board, memory: alert)
            withAnimation(fresh ? Self.arrival : IslandView.spring) { state.memoryAlert = alert }
        } else {
            withAnimation(IslandView.spring) { state.memoryAlert = alert }
        }
        if fresh {
            if frontID == "memory" { frontID = nil }
            frontChanged()
        }
    }

    func simulateFinished(_ session: Session) {
        guard !state.expanded else { return }
        state.forcedFinished.insert(session.id)
        sessionFinished(session)
    }

    func blockedArrived(_ session: Session, rule: String, command: String) {
        rebuild()
        let alert = BlockedAlert(session: session, rule: rule, command: command, simulated: model.simulating)
        if state.expanded {
            withAnimation(IslandView.spring) { state.blocked.insert(alert, at: 0) }
            return
        }
        growCollapsed(for: state.board, blocked: [alert] + state.blocked)
        withAnimation(Self.arrival) { state.blocked.insert(alert, at: 0) }
        frontChanged()
    }

    static let arrival = Animation.spring(response: 0.38, dampingFraction: 0.72)

    private func frontChanged() {
        let front = state.stack.first
        guard front?.id != frontID else { return }
        frontID = front?.id
        frontWork?.cancel()
        if let front, let dwell = front.dwell { scheduleFront(front, after: dwell) }
    }

    private func scheduleFront(_ item: AlertItem, after delay: TimeInterval) {
        frontWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.state.stack.first?.id == item.id else { return }
                if self.state.expanded || self.alertRect.contains(self.pointer()) {
                    self.scheduleFront(item, after: 1)
                } else {
                    self.dismiss(item, auto: true)
                }
            }
        }
        frontWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func dismiss(_ item: AlertItem, auto: Bool = false) {
        withAnimation(IslandView.spring) {
            switch item {
            case .approval: break
            case .memory: state.memoryAlert = nil
            case .blocked(let b):
                state.blocked.removeAll { $0.id == b.id }
                if state.blocked.isEmpty { model.dismissBlocked() }
            case .finished(let f):
                state.finished.removeAll { $0 == f.id }
                state.forcedFinished.remove(f.id)
            }
        }
        if case .memory = item { model.dismissMemoryAlert() }
        if auto { remember(item) }
        updateFrame()
        frontChanged()
    }

    private func remember(_ item: AlertItem) {
        switch item {
        case .approval:
            break
        case .finished(let f):
            let s = f.session
            let detail = s.detail ?? s.lastMessage.map(ToolSummary.firstLine)
            model.addMissed(MissedItem(kind: .finished, sessionID: s.id,
                                       text: "\(s.chipName) finished" + (detail.map { " · " + ToolSummary.clip($0, 60) } ?? "")))
        case .memory(let m):
            let session = m.top.first.flatMap { e in state.board.items.first { $0.session.pid == e.sessionPID } }?.session
            let title = m.level == .critical ? "Memory almost full" : "Memory running low"
            model.addMissed(MissedItem(kind: .memory, sessionID: session?.id, text: "\(title) · \(MemoryPill.figures(m))"))
        case .blocked(let b):
            model.addMissed(MissedItem(kind: .blocked, sessionID: b.session.id,
                                       text: "Blocked \(ToolSummary.clip(ToolSummary.firstLine(b.command), 48)) · \(b.session.chipName)"))
        }
    }

    private func missedAction(_ m: MissedItem) {
        model.removeMissed(m.id)
        guard let id = m.sessionID, let s = model.session(withID: id) else { return }
        switch m.kind {
        case .finished, .memory:
            model.jump(to: s)
            collapse()
        case .blocked:
            withAnimation(IslandView.spring) { state.highlightSessionID = id }
        }
    }

    func sessionFinished(_ session: Session) {
        guard prefs.notifyFinished, !state.expanded else { return }
        rebuild()
        var next = state.finished.filter { $0 != session.id }
        next.append(session.id)
        guard !NotchState.finishedItems(board: state.board, ids: next, forced: state.forcedFinished).isEmpty else { return }
        growCollapsed(for: state.board, finished: next)
        let showsNow = state.board.requests.isEmpty
        withAnimation(Self.arrival) {
            state.finished = next
            if showsNow { state.glowKey = UUID() }
        }
        frontChanged()
    }

    private func dismissFinished() {
        if let front = state.stack.first, case .finished = front { dismiss(front) }
    }

    private func openFinished(_ session: Session) {
        model.jump(to: session)
        let rest = state.finished.filter { $0 != session.id }
        withAnimation(IslandView.spring) {
            state.finished = rest
            state.forcedFinished.remove(session.id)
        }
        rebuild()
        updateFrame()
        frontChanged()
    }

    func requestAdded(_ item: RequestItem) {
        if prefs.autoOpen && !state.expanded { expand(focus: false) }
    }

    func statusChanged(_ session: Session, _ status: DisplayStatus) {
        guard status == .question, prefs.autoOpen, !state.expanded, state.board.requests.isEmpty else { return }
        expand(focus: false, closeAfter: 5)
    }

    func expand(focus: Bool, closeAfter: TimeInterval? = nil) {
        autoCloseWork?.cancel()
        panel.allowsKey = true
        if focus { panel.makeKeyAndOrderFront(nil) }
        guard !state.expanded else { return }
        state.hooks = hooks.status()
        refreshMemory()
        mouseWasInside = mouseInside()
        leaveWork?.cancel()
        leaveWork = nil
        preGrow()
        dwellStart = nil
        frontWork?.cancel()
        frontID = nil
        for item in state.stack {
            switch item {
            case .finished, .blocked: remember(item)
            default: break
            }
        }
        withAnimation(IslandView.spring) {
            state.expanded = true
            state.stackHovered = false
            state.blocked = []
            state.finished = []
            state.forcedFinished = []
        }
        updateFrame()
        installMonitors()
        if let closeAfter {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.mouseWasInside, self.state.board.requests.isEmpty else { return }
                    self.collapse()
                }
            }
            autoCloseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + closeAfter, execute: work)
        }
    }

    func collapse() {
        guard state.expanded else { return }
        reopenAfter = Date().addingTimeInterval(0.4)
        leaveWork?.cancel()
        leaveWork = nil
        autoCloseWork?.cancel()
        removeMonitors()
        panel.allowsKey = false
        if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        if state.usageOpen { model.setUsageVisible(false) }
        if state.memoryAlert != nil {
            state.memoryAlert = nil
            model.dismissMemoryAlert()
        }
        withAnimation(IslandView.spring) {
            state.highlightSessionID = nil
            state.expanded = false
            state.usageOpen = false
            state.naming = nil
            state.dropTarget = nil
        }
        updateFrame()
        hoverTick()
    }

    #if DEBUG
    var traceWindow: NSWindow { panel }
    var traceHost: NSView? { hosting }
    var traceCenter: NSPoint { NSPoint(x: centerX, y: top - state.metrics.height / 2) }
    func traceHover(_ inside: Bool) { hoverChanged(inside) }
    #endif

    private func hoverChanged(_ inside: Bool) {
        if state.expanded {
            if !inside { mouseMoved() }
            return
        }
        if !state.stack.isEmpty {
            let fan = inside && state.stack.count > 1
            if fan != state.stackHovered { withAnimation(IslandView.spring) { state.stackHovered = fan } }
        } else if state.stackHovered {
            state.stackHovered = false
        }
        if inside { hoverTick() }
    }

    private func setHoverPoll(_ on: Bool) {
        if !on {
            hoverPoll?.invalidate()
            hoverPoll = nil
            return
        }
        guard hoverPoll == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.hoverTick() }
        }
        t.tolerance = 0.02
        RunLoop.main.add(t, forMode: .common)
        hoverPoll = t
    }

    private var hoverZone: NSRect {
        let base = IslandLayout.of(state.board.isEmpty ? .empty : .ears, metrics: state.metrics, board: state.board)
        let w = max(base.width, state.metrics.hasNotch ? state.metrics.notchWidth : 0)
        let h = max(base.height, state.metrics.height)
        return NSRect(x: centerX - w / 2 - 8, y: top - h - 6, width: w + 16, height: h + 6)
    }

    private func inHoverZone(_ p: NSPoint) -> Bool {
        let z = hoverZone
        return p.x >= z.minX && p.x <= z.maxX && p.y >= z.minY && p.y <= z.maxY + 1
    }

    private func hoverTick() {
        let p = pointer()
        setHoverPoll(!state.expanded && (nearNotch(p) || dwellStart != nil))
        let hit = inHoverZone(p)
        let now = Date()
        let reason: String
        if state.expanded {
            dwellStart = nil
            reason = "open"
        } else if !hit {
            dwellStart = nil
            reason = "outside zone"
        } else if !prefs.openOnHover {
            dwellStart = nil
            reason = "hover off in settings"
        } else if !(state.mode == .ears || state.mode == .empty) {
            dwellStart = nil
            reason = "pill showing"
        } else if now < reopenAfter {
            dwellStart = nil
            reason = "just closed"
        } else if let start = dwellStart, now.timeIntervalSince(start) >= 0.18 {
            dwellStart = nil
            reason = "opening"
            expand(focus: false)
        } else {
            if dwellStart == nil { dwellStart = now }
            reason = String(format: "dwell %.2f", now.timeIntervalSince(dwellStart ?? now))
        }
        hoverLog?(String(format: "tick x=%.0f y=%.0f top=%.0f zone=%@ state=%@ %@", p.x, p.y, top, hit ? "hit" : "miss",
                         state.expanded ? "open" : (state.mode == .ears || state.mode == .empty ? "closed" : "pill"), reason))
    }

    private func wireActions() {
        state.actions = NotchActions(
            toggle: { [weak self] in self?.toggle() },
            expand: { [weak self] in self?.expand(focus: true) },
            decide: { [weak self] id, d in self?.model.decide(id, d) },
            openTerminal: { [weak self] s in self?.model.jump(to: s) },
            open: { [weak self] s in
                self?.model.jump(to: s)
                self?.collapse()
            },
            installHooks: { [weak self] in self?.installHooks() },
            showMenu: { [weak self] in self?.showMenu() },
            cardAppeared: { [weak self] id in self?.shownAt[id] = Date() },
            isArmed: { [weak self] id in self?.isArmed(id) ?? false },
            contentHeight: { [weak self] h in self?.contentHeightChanged(h) },
            toggleUsage: { [weak self] in self?.toggleUsage() },
            finishedOpen: { [weak self] s in self?.openFinished(s) },
            finishedLater: { [weak self] in self?.dismissFinished() },
            memoryOpen: { [weak self] s in
                self?.model.dismissMemoryAlert()
                self?.model.jump(to: s)
            },
            memoryStop: { [weak self] pid in self?.model.stopProcess(pid) },
            memoryDismiss: { [weak self] in self?.model.dismissMemoryAlert() },
            blockedDetails: { [weak self] b in
                guard let self else { return }
                self.dismiss(.blocked(b))
                self.state.highlightSessionID = b.session.id
                self.expand(focus: true)
            },
            blockedDismiss: { [weak self] id in
                guard let self, let b = self.state.blocked.first(where: { $0.id == id }) else { return }
                self.dismiss(.blocked(b))
            },
            missedAction: { [weak self] m in self?.missedAction(m) },
            missedClear: { [weak self] in self?.model.clearMissed() },
            fixAutomation: { [weak self] in self?.model.openAutomationSettings() },
            dismissJumpProblem: { [weak self] in self?.model.dismissJumpProblem() },
            prefetchUsage: { [weak self] in self?.refreshMemory() },
            groupTogether: { [weak self] a, b in self?.groupTogether(a, b) },
            moveToGroup: { [weak self] id, g in
                guard let self, let s = self.model.session(withID: id) else { return }
                self.model.move(s, to: g)
                self.dragging = false
            },
            startNaming: { [weak self] id in self?.startNaming(id) },
            deleteGroup: { [weak self] id in
                self?.model.deleteGroup(id)
                if self?.state.naming == id { self?.state.naming = nil }
            },
            toggleGroup: { [weak self] id in
                self?.animatePanel { self?.model.toggleGroup(id) }
            },
            renameGroup: { [weak self] id, name in self?.model.renameGroup(id, name) },
            recolorGroup: { [weak self] id, c in self?.model.recolorGroup(id, c) },
            finishNaming: { [weak self] in
                self?.animatePanel { self?.state.naming = nil }
            },
            dragStarted: { [weak self] in self?.dragging = true })
    }

    private func groupTogether(_ draggedID: String, _ targetID: String) {
        dragging = false
        guard let d = model.session(withID: draggedID), let t = model.session(withID: targetID) else { return }
        let fresh = model.group(for: t) == nil
        guard let id = model.groupTogether(d, onto: t), fresh else { return }
        startNaming(id, isNew: true)
    }

    private func startNaming(_ id: UUID, isNew: Bool = false) {
        state.namingIsNew = isNew
        panel.allowsKey = true
        panel.makeKey()
        animatePanel { state.naming = id }
    }

    private func toggleUsage() {
        let on = !state.usageOpen
        model.setUsageVisible(on)
        animatePanel { state.usageOpen = on }
    }

    private func animatePanel(_ change: () -> Void) {
        if state.expanded { preGrow() }
        withAnimation(IslandView.spring, change)
    }

    private func growCollapsed(for board: Board, finished: [String]? = nil, memory: MemoryAlert? = nil, blocked: [BlockedAlert]? = nil) {
        shrinkWork?.cancel()
        let mode = NotchState.collapsedMode(board: board, finished: finished ?? state.finished, forced: state.forcedFinished,
                                            memory: memory ?? state.memoryAlert, blocked: blocked ?? state.blocked)
        let l = IslandLayout.of(mode, metrics: state.metrics, board: board)
        let pad = l.shadow ? Self.islandPad : .zero
        let extra = l.shadow ? IslandLayout.stackExtra : 0
        resize(to: panel.frame.union(centered(width: l.width + 2 * pad.width, height: l.height + extra + pad.height)))
    }

    private func preGrow() {
        shrinkWork?.cancel()
        let island = state.metrics.hasNotch ? state.metrics.height : IslandLayout.approvalHeight
        let h = island + IslandLayout.panelGap + maxPanelHeight + Self.panelPad.height
        let big = centered(width: IslandLayout.panelWidth + 2 * Self.panelPad.width, height: h)
        resize(to: panel.frame.union(big))
    }

    private func resize(to f: NSRect) {
        guard f != panel.frame else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panel.setFrame(f, display: false)
        hosting?.layoutSubtreeIfNeeded()
        CATransaction.commit()
        CATransaction.flush()
    }

    private func refreshMemory() {
        guard Date().timeIntervalSince(sampledAt) > 2 else { return }
        sampledAt = Date()
        let sampler = self.sampler
        let pids = state.board.items.map(\.session.pid).filter { $0 > 0 }
        DispatchQueue.global(qos: .utility).async {
            let s = sampler.sample(claudePIDs: pids)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.memory = MemoryLine(used: s.ramUsed, total: s.ramTotal)
                    self?.prefetched = UsageInfo(s)
                    self?.rebuild()
                }
            }
        }
    }

    private func isArmed(_ id: UUID) -> Bool {
        guard let t = shownAt[id] else { return false }
        return Date().timeIntervalSince(t) >= 0.4
    }

    private func scheduleRebuild() {
        guard !rebuildPending else { return }
        rebuildPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.rebuildPending = false
                self?.rebuild()
            }
        }
    }

    private func rebuild() {
        var board = Board(sessions: model.sessions, requests: model.requests, groups: model.groups,
                          now: model.now, stallAfter: model.stallAfter)
        board.usage = model.usage.map(UsageInfo.init) ?? prefetched
        board.memory = memory
        if model.missed != state.missed { animatePanel { state.missed = model.missed } }
        guard board != state.board else { return }
        let old = state.board
        if Self.structure(old) != Self.structure(board) {
            if !state.expanded { growCollapsed(for: board) }
            animatePanel { state.board = board }
        } else if state.usageOpen, old.usage != board.usage {
            withAnimation(.easeOut(duration: 0.35)) { state.board = board }
        } else {
            state.board = board
        }
        let live = Set(board.requests.map(\.id))
        shownAt = shownAt.filter { live.contains($0.key) }
        if let n = state.naming, board.group(n) == nil { state.naming = nil }
        if !state.finished.isEmpty {
            let alive = Set(NotchState.finishedItems(board: board, ids: state.finished, forced: state.forcedFinished).map(\.id))
            let kept = state.finished.filter { alive.contains($0) }
            if kept != state.finished {
                withAnimation(IslandView.spring) { state.finished = kept }
                updateFrame()
            }
        }
        if state.expanded, !old.requests.isEmpty, board.requests.isEmpty, !mouseInside() { scheduleLeave() }
        if old.items.count != board.items.count || old.requests.isEmpty != board.requests.isEmpty { updateFrame() }
        if !state.expanded { frontChanged() }
    }

    private static func structure(_ b: Board) -> [String] {
        b.sections.map { s in "\(s.id)|\(s.group?.collapsed ?? false)|" + s.items.map(\.id).joined(separator: ",") }
            + b.requests.map(\.id.uuidString)
    }

    private func contentHeightChanged(_ h: CGFloat) {
        guard state.expanded, h > 0, abs((state.contentHeight ?? 0) - h) > 0.5 else { return }
        state.contentHeight = h
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.updateFrame() }
        }
    }

    private func relayout(_ choice: ScreenChoice? = nil) {
        guard let screen = Self.pickScreen(choice ?? prefs.screen) else {
            panel.orderOut(nil)
            return
        }
        let (m, cx) = NotchMetrics.of(screen)
        centerX = cx
        top = screen.frame.maxY
        maxPanelHeight = min(760, (screen.visibleFrame.height * 0.85).rounded())
        if m != state.metrics { state.metrics = m }
        updateFrame(immediate: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
        if !proximityMonitors.isEmpty { hoverTick() }
    }

    static func pickScreen(_ choice: ScreenChoice) -> NSScreen? {
        switch choice {
        case .automatic: return NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
        case .main: return NSScreen.screens.first
        }
    }

    private var islandRect: NSRect {
        let l = state.layout
        return NSRect(x: centerX - l.width / 2, y: top - l.height, width: l.width, height: l.height)
    }

    private var cardRect: NSRect? {
        guard state.expanded else { return nil }
        let h = state.contentHeight ?? maxPanelHeight
        let w = IslandLayout.panelWidth
        return NSRect(x: centerX - w / 2, y: top - state.layout.height - IslandLayout.panelGap - h, width: w, height: h)
    }

    private func mouseInside() -> Bool {
        let p = pointer()
        let r = cardRect.map { islandRect.union($0) } ?? islandRect
        return r.insetBy(dx: -2, dy: -2).contains(p)
    }

    private func desiredFrame() -> NSRect {
        let l = state.layout
        if state.expanded {
            let h = l.height + IslandLayout.panelGap + min(maxPanelHeight, state.contentHeight ?? maxPanelHeight)
            return centered(width: max(l.width, IslandLayout.panelWidth) + 2 * Self.panelPad.width, height: h + Self.panelPad.height)
        }
        let pad = l.shadow ? Self.islandPad : .zero
        let extra = l.shadow ? IslandLayout.stackExtra : 0
        return centered(width: l.width + 2 * pad.width, height: l.height + extra + pad.height)
    }

    private var alertRect: NSRect {
        let r = islandRect
        let n = min(IslandLayout.stackDepth, max(0, state.stack.count - 1))
        let extra = CGFloat(n) * IslandLayout.stackFan + (state.stack.count > IslandLayout.stackDepth + 1 ? 16 : 0)
        return NSRect(x: r.minX, y: r.minY - extra, width: r.width, height: r.height + extra)
    }

    private func centered(width: CGFloat, height: CGFloat) -> NSRect {
        let x = (centerX - width / 2).rounded(.down)
        let h = height.rounded(.up)
        return NSRect(x: x, y: top - h, width: 2 * (centerX - x), height: h)
    }

    private func updateFrame(immediate: Bool = false) {
        shrinkWork?.cancel()
        let target = desiredFrame()
        let current = panel.frame
        if immediate || !panel.isVisible {
            panel.setFrame(target, display: true)
            return
        }
        let grown = current.union(target)
        resize(to: grown)
        guard grown != target else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.resize(to: self.desiredFrame())
            }
        }
        shrinkWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedElsewhere() }
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseUp], handler: { [weak self] e in
            let up = e.type == .leftMouseUp
            MainActor.assumeIsolated { up ? self?.mouseUp() : self?.mouseMoved() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .leftMouseUp, .keyDown], handler: { [weak self] e in
            let consumed = MainActor.assumeIsolated { self?.consumes(e) ?? false }
            return consumed ? nil : e
        }) { monitors.append(m) }
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    private func clickedElsewhere() {
        #if DEBUG
        if MotionTrace.enabled { return }
        #endif
        guard !menuOpen, !dragging, !mouseInside() else { return }
        if state.expanded { collapse() }
    }

    private func mouseUp() {
        guard dragging else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.dragging = false }
        }
    }

    private func consumes(_ e: NSEvent) -> Bool {
        switch e.type {
        case .mouseMoved:
            mouseMoved()
        case .leftMouseUp:
            mouseUp()
        case .leftMouseDown, .rightMouseDown:
            if e.window === panel, !mouseInside() {
                collapse()
                return true
            }
        case .keyDown:
            return e.window === panel && handleKey(e)
        default:
            break
        }
        return false
    }

    private func mouseMoved() {
        let inside = mouseInside()
        guard state.expanded else { return }
        if inside {
            mouseWasInside = true
            autoCloseWork?.cancel()
            leaveWork?.cancel()
            leaveWork = nil
        } else if mouseWasInside {
            scheduleLeave()
        }
    }

    private func scheduleLeave() {
        guard leaveWork == nil, state.expanded, !menuOpen, !dragging, state.naming == nil, state.board.requests.isEmpty,
              !panel.isKeyWindow else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.leaveWork = nil
                if !self.mouseInside(), !self.menuOpen, !self.dragging, self.state.naming == nil, self.state.board.requests.isEmpty,
                   !self.panel.isKeyWindow {
                    self.collapse()
                }
            }
        }
        leaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        guard state.expanded else { return false }
        let key = Int(e.keyCode)
        if key == kVK_Escape {
            if state.naming != nil {
                state.actions.finishNaming()
            } else {
                collapse()
            }
            return true
        }
        guard state.naming == nil, e.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) else { return false }
        if key == kVK_Return || key == kVK_ANSI_KeypadEnter {
            decideTop(.allow)
            return true
        }
        if key == kVK_Delete || key == kVK_ForwardDelete {
            decideTop(.deny)
            return true
        }
        return false
    }

    private func decideTop(_ d: Decision) {
        guard let r = state.board.requests.first, isArmed(r.id) else { return }
        model.decide(r.id, d)
    }

    private func installHooks() {
        do {
            try hooks.install()
        } catch {
            Self.alert(error)
        }
        let next = hooks.status()
        animatePanel { state.hooks = next }
    }

    private func uninstallHooks() {
        do {
            try hooks.uninstall()
        } catch {
            Self.alert(error)
        }
        state.hooks = hooks.status()
    }

    private static func alert(_ error: Error) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Could not update ~/.claude/settings.json"
        a.informativeText = error.localizedDescription
        a.runModal()
    }

    private func rightClick(at p: NSPoint) -> Bool {
        guard islandRect.contains(p) else { return false }
        showMenu()
        return true
    }

    func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionItem("Settings…") { [weak self] in
            self?.collapse()
            self?.onOpenSettings?()
        })
        menu.addItem(.separator())
        let hookState = hooks.status()
        let header = NSMenuItem(title: Self.hookText(hookState), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if !hookState.isActive {
            menu.addItem(ActionItem(hookState == .outdated ? "Reinstall Hooks" : "Install Hooks") { [weak self] in self?.installHooks() })
        }
        if hookState == .installed || hookState == .outdated {
            menu.addItem(ActionItem("Uninstall Hooks") { [weak self] in self?.uninstallHooks() })
        }
        menu.addItem(.separator())
        let login = ActionItem("Launch at Login") {
            try? LoginItem.setEnabled(!LoginItem.isEnabled)
        }
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(ActionItem("Quit Earshot") { NSApp.terminate(nil) })

        menuOpen = true
        leaveWork?.cancel()
        leaveWork = nil
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        menuOpen = false
        if state.expanded, !mouseInside(), state.board.requests.isEmpty, mouseWasInside { scheduleLeave() }
    }

    private static func hookText(_ s: HookInstallState) -> String {
        switch s {
        case .installed: return "Hooks installed"
        case .viaPlugin: return "Hooks: via Claude Code plugin"
        case .notInstalled: return "Hooks not installed"
        case .outdated: return "Hooks point to another copy"
        }
    }
}

final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func fire() { handler() }
}

#if DEBUG
extension NotchController {
    enum TraceKind { case hover, panel, approval, finished, stack }

    func runTrace(_ kind: TraceKind, inject: @escaping @MainActor (String) -> Void) {
        MotionTrace.enabled = true
        var inside = false
        var topRow = false
        pointer = { [weak self] in
            guard let self else { return .zero }
            if !inside { return NSPoint(x: -10_000, y: -10_000) }
            return topRow ? NSPoint(x: self.traceCenter.x + 40, y: self.top) : NSPoint(x: self.traceCenter.x, y: self.traceCenter.y)
        }
        var lastLine = ""
        let sampler = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let host = self.traceHost else { return }
                let f = self.traceWindow.frame
                let sparks = MotionTrace.sparks(in: host)
                let line = "win=\(Int(f.width))x\(Int(f.height)) shapes=[\(MotionTrace.shapeLayers(host))] layers=\(MotionTrace.layerCount(host)) card=[\(MotionTrace.glass(host))] open=\(self.state.expanded) requests=\(self.state.board.requests.count) stack=\(self.state.stack.map(\.id.first!).map(String.init).joined()) fan=\(self.state.stackHovered) nsSparks=\(sparks.count)"
                if line != lastLine {
                    MotionTrace.log(line)
                    lastLine = line
                }
            }
        }
        if ProcessInfo.processInfo.environment["TRACE_QUIET"] == nil { RunLoop.main.add(sampler, forMode: .common) }
        func at(_ t: Double, _ label: String, _ body: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                MainActor.assumeIsolated {
                    MotionTrace.log("--- \(label) cpu=\(String(format: "%.3f", MotionTrace.cpuSeconds()))s")
                    body()
                }
            }
        }
        func finish(_ t: Double) {
            at(t, "done") {
                sampler.invalidate()
                exit(0)
            }
        }
        if ProcessInfo.processInfo.environment["TRACE_GLASS"] != nil { state.glass = true }
        switch kind {
        case .panel:
            at(1.0, "click open #1") { self.state.actions.toggle() }
            at(2.6, "click close #1") { self.state.actions.toggle() }
            at(3.5, "click open #2") { self.state.actions.toggle() }
            at(4.5, "collapse group") {
                if let g = self.state.board.sections.first(where: { $0.group != nil })?.group { self.state.actions.toggleGroup(g.id) }
            }
            at(5.5, "expand group") {
                if let g = self.state.board.sections.first(where: { $0.group?.collapsed == true })?.group { self.state.actions.toggleGroup(g.id) }
            }
            at(6.5, "click close #2") { self.state.actions.toggle() }
            finish(7.9)
        case .hover:
            hoverLog = { MotionTrace.log($0) }
            at(1.0, "rest on the top pixel row") {
                inside = true
                topRow = true
            }
            at(2.4, "leave") {
                inside = false
                topRow = false
                self.traceHover(false)
            }
            at(3.4, "rest in the notch, no enter event") { inside = true }
            at(4.6, "close with Esc while still inside") { self.collapse() }
            at(6.2, "leave") {
                inside = false
                self.traceHover(false)
            }
            finish(7.4)
        case .approval:
            at(1.0, "request") { inject("request") }
            at(2.4, "second request") { inject("request") }
            at(3.4, "allow first") {
                if let r = self.state.board.requests.first { self.state.actions.decide(r.id, .allow) }
            }
            at(4.6, "allow second") {
                if let r = self.state.board.requests.first { self.state.actions.decide(r.id, .allow) }
            }
            finish(6.0)
        case .stack:
            at(1.0, "burst") { inject("sim:burst") }
            at(2.6, "hover enter") {
                inside = true
                self.traceHover(true)
            }
            at(3.4, "hover leave") {
                inside = false
                self.traceHover(false)
            }
            at(4.0, "deny approval") {
                if case .approval(let r) = self.state.mode { self.state.actions.decide(r.id, .deny) }
            }
            at(5.2, "ok blocked") {
                if case .blocked(let b) = self.state.mode { self.state.actions.blockedDismiss(b.id) }
            }
            at(6.4, "later finished") { self.state.actions.finishedLater() }
            at(7.6, "dismiss memory") { self.state.actions.memoryDismiss() }
            finish(9.0)
        case .finished:
            at(2.6, "finish auth") { inject("stop:auth") }
            at(4.0, "finish infra") { inject("stop:infra") }
            at(5.4, "later") { self.state.actions.finishedLater() }
            at(6.6, "finish auth again") { inject("prompt:auth") }
            at(6.7, "finish auth again") { inject("stop:auth") }
            at(9.5, "open") {
                if case .finished(let info, _) = self.state.mode { self.state.actions.finishedOpen(info.session) }
            }
            finish(11.0)
        }
    }
}
#endif
