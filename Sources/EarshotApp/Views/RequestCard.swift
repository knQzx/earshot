import EarshotCore
import SwiftUI

struct RequestCard: View {
    var item: RequestItem
    var group: SessionGroup?
    var actions: NotchActions
    @State private var armed = false
    @Environment(\.staticRendering) private var staticRendering

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                SparkBadge(look: SparkLook(color: Theme.clayOnGlass, hop: true, ring: true), size: 28, glyph: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.session.name)
                        .font(.system(size: 13, weight: .semibold))
                    TimelineView(.periodic(from: .now, by: 30)) { ctx in
                        Text("\(Self.intent(item.request)) · \(StatusPhrase.duration(ctx.date.timeIntervalSince(item.request.createdAt)))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.white.opacity(0.6))
                    }
                    if let rule = item.request.policyRule {
                        PolicyLabel(rule: rule)
                    }
                }
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                if item.simulated { SimulatedTag() }
                if let group { GroupCapsule(group: group) }
            }
            CommandWell(description: Self.description(item.request), code: Self.code(item.request))
            if item.simulated {
                HStack {
                    Text("Shown by earshot-hook --simulate, nothing is sent to Claude")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                    Spacer(minLength: 6)
                    Button("Dismiss") { act(.deny) }
                        .buttonStyle(PillButtonStyle(kind: .ghost))
                }
            } else {
            HStack(spacing: 6) {
                Button("Deny") { act(.deny) }
                    .buttonStyle(PillButtonStyle(kind: .ghost))
                if item.request.canAlways {
                    Button("Always") { act(.always) }
                        .buttonStyle(PillButtonStyle(kind: .ghost))
                }
                Button { actions.openTerminal(item.session) } label: {
                    TerminalIcon()
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2.2 * 13 / 24, lineCap: .round, lineJoin: .round))
                        .frame(width: 13, height: 13)
                        .padding(.horizontal, -5)
                }
                .buttonStyle(PillButtonStyle(kind: .ghost))
                .help("Open terminal")
                Spacer(minLength: 6)
                Button { act(.allow) } label: {
                    HStack(spacing: 7) {
                        Text("Allow")
                        Text("⌘↩").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.black.opacity(0.42))
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
            }
            .opacity(armed || staticRendering ? 1 : 0.45)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.module))
        .onAppear {
            actions.cardAppeared(item.id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.easeOut(duration: 0.18)) { armed = true }
            }
        }
    }

    private func act(_ d: Decision) {
        guard actions.isArmed(item.id) else { return }
        actions.decide(item.id, d)
    }

    static func intent(_ r: PendingRequest) -> String {
        let file = { (k: String) in r.toolInput[k]?.string.map { ($0 as NSString).lastPathComponent } }
        switch r.toolName {
        case "Bash": return "Wants to run a command"
        case "Edit", "MultiEdit", "Write": return "Wants to edit \(file("file_path") ?? "a file")"
        case "NotebookEdit": return "Wants to edit \(file("notebook_path") ?? "a notebook")"
        case "Read": return "Wants to read \(file("file_path") ?? "a file")"
        case "WebFetch": return "Wants to fetch \(r.toolInput["url"]?.string.flatMap { URL(string: $0)?.host } ?? "a page")"
        case "WebSearch": return "Wants to search the web"
        case "Task", "Agent": return "Wants to start an agent"
        default:
            if r.toolName.hasPrefix("mcp__") {
                let parts = r.toolName.dropFirst(5).components(separatedBy: "__")
                return "Wants to use \(r.summary.server ?? parts.first ?? "") · \(parts.dropFirst().joined(separator: "__"))"
            }
            return "Wants to use \(r.toolName)"
        }
    }

    static func description(_ r: PendingRequest) -> String? {
        r.toolName == "Bash" ? r.toolInput["description"]?.string : nil
    }

    static func code(_ r: PendingRequest) -> String {
        if r.toolName == "Bash" { return r.toolInput["command"]?.string ?? r.summary.detail }
        return r.summary.detail.isEmpty ? r.summary.short : r.summary.detail
    }
}

struct CommandWell: View {
    var description: String?
    var code: String

    static let maxLines = 6
    static let lineHeight: CGFloat = 18
    static let charsPerLine = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.5))
                    .lineLimit(2)
            }
            let label = Text(code)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Scrollable(height: CGFloat(Self.maxLines) * Self.lineHeight, enabled: estimatedLines > Self.maxLines, indicators: true) { label }
            if estimatedLines > Self.maxLines {
                Text("\(code.split(separator: "\n", omittingEmptySubsequences: false).count) lines, scroll to read all")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.32)))
    }

    private var estimatedLines: Int {
        code.split(separator: "\n", omittingEmptySubsequences: false)
            .reduce(0) { $0 + max(1, ($1.count + Self.charsPerLine - 1) / Self.charsPerLine) }
    }
}

struct PolicyLabel: View {
    var rule: PolicyMatch

    var body: some View {
        Text("Policy · \(rule.label)")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.clayLabel)
            .lineLimit(1)
    }
}
