import SwiftUI

struct IslandShape: Shape {
    var flare: CGFloat
    var bottomRadius: CGFloat
    var topRadius: CGFloat
    var topInset: CGFloat

    init(_ layout: IslandLayout) {
        flare = 0
        bottomRadius = layout.bottomRadius
        topRadius = layout.topRadius
        topInset = layout.topInset
    }

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(flare, bottomRadius), AnimatablePair(topRadius, topInset)) }
        set {
            flare = newValue.first.first
            bottomRadius = newValue.first.second
            topRadius = newValue.second.first
            topInset = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        #if DEBUG
        if MotionTrace.traceShapes { MainActor.assumeIsolated { MotionTrace.noteShape(rect) } }
        #endif
        let top = rect.minY + topInset
        let body = CGRect(x: rect.minX + flare, y: top, width: max(0, rect.width - 2 * flare), height: max(0, rect.maxY - top))
        let limit = min(body.width, body.height) / 2
        let br = min(bottomRadius, limit), tr = min(topRadius, limit)
        var p = Path(roundedRect: body,
                     cornerRadii: RectangleCornerRadii(topLeading: tr, bottomLeading: br, bottomTrailing: br, topTrailing: tr),
                     style: .continuous)
        let f = min(flare, body.height)
        if f > 0.01 {
            let l = body.minX, r = body.maxX
            p.move(to: CGPoint(x: l - f, y: top))
            p.addLine(to: CGPoint(x: l + 1, y: top))
            p.addLine(to: CGPoint(x: l + 1, y: top + f))
            p.addLine(to: CGPoint(x: l, y: top + f))
            p.addQuadCurve(to: CGPoint(x: l - f, y: top), control: CGPoint(x: l, y: top))
            p.closeSubpath()
            p.move(to: CGPoint(x: r + f, y: top))
            p.addQuadCurve(to: CGPoint(x: r, y: top + f), control: CGPoint(x: r, y: top))
            p.addLine(to: CGPoint(x: r - 1, y: top + f))
            p.addLine(to: CGPoint(x: r - 1, y: top))
            p.closeSubpath()
        }
        return p
    }
}
