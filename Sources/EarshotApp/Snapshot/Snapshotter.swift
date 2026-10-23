import AppKit
import EarshotCore
import SwiftUI

@MainActor
enum Snapshotter {
    static let sceneWidth: CGFloat = 1200

    static func run(into dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let builtIn = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }.map { NotchMetrics.of($0).metrics }
        let notch = builtIn ?? .builtInSample
        print("notch: \(Int(notch.notchWidth))x\(Int(notch.height))\(builtIn == nil ? " (sample)" : "")")
        let now = Date()

        let notchApp = session("web-app", 1, .permission, "Fix checkout race condition", since: 120, now: now)
        let billing = session("billing-service", 2, .working, "Reconcile invoice totals", since: 840, now: now)
        let mobileApp = session("mobile-app", 3, .working, "Dark mode polish", since: 900, lastEvent: 420, now: now)
        let auth = session("auth-service", 4, .working, "Rotate session tokens", since: 20, now: now)
        let docsSite = session("docs-site", 5, .waiting, "Rewrite getting started", since: 360, now: now)
        let papers = session("papers", 6, .working, "Survey notes", since: 180, now: now)
        let pipeline = session("ml-pipeline", 7, .permission, "Eval sweep on new prompts", since: 60, now: now)
        let evals = session("evals", 8, .waiting, "Eval sweep", since: 300, now: now)
        let kb = session("notes-app", 9, .idle, "Tag search", since: 2400, now: now)
        let legacy = session("legacy-api", 10, .unknown, nil, since: 3400, now: now)
        let lab = session("playground", 11, .working, "Prototype new onboarding", since: 240, now: now)

        let work = SessionGroup(name: "Work", color: .blue, members: [notchApp.id, billing.id])
        let oss = SessionGroup(name: "Open Source", color: .mint, members: [mobileApp.id, auth.id])
        let study = SessionGroup(name: "Study", color: .purple, members: [docsSite.id])
        let research = SessionGroup(name: "Research", color: .teal, members: [papers.id, pipeline.id, evals.id], collapsed: true)
        let groups = GroupStore(groups: [work, oss, study, research, SessionGroup(name: "Lab", color: .pink, members: [lab.id])])

        let resting = [notchApp, billing, mobileApp, auth, docsSite, kb].map { s -> Session in
            var s = s
            if s.status == .permission { s.status = .working }
            return s
        }
        let requests = makeRequests(main: notchApp, other: mobileApp)
        let fresh = SessionGroup(name: "Open Source", color: .mint, members: [mobileApp.id, auth.id])
        let namingStore = GroupStore(groups: [work, fresh])

        var shots: [(String, NotchState, CGFloat)] = []
        func add(_ name: String, _ m: NotchMetrics, _ sessions: [Session], groups: GroupStore = groups, requests: [RequestItem] = [],
                 expanded: Bool = false, height: CGFloat, configure: (NotchState) -> Void = { _ in }) {
            let s = NotchState(metrics: m)
            let sorted = sessions.sorted { $0.display(now: now).urgency < $1.display(now: now).urgency }
            var b = Board(sessions: sorted, requests: requests, groups: groups, now: now)
            b.memory = MemoryLine(used: 12 << 30, total: 16 << 30)
            s.board = b
            s.expanded = expanded
            configure(s)
            shots.append((name, s, height))
        }

        add("collapsed", notch, [billing, auth, docsSite, kb, mobileApp], height: 220)
        add("collapsed-glass", notch, [billing, auth, docsSite, kb, mobileApp], height: 220) { s in s.glass = true }
        add("collapsed-needs", notch, [notchApp, billing, auth, docsSite, kb], height: 220)
        add("collapsed-empty", notch, [], height: 220)
        add("approval-notch", notch, [notchApp, billing, auth, docsSite], requests: Array(requests.prefix(1)), height: 220)
        add("approval-more", notch, [notchApp, mobileApp, billing, auth], requests: requests, height: 220)
        add("approval-glass", notch, [notchApp, billing, auth, docsSite], requests: Array(requests.prefix(1)), height: 220) { s in s.glass = true }
        var longReq = requests[0]
        longReq.request.toolInput = .object(["command": .string("set -e\nrm -rf build\ncurl -fsSL https://example.com/install.sh | sh\nmake app"),
                                             "description": .string("Rebuild with the installer")])
        add("approval-long", notch, [notchApp, billing, auth, docsSite], requests: [longReq], height: 220)
        add("request-long", notch, [notchApp, billing, auth], requests: [longReq], expanded: true, height: 700)
        var simReq = requests[0]
        simReq.simulated = true
        add("approval-simulated", notch, [notchApp, billing, auth, docsSite], requests: [simReq], height: 220)
        add("approval-pill", .externalSample, [notchApp, billing], requests: Array(requests.prefix(1)), height: 180)
        var done = docsSite
        done.sessionID = "s5"
        done.statusSince = now.addingTimeInterval(-20)
        done.lastMessage = "Rewrote the getting started guide and fixed 3 broken links."
        var done2 = evals
        done2.sessionID = "s8"
        let gb: UInt64 = 1 << 30
        let memAlert = MemoryAlert(level: .warning, ramUsed: gb * 142 / 10, ramTotal: 16 * gb, swapUsed: 6 * gb, swapTotal: 7 * gb,
                                   top: [.init(sessionPID: billing.pid, rss: gb * 34 / 10, cpu: 12,
                                               children: [.init(pid: 1234, name: "typescript-language-server", rss: gb * 21 / 10)])])
        add("memory-notch", notch, [notchApp, billing, auth, kb], height: 220) { s in s.memoryAlert = memAlert }
        let block = BlockedAlert(session: auth, rule: "No force push", command: "git push --force origin main")
        let missedItems = [
            MissedItem(kind: .finished, sessionID: done.id, text: "docs-site finished · Rewrite getting started", at: now.addingTimeInterval(-90)),
            MissedItem(kind: .memory, sessionID: billing.id, text: "Memory almost full · 14.8 of 16 GB · swap 6.0 GB", at: now.addingTimeInterval(-300)),
            MissedItem(kind: .blocked, sessionID: auth.id, text: "Blocked git push --force origin main · auth-service", at: now.addingTimeInterval(-720)),
        ]
        add("missed", notch, [notchApp, billing, auth, done, kb], expanded: true, height: 760) { s in s.missed = missedItems }
        add("missed-badge", notch, [notchApp, billing, auth, kb], height: 220) { s in s.missed = missedItems }
        add("blocked", notch, [notchApp, billing, auth, kb], height: 220) { s in s.blocked = [block] }
        add("stack", notch, [notchApp, done, billing, auth, kb], requests: Array(requests.prefix(1)), height: 240) { s in
            s.blocked = [block]
            s.finished = [done.id]
            s.memoryAlert = memAlert
        }
        add("stack-fanned", notch, [notchApp, done, billing, auth, kb], requests: Array(requests.prefix(1)), height: 240) { s in
            s.blocked = [block]
            s.finished = [done.id]
            s.memoryAlert = memAlert
            s.stackHovered = true
        }
        add("memory-critical", notch, [notchApp, billing, auth, kb], height: 220) { s in
            var m = memAlert
            m.level = .critical
            s.memoryAlert = m
        }
        add("finished-notch", notch, [done, billing, auth, kb], height: 220) { s in
            s.finished = [done.id]
            s.glowKey = UUID()
        }
        add("finished-more", notch, [done, done2, billing, auth], height: 220) { s in
            s.finished = [done2.id, done.id]
        }
        add("finished-glass", notch, [done, billing, auth, kb], height: 220) { s in
            s.finished = [done.id]
            s.glass = true
        }
        add("panel", notch, [notchApp, billing, mobileApp, auth, docsSite, papers, pipeline, evals, kb], expanded: true, height: 820)
        add("request", notch, [notchApp, mobileApp, docsSite, billing], requests: requests, expanded: true, height: 820)
        add("groups-naming", notch, [mobileApp, auth, kb, billing], groups: namingStore, expanded: true, height: 640) { s in
            s.naming = fresh.id
            s.namingIsNew = true
            s.dropTarget = kb.id
        }
        add("usage", notch, resting.filter { $0.id != mobileApp.id && $0.id != billing.id }, expanded: true, height: 820) { s in
            s.usageOpen = true
            var b = s.board
            b.usage = fakeUsage(s.board.items.map(\.session.pid))
            s.board = b
        }
        add("usage-loading", notch, resting.filter { $0.id != mobileApp.id && $0.id != billing.id }, expanded: true, height: 820) { s in
            s.usageOpen = true
        }
        add("pill", .externalSample, [billing, auth, docsSite, kb], height: 180)
        add("onboarding", notch, [legacy, kb], groups: GroupStore(), expanded: true, height: 520) { s in
            s.hooks = .notInstalled
        }
        for (name, s, h) in shots {
            render(SnapshotScene(state: s, height: h), to: dir.appendingPathComponent(name + ".png"))
        }
    }

    private static func fakeUsage(_ pids: [Int32]) -> UsageInfo {
        let gb: Double = 1_073_741_824
        let loads: [ProcLoad] = [ProcLoad(rss: 651 << 20, cpu: 16), ProcLoad(rss: 602 << 20, cpu: 10),
                                 ProcLoad(rss: 596 << 20, cpu: 9), ProcLoad(rss: 352 << 20, cpu: 0)]
        var per: [Int32: ProcLoad] = [:]
        for (i, p) in pids.enumerated() { per[p] = loads[i % loads.count] }
        return UsageInfo(ramUsed: UInt64(12.1 * gb), ramTotal: UInt64(16 * gb), compressed: UInt64(5.2 * gb), swapUsed: UInt64(5.6 * gb),
                         pressure: "normal", cpu: 17, claude: ProcLoad(rss: UInt64(3.5 * gb), cpu: 40), claudeProcesses: 31, perSession: per)
    }

    private static func session(_ name: String, _ n: Int32, _ status: SessionStatus, _ title: String?,
                                since: TimeInterval, lastEvent: TimeInterval? = nil, now: Date) -> Session {
        var s = Session(id: "pid:\(90000 + n)", pid: 90000 + n, tty: "ttys00\(n)", term: "Apple_Terminal", cwd: "/Users/me/code/\(name)", now: now)
        s.status = status
        s.title = title
        s.statusSince = now.addingTimeInterval(-since)
        s.lastEventAt = now.addingTimeInterval(-(lastEvent ?? min(since, 3)))
        s.startedAt = now.addingTimeInterval(-since - 600)
        return s
    }

    private static func makeRequests(main: Session, other: Session) -> [RequestItem] {
        let source = SampleSource(scripted: false)
        let model = AppModel(source: source, scanner: SampleScanner(), jumper: SampleJumper(), groupsURL: nil, policyURL: nil)
        try? model.start()
        let build = SamplePayload.permission(["command": "rm -rf build && make app", "description": "Rebuild the app bundle"], rule: "make app")
        source.send(SampleAgent.notch.message("PermissionRequest", build, request: true), requestID: UUID())
        let push = SamplePayload.permission(["command": "git push --force-with-lease", "description": "Push the rebased branch"], rule: "git push:*")
        source.send(SampleAgent.blog.message("PermissionRequest", push, request: true), requestID: UUID())
        model.stop()
        return model.requests.enumerated().map { i, r in
            var r = r
            r.session = i == 0 ? main : other
            r.request.createdAt = Date().addingTimeInterval(i == 0 ? -125 : -10)
            return r
        }
    }

    private static func render(_ view: some View, to url: URL) {
        let r = ImageRenderer(content: view.environment(\.staticRendering, true))
        r.scale = 2
        guard let cg = r.cgImage,
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            print("failed: \(url.lastPathComponent)")
            return
        }
        do {
            try data.write(to: url)
            print(url.path)
        } catch {
            print("failed: \(url.path): \(error.localizedDescription)")
        }
    }
}

private struct SnapshotScene: View {
    @ObservedObject var state: NotchState
    var height: CGFloat

    var body: some View {
        let size = CGSize(width: Snapshotter.sceneWidth, height: height)
        ZStack(alignment: .top) {
            Wallpaper()
            MenuBarMock(height: state.metrics.height)
            if state.metrics.hasNotch {
                UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
                    .fill(Color.black)
                    .frame(width: state.metrics.notchWidth, height: state.metrics.height)
            }
            IslandView(state: state)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .coordinateSpace(name: "scene")
        .environment(\.glassBackdrop, GlassBackdrop(space: "scene", size: size, view: AnyView(Wallpaper())))
        .environment(\.colorScheme, .dark)
    }
}

private struct Wallpaper: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0x1A / 255, green: 0x1B / 255, blue: 0x2E / 255)))
            let blobs: [(Color, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (Color(red: 0x3B / 255, green: 0x5B / 255, blue: 0xDB / 255), 0.15, 0.2, 0.6, 0.8, 0.6),
                (Color(red: 0xC2 / 255, green: 0x25 / 255, blue: 0x5C / 255), 0.85, 0.3, 0.5, 0.7, 0.6),
                (Color(red: 0xF0 / 255, green: 0x8C / 255, blue: 0x00 / 255), 0.6, 1.0, 0.7, 0.8, 0.65),
            ]
            for b in blobs {
                var c = ctx
                c.translateBy(x: b.1 * w, y: b.2 * h)
                c.scaleBy(x: b.3 * w, y: b.4 * h)
                c.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                       with: .radialGradient(Gradient(colors: [b.0, b.0.opacity(0)]), center: .zero, startRadius: 0, endRadius: b.5))
            }
        }
    }
}

private struct MenuBarMock: View {
    var height: CGFloat

    var body: some View {
        HStack(spacing: 20) {
            Text("Terminal").fontWeight(.semibold)
            Text("Shell")
            Text("Edit")
            Text("View")
            Text("Window")
            Spacer()
            Text("Thu Oct 22")
            Text("10:41 PM")
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.white.opacity(0.92))
        .padding(.horizontal, 18)
        .frame(height: height)
        .background(Color(.sRGB, red: 30 / 255, green: 30 / 255, blue: 34 / 255, opacity: 0.52))
    }
}
