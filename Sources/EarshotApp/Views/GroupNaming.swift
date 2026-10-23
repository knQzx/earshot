import EarshotCore
import SwiftUI

struct GroupNaming: View {
    var group: SessionGroup
    var isNew: Bool
    var actions: NotchActions
    @State private var name: String
    @FocusState private var focused: Bool
    @Environment(\.staticRendering) private var staticRendering

    init(group: SessionGroup, isNew: Bool, actions: NotchActions) {
        self.group = group
        self.isNew = isNew
        self.actions = actions
        _name = State(initialValue: group.name)
    }

    static let presets: [(String, GroupColor)] = Array(GroupStore.presets.prefix(4))

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isNew ? "New group" : "Rename group")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
                Spacer()
                Button("Done", action: commit)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.75))
            }
            field
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.3)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color(nsColor: Theme.group(.blue)).opacity(0.9), lineWidth: 1.5))
            HStack(spacing: 10) {
                ForEach(Theme.swatches, id: \.self) { c in
                    Button { actions.recolorGroup(group.id, c) } label: {
                        Circle()
                            .fill(Theme.groupColor(c))
                            .frame(width: 22, height: 22)
                            .overlay {
                                if c == group.color {
                                    Circle().strokeBorder(Color.white, lineWidth: 2).padding(-4)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(c.rawValue.capitalized)
                }
            }
            .padding(.leading, 4)
            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.0) { p in
                    Button {
                        name = p.0
                        actions.renameGroup(group.id, p.0)
                        actions.recolorGroup(group.id, p.1)
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(Theme.groupColor(p.1)).frame(width: 6, height: 6)
                            Text(p.0)
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.module))
        .onAppear { focused = true }
    }

    @ViewBuilder private var field: some View {
        if staticRendering {
            Text(name).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("", text: $name)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(commit)
        }
    }

    private func commit() {
        actions.renameGroup(group.id, name)
        actions.finishNaming()
    }
}
