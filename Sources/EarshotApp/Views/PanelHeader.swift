import SwiftUI

struct PanelHeader: View {
    var count: Int
    var needsYou: Int

    var body: some View {
        HStack {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Sessions").font(.system(size: 13, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            Spacer()
            if needsYou > 0 {
                Text("\(needsYou) needs you")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.clayLabel)
            }
        }
        .padding(.top, 4)
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 30)
    }
}

struct PanelFooter: View {
    var memory: String
    var usageOpen: Bool
    var toggleUsage: () -> Void
    var prefetch: () -> Void
    var showMenu: () -> Void

    var body: some View {
        HStack {
            FooterButton(active: usageOpen, action: toggleUsage) {
                HStack(spacing: 7) {
                    ChipIcon()
                        .stroke(Color.white.opacity(usageOpen ? 1 : 0.75), style: StrokeStyle(lineWidth: 1.9 * 13 / 24, lineCap: .round))
                        .frame(width: 13, height: 13)
                    Text(memory)
                        .font(.system(size: 11.5).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(usageOpen ? 1 : 0.75))
                    Image(systemName: usageOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.white.opacity(usageOpen ? 1 : 0.6))
                }
                .padding(.horizontal, 9)
            }
            .help("Memory and CPU")
            .onHover { if $0 { prefetch() } }
            Spacer()
            FooterButton(active: false, action: showMenu) {
                GearIcon()
                    .stroke(Color.white.opacity(0.65), style: StrokeStyle(lineWidth: 1.9 * 14 / 24, lineCap: .round, lineJoin: .round))
                    .frame(width: 14, height: 14)
                    .frame(width: 26)
            }
            .help("Settings")
        }
        .padding(.horizontal, 2)
        .padding(.top, usageOpen ? 4 : 2)
        .frame(height: usageOpen ? 34 : 32)
    }
}

private struct FooterButton<Label: View>: View {
    var active: Bool
    var action: () -> Void
    @ViewBuilder var label: Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            label
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(active ? (hover ? 0.16 : 0.1) : (hover ? 0.1 : 0))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct ChipIcon: Shape {
    func path(in r: CGRect) -> Path {
        let k = r.width / 24
        var p = Path()
        p.addRoundedRect(in: CGRect(x: r.minX + 6 * k, y: r.minY + 6 * k, width: 12 * k, height: 12 * k), cornerSize: CGSize(width: 2 * k, height: 2 * k))
        for v in [9.0, 15.0] {
            p.move(to: CGPoint(x: r.minX + v * k, y: r.minY + 2 * k)); p.addLine(to: CGPoint(x: r.minX + v * k, y: r.minY + 5 * k))
            p.move(to: CGPoint(x: r.minX + v * k, y: r.minY + 19 * k)); p.addLine(to: CGPoint(x: r.minX + v * k, y: r.minY + 22 * k))
            p.move(to: CGPoint(x: r.minX + 2 * k, y: r.minY + v * k)); p.addLine(to: CGPoint(x: r.minX + 5 * k, y: r.minY + v * k))
            p.move(to: CGPoint(x: r.minX + 19 * k, y: r.minY + v * k)); p.addLine(to: CGPoint(x: r.minX + 22 * k, y: r.minY + v * k))
        }
        return p
    }
}

struct GearIcon: Shape {
    func path(in r: CGRect) -> Path {
        let k = r.width / 24
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: r.minX + x * k, y: r.minY + y * k) }
        var p = Path()
        p.addEllipse(in: CGRect(x: r.minX + 9 * k, y: r.minY + 9 * k, width: 6 * k, height: 6 * k))
        let spokes: [(Double, Double, Double, Double)] = [(12, 2, 12, 5), (12, 19, 12, 22), (4.9, 4.9, 7, 7), (17, 17, 19.1, 19.1),
                                                          (2, 12, 5, 12), (19, 12, 22, 12), (4.9, 19.1, 7, 17), (17, 7, 19.1, 4.9)]
        for s in spokes {
            p.move(to: pt(s.0, s.1))
            p.addLine(to: pt(s.2, s.3))
        }
        return p
    }
}

struct TerminalIcon: Shape {
    func path(in r: CGRect) -> Path {
        let k = r.width / 24
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 5 * k, y: r.minY + 7 * k))
        p.addLine(to: CGPoint(x: r.minX + 10 * k, y: r.minY + 12 * k))
        p.addLine(to: CGPoint(x: r.minX + 5 * k, y: r.minY + 17 * k))
        p.move(to: CGPoint(x: r.minX + 12 * k, y: r.minY + 18 * k))
        p.addLine(to: CGPoint(x: r.minX + 19 * k, y: r.minY + 18 * k))
        return p
    }
}
