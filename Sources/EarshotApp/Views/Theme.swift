import AppKit
import EarshotCore
import SwiftUI

enum Theme {
    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static let clayOnBlack = rgb(0xD97757)
    static let clayOnGlass = rgb(0xE8957A)
    static let clayLabel = Color(nsColor: rgb(0xFFB38F))
    static let notchWell = Color(nsColor: rgb(0x1C1C1E))

    static let primary = Color.white
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.5)
    static let module = Color.white.opacity(0.08)
    static let well = Color.black.opacity(0.35)
    static let hover = Color.white.opacity(0.08)
    static let ghost = Color.white.opacity(0.14)

    static func group(_ c: GroupColor) -> NSColor {
        switch c {
        case .blue: return rgb(0x0A84FF)
        case .indigo: return rgb(0x5E5CE6)
        case .purple: return rgb(0xBF5AF2)
        case .pink: return rgb(0xFF375F)
        case .teal: return rgb(0x64D2FF)
        case .mint: return rgb(0x30D158)
        case .yellow: return rgb(0xFFD60A)
        case .brown: return rgb(0xAC8E68)
        case .gray: return rgb(0x8E8E93)
        }
    }

    static func groupColor(_ c: GroupColor?) -> Color {
        c.map { Color(nsColor: group($0)) } ?? Color.white.opacity(0.4)
    }

    static func groupTint(_ c: GroupColor) -> Color {
        Color(nsColor: group(c).blended(withFraction: 0.45, of: .white) ?? group(c))
    }

    static func needsYou(_ d: DisplayStatus, unseen: Bool) -> Bool {
        d == .permission || d == .question || d == .error || (d == .waiting && unseen)
    }

    static func labelColor(_ d: DisplayStatus, unseen: Bool) -> Color {
        if needsYou(d, unseen: unseen) { return clayLabel }
        if d == .working || d == .stalled { return Color.white.opacity(0.75) }
        return Color.white.opacity(0.5)
    }

    static let swatches: [GroupColor] = [.blue, .indigo, .purple, .pink, .teal, .mint, .yellow, .gray]
}

struct PillButtonStyle: ButtonStyle {
    enum Kind { case primary, ghost }
    var kind: Kind
    var height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        PillButtonBody(kind: kind, height: height, pressed: configuration.isPressed) { configuration.label }
    }
}

private struct PillButtonBody<Label: View>: View {
    var kind: PillButtonStyle.Kind
    var height: CGFloat
    var pressed: Bool
    @ViewBuilder var label: Label
    @State private var hover = false

    var body: some View {
        label
            .font(.system(size: 12.5, weight: kind == .primary ? .semibold : .medium))
            .foregroundStyle(kind == .primary ? Color.black : Color.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, kind == .primary ? 14 : 12)
            .frame(minWidth: height, minHeight: height, maxHeight: height)
            .background(Capsule().fill(fill))
            .opacity(pressed ? 0.75 : 1)
            .contentShape(Capsule())
            .onHover { hover = $0 }
    }

    private var fill: Color {
        switch kind {
        case .primary: return hover ? Color(white: 0.95) : .white
        case .ghost: return Color.white.opacity(hover ? 0.2 : 0.14)
        }
    }
}

struct GroupCapsule: View {
    var group: SessionGroup
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            Circle().fill(Theme.groupColor(group.color)).frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
            Text(group.name).lineLimit(1)
        }
        .font(.system(size: compact ? 10.5 : 11.5, weight: .semibold))
        .foregroundStyle(Theme.groupTint(group.color))
        .padding(.horizontal, compact ? 7 : 9)
        .frame(height: compact ? 18 : 22)
        .background(Capsule().fill(Theme.groupColor(group.color).opacity(0.28)))
        .fixedSize()
    }
}
