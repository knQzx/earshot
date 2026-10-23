import EarshotCore
import SwiftUI

struct SessionRow: View {
    var item: SessionInfo
    var dropLabel: String?
    var showUsage = false
    var highlighted = false
    var load: ProcLoad?
    var actions: NotchActions
    @State private var hover = false

    static let height: CGFloat = 42

    var body: some View {
        HStack(spacing: 10) {
            SparkBadge(look: item.look(onBlack: false), size: 24, glyph: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.session.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(item.session.detail ?? fallbackTitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let dropLabel {
                Text(dropLabel)
                    .font(.system(size: 12, weight: .medium))
            } else {
                ZStack(alignment: .trailing) {
                    PhraseColumn(item: item)
                        .opacity(showUsage ? 0 : 1)
                    UsageColumn(load: load)
                        .opacity(showUsage ? 1 : 0)
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(dropLabel != nil ? Color.white.opacity(0.1) : (highlighted ? Color(nsColor: Theme.clayOnGlass).opacity(0.16) : (hover ? Theme.hover : .clear))))
        .overlay {
            if dropLabel != nil {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.white.opacity(0.35), lineWidth: 1.5)
            } else if highlighted {
                RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color(nsColor: Theme.clayOnGlass).opacity(0.45), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { actions.open(item.session) }
        .modifier(SessionDrag(item: item, started: actions.dragStarted))
    }

    private var fallbackTitle: String {
        item.display == .unknown ? "Restart to see live status" : "No prompt yet"
    }
}

private struct SessionDrag: ViewModifier {
    var item: SessionInfo
    var started: () -> Void
    @Environment(\.staticRendering) private var staticRendering

    func body(content: Content) -> some View {
        if staticRendering {
            content
        } else {
            content.onDrag {
                started()
                return NSItemProvider(object: item.id as NSString)
            } preview: {
                DragPreview(item: item)
            }
        }
    }
}

struct UsageColumn: View {
    var load: ProcLoad?

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(load.map { UsageSampler.bytes($0.rss) } ?? "–")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
            Text(load.map { "\(Int($0.cpu.rounded()))%" } ?? " ")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

struct PhraseColumn: View {
    var item: SessionInfo

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            let p = StatusPhrase.parts(item.session, display: item.display, now: ctx.date)
            VStack(alignment: .trailing, spacing: 1) {
                Text(p.label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.labelColor(item.display, unseen: item.unseen))
                Text(second(p.time))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            .lineLimit(1)
            .frame(maxWidth: 150, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func second(_ time: String?) -> String {
        if let time { return time }
        if item.display == .error, let why = item.session.activity { return ToolSummary.clip(why, 24) }
        return " "
    }
}

private struct DragPreview: View {
    var item: SessionInfo

    var body: some View {
        HStack(spacing: 12) {
            SparkBadge(look: item.look(onBlack: false), size: 30, glyph: 15)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.session.name).font(.system(size: 13.5, weight: .semibold))
                Text(StatusPhrase.text(item.session, display: item.display, now: Date()))
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 10)
        .frame(width: 370, height: 54)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.sRGB, red: 72 / 255, green: 72 / 255, blue: 80 / 255, opacity: 0.92)))
        .environment(\.colorScheme, .dark)
    }
}

struct CompactRow: View {
    var item: SessionInfo
    var open: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.groupColor(item.group?.color)).frame(width: 7, height: 7)
            Text(item.session.name)
                .font(.system(size: 12.5, weight: .semibold))
                .fixedSize()
            TimelineView(.periodic(from: .now, by: 30)) { ctx in
                Text(StatusPhrase.text(item.session, display: item.display, now: ctx.date))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(perform: open)
    }
}
