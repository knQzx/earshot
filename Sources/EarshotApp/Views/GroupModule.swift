import EarshotCore
import SwiftUI

struct GroupModule: View {
    var section: SessionSection
    var showHeader: Bool
    @ObservedObject var state: NotchState

    var body: some View {
        let open = !(section.group?.collapsed ?? false)
        VStack(spacing: 0) {
            if showHeader {
                GroupHeader(section: section, open: open, actions: state.actions)
                    .sessionDrop(state, section.group.map { .group($0.id) } ?? .ungroup)
            }
            if open {
                ForEach(section.items) { item in
                    SessionRow(item: item, dropLabel: dropLabel(for: item), showUsage: state.usageOpen,
                               highlighted: state.memoryAlert?.top.first?.sessionPID == item.session.pid || state.highlightSessionID == item.id,
                               load: state.board.usage?.perSession[item.session.pid], actions: state.actions)
                        .sessionDrop(state, .session(item.id))
                }
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.module))
    }

    private func dropLabel(for item: SessionInfo) -> String? {
        guard state.dropTarget == item.id else { return nil }
        if let g = item.group { return "Add to \(g.name)" }
        return "Create group"
    }
}

struct GroupHeader: View {
    var section: SessionSection
    var open: Bool
    var actions: NotchActions
    @State private var hover = false
    @Environment(\.staticRendering) private var staticRendering

    var body: some View {
        if staticRendering {
            content
        } else {
            content.contextMenu { menu }
        }
    }

    @ViewBuilder private var menu: some View {
        if let g = section.group {
            Button("Rename") { actions.startNaming(g.id) }
            Menu("Color") {
                ForEach(GroupColor.allCases, id: \.self) { c in
                    Button(c.rawValue.capitalized) { actions.recolorGroup(g.id, c) }
                }
            }
            Button(g.collapsed ? "Expand" : "Collapse") { actions.toggleGroup(g.id) }
            Divider()
            Button("Delete Group", role: .destructive) { actions.deleteGroup(g.id) }
        }
    }

    private var content: some View {
        HStack(spacing: 7) {
            Circle().fill(Theme.groupColor(section.group?.color)).frame(width: 7, height: 7)
            Text(section.group?.name ?? "Ungrouped")
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if open {
                Text("\(section.items.count)")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.45))
            } else {
                AvatarStack(items: section.items, onBlack: false, separator: Color(.sRGB, red: 40 / 255, green: 40 / 255, blue: 46 / 255, opacity: 0.9))
                    .padding(.leading, 5)
            }
            Spacer(minLength: 6)
            if let note {
                Text(note.text)
                    .font(.system(size: 11))
                    .foregroundStyle(note.color)
                    .lineLimit(1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.45))
                .rotationEffect(.degrees(open ? 0 : -90))
                .opacity(section.group == nil ? 0 : 1)
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? Color.white.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if let g = section.group { actions.toggleGroup(g.id) } }
    }

    private var note: (text: String, color: Color)? {
        if section.needsYou > 0 { return ("\(section.needsYou) needs you", Theme.clayLabel) }
        if !open, section.items.allSatisfy({ $0.display == .working }) { return ("All working", Color.white.opacity(0.5)) }
        return nil
    }
}
