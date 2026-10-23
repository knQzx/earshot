import EarshotCore
import AppKit

struct NotchMetrics: Equatable {
    var hasNotch: Bool
    var notchWidth: CGFloat
    var height: CGFloat

    static let builtInSample = NotchMetrics(hasNotch: true, notchWidth: 185, height: 32)
    static let externalSample = NotchMetrics(hasNotch: false, notchWidth: 0, height: 24)

    static func of(_ screen: NSScreen) -> (metrics: NotchMetrics, centerX: CGFloat) {
        let f = screen.frame
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = f.width - left.width - right.width
            if width > 40 {
                return (NotchMetrics(hasNotch: true, notchWidth: width, height: top), f.minX + left.width + width / 2)
            }
        }
        let bar = f.maxY - screen.visibleFrame.maxY
        let height = bar >= 18 && bar <= 44 ? bar : max(22, NSStatusBar.system.thickness)
        return (NotchMetrics(hasNotch: false, notchWidth: 0, height: height), f.midX)
    }
}

struct IslandLayout: Equatable {
    var bodyWidth: CGFloat
    var bodyHeight: CGFloat
    var bottomRadius: CGFloat
    var topRadius: CGFloat = 0
    var topInset: CGFloat = 0
    var earWidth: CGFloat = 0
    var shadow = false

    static let panelWidth: CGFloat = 440
    static let panelGap: CGFloat = 8
    static let avatar: CGFloat = 18
    static let overlap: CGFloat = 3
    static let maxAvatars = 5
    static let approvalHeight: CGFloat = 76
    static let stackStep: CGFloat = 6
    static let stackFan: CGFloat = 10
    static let stackDepth = 2
    static let stackExtra: CGFloat = stackFan * CGFloat(stackDepth) + 16

    var width: CGFloat { bodyWidth }
    var height: CGFloat { topInset + bodyHeight }

    static func stackWidth(_ count: Int, avatar: CGFloat = avatar) -> CGFloat {
        let shown = min(count, maxAvatars)
        guard shown > 0 else { return 0 }
        var w = CGFloat(shown) * avatar - CGFloat(shown - 1) * overlap
        if count > maxAvatars { w += 4 + 18 }
        return w
    }

    @MainActor
    static func of(_ mode: IslandMode, metrics m: NotchMetrics, board: Board) -> IslandLayout {
        let notch = m.hasNotch ? m.notchWidth : 0
        switch mode {
        case .blocked(let b):
            let ear = ApprovalMetrics.blockedEarWidth(b, group: board.groupOf(b.session))
            return IslandLayout(bodyWidth: min(640, max(460, notch + 2 * ear)), bodyHeight: approvalHeight, bottomRadius: 22, shadow: true)
        case .memory(let alert):
            let ear = ApprovalMetrics.memoryEarWidth(alert)
            return IslandLayout(bodyWidth: min(640, max(460, notch + 2 * ear)), bodyHeight: approvalHeight, bottomRadius: 22, shadow: true)
        case .finished(let info, let more):
            let ear = ApprovalMetrics.finishedEarWidth(info, more: more)
            return IslandLayout(bodyWidth: min(640, max(460, notch + 2 * ear)), bodyHeight: approvalHeight, bottomRadius: 22, shadow: true)
        case .approval(let item):
            let ear = ApprovalMetrics.earWidth(item, group: board.groupOf(item.session), more: board.requests.count - 1)
            return IslandLayout(bodyWidth: min(640, max(460, notch + 2 * ear)), bodyHeight: approvalHeight, bottomRadius: 22, shadow: true)
        case .empty where m.hasNotch:
            return IslandLayout(bodyWidth: m.notchWidth - 2, bodyHeight: m.height - 1, bottomRadius: 11)
        case .empty:
            let h = max(16, m.height - 4)
            return IslandLayout(bodyWidth: h + 12, bodyHeight: h, bottomRadius: h / 2, topRadius: h / 2, topInset: 2)
        case .ears where m.hasNotch:
            let ear = 12 + max(22, stackWidth(board.items.count)) + 10
            return IslandLayout(bodyWidth: m.notchWidth + 2 * ear, bodyHeight: m.height, bottomRadius: 11, earWidth: ear)
        case .ears:
            let h = max(16, m.height - 4)
            let w = 8 + 16 + 6 + stackWidth(board.items.count, avatar: 16) + 8
            return IslandLayout(bodyWidth: w, bodyHeight: h, bottomRadius: h / 2, topRadius: h / 2, topInset: 2)
        }
    }
}

@MainActor
enum ApprovalMetrics {
    static let nameFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let capsuleFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    static let moreFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static var widths: [String: CGFloat] = [:]

    static func width(_ s: String, _ font: NSFont) -> CGFloat {
        let key = "\(font.pointSize)|\(s)"
        if let w = widths[key] { return w }
        let w = ceil((s as NSString).size(withAttributes: [.font: font]).width)
        if widths.count > 256 { widths.removeAll() }
        widths[key] = w
        return w
    }

    static let doneFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    static func blockedEarWidth(_ b: BlockedAlert, group: SessionGroup?) -> CGFloat {
        let left = 12 + 22 + 8 + width(BlockedPill.title(b), nameFont)
        var right = 14 + width(b.session.chipName, doneFont)
        if let group { right += 7 + 7 + 5 + 4 + width(group.name, capsuleFont) + 7 }
        return max(left, right) + 14
    }

    static func memoryEarWidth(_ alert: MemoryAlert) -> CGFloat {
        let left = 12 + 22 + 8 + width(MemoryPill.title(alert), nameFont)
        let right = 14 + width(MemoryPill.figures(alert), doneFont) + 8 + 18
        return max(left, right) + 14
    }

    static func finishedEarWidth(_ info: SessionInfo, more: Int) -> CGFloat {
        var left = 12 + 22 + 8 + width(info.session.name, nameFont)
        if let g = info.group { left += 7 + 7 + 5 + 4 + width(g.name, capsuleFont) + 7 }
        var right = 14 + width("Done · 59 min", doneFont)
        if more > 0 { right += 8 + width("+\(more)", moreFont) }
        return max(left, right) + 14
    }

    static func earWidth(_ item: RequestItem, group: SessionGroup?, more: Int) -> CGFloat {
        var left = 12 + 22 + 8 + width(item.session.chipName, nameFont)
        if let group { left += 7 + 7 + 5 + 4 + width(group.name, capsuleFont) + 7 }
        let right = more > 0 ? 14 + width("+\(more)", moreFont) : 0
        return max(left, right) + 14
    }
}
