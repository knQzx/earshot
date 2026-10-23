import EarshotCore
import SwiftUI

struct UsageModule: View {
    var usage: UsageInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                titleRow("Memory", "Pressure: \(usage?.pressure ?? "–")")
                Bar(parts: [(fraction(u.ramUsed > u.compressed ? u.ramUsed - u.compressed : 0), 0.92),
                            (fraction(u.compressed), 0.5)])
                HStack(spacing: 14) {
                    (Text(usage.map { MemoryLine.gb($0.ramUsed) } ?? "–").foregroundColor(.white).fontWeight(.semibold)
                        + Text(" of \(usage.map { MemoryLine.gb($0.ramTotal, round: true) } ?? "–") GB"))
                    Text("compressed \(usage.map { UsageSampler.bytes($0.compressed) } ?? "–")")
                    Text("swap \(usage.map { UsageSampler.bytes($0.swapUsed) } ?? "–")")
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.62))
            }
            VStack(alignment: .leading, spacing: 7) {
                titleRow("CPU", usage.map { "\(Int($0.cpu.rounded()))%" } ?? "–")
                Bar(parts: [(min(1, u.cpu / 100), 0.92)])
            }
            Rectangle().fill(Color.white.opacity(0.16)).frame(height: 0.5)
            HStack(spacing: 10) {
                SparkBadge(look: SparkLook(color: Theme.clayOnGlass), size: 24, glyph: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text("All Claude sessions").font(.system(size: 12.5, weight: .semibold))
                    Text(usage.map { "\($0.claudeProcesses) processes incl. MCP servers and tools" } ?? "Measuring…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(usage.map { UsageSampler.bytes($0.claude.rss) } ?? "–").font(.system(size: 12.5, weight: .semibold))
                    Text(usage.map { "\(Int($0.claude.cpu.rounded()))% CPU" } ?? " ")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
                .monospacedDigit()
            }
        }
        .contentTransition(.numericText())
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.module))
    }

    private var u: UsageInfo {
        usage ?? UsageInfo(ramUsed: 0, ramTotal: 0, compressed: 0, swapUsed: 0, pressure: "", cpu: 0,
                           claude: ProcLoad(rss: 0, cpu: 0), claudeProcesses: 0, perSession: [:])
    }

    private func fraction(_ b: UInt64) -> Double {
        u.ramTotal == 0 ? 0 : min(1, Double(b) / Double(u.ramTotal))
    }

    private func titleRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Spacer()
            Text(value)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.6))
        }
    }
}

private struct Bar: View {
    var parts: [(Double, Double)]

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    Rectangle()
                        .fill(Color.white.opacity(p.1))
                        .frame(width: max(0, g.size.width * p.0 - 2))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 6)
        .background(Color.white.opacity(0.14))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}
