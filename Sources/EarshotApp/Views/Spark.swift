import AppKit
import EarshotCore
import SwiftUI

struct SparkLook: Equatable {
    enum Motion { case still, spin, breathe }

    var color: NSColor
    var motion: Motion = .still
    var hop = false
    var ring = false
    var ringColor: NSColor = Theme.clayOnGlass

    static func brand(needsYou: Bool) -> SparkLook {
        SparkLook(color: Theme.clayOnBlack, ring: needsYou)
    }

    static func of(_ d: DisplayStatus, unseen: Bool, onBlack: Bool) -> SparkLook {
        let clay = onBlack ? Theme.clayOnBlack : Theme.clayOnGlass
        switch d {
        case .working:
            return SparkLook(color: onBlack ? Theme.rgb(0xF5F5F7) : .white, motion: .spin)
        case .stalled:
            return SparkLook(color: NSColor(white: 1, alpha: 0.75), motion: .breathe)
        case .permission, .question:
            return SparkLook(color: clay, hop: true, ring: true)
        case .waiting where unseen:
            return SparkLook(color: clay, hop: true)
        case .error:
            return SparkLook(color: clay, hop: true)
        case .unknown:
            return SparkLook(color: NSColor(white: 1, alpha: 0.25))
        default:
            return SparkLook(color: NSColor(white: 1, alpha: 0.35))
        }
    }
}

enum SparkGlyph {
    static func path(size: CGFloat, origin: CGPoint = .zero) -> CGPath {
        let k = size / 24
        let p = CGMutablePath()
        let lines: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(12, 3, 12, 21), (3, 12, 21, 12), (5.6, 5.6, 18.4, 18.4), (18.4, 5.6, 5.6, 18.4)]
        for l in lines {
            p.move(to: CGPoint(x: origin.x + l.0 * k, y: origin.y + l.1 * k))
            p.addLine(to: CGPoint(x: origin.x + l.2 * k, y: origin.y + l.3 * k))
        }
        return p
    }

    static func lineWidth(_ size: CGFloat) -> CGFloat {
        size * (size <= 10 ? 3.4 : (size >= 14 ? 2.6 : 2.8)) / 24
    }
}

struct SparkBadge: View {
    var look: SparkLook
    var size: CGFloat
    var glyph: CGFloat
    var fill: Color? = Theme.well
    var separator: Color? = nil
    @Environment(\.staticRendering) private var staticRendering
    @Environment(\.sparkLayerBacked) private var layerBacked
    @Environment(\.sparkHidden) private var hidden

    var body: some View {
        Group {
            if staticRendering {
                StaticSpark(look: look, size: size, glyph: glyph, fill: fill, separator: separator, phase: .resting(look))
            } else if layerBacked {
                LiveSpark(look: look, size: size, glyph: glyph, fill: fill.map { NSColor($0) },
                          separator: separator.map { NSColor($0) }, hidden: hidden)
            } else {
                TimelineSpark(look: look, size: size, glyph: glyph, fill: fill, separator: separator)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct SparkLayerBackedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SparkHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sparkLayerBacked: Bool {
        get { self[SparkLayerBackedKey.self] }
        set { self[SparkLayerBackedKey.self] = newValue }
    }

    var sparkHidden: Bool {
        get { self[SparkHiddenKey.self] }
        set { self[SparkHiddenKey.self] = newValue }
    }
}

private struct GlyphShape: Shape {
    var glyph: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(SparkGlyph.path(size: glyph, origin: CGPoint(x: rect.midX - glyph / 2, y: rect.midY - glyph / 2)))
    }
}

struct SparkPhase {
    var rotation: Double = 0
    var glyphAlpha: Double = 1
    var ringScale: CGFloat = 1
    var ringAlpha: Double = 0.9
    var hop: CGFloat = 0

    static func resting(_ look: SparkLook) -> SparkPhase {
        SparkPhase(rotation: look.motion == .spin ? 12 : 0)
    }

    static func at(_ t: Double, _ look: SparkLook) -> SparkPhase {
        var p = SparkPhase()
        switch look.motion {
        case .spin: p.rotation = t.truncatingRemainder(dividingBy: 6) / 6 * 360
        case .breathe: p.glyphAlpha = 0.45 + 0.55 * (0.5 - 0.5 * cos(t / 2.4 * 2 * .pi))
        case .still: break
        }
        if look.ring {
            let r = t.truncatingRemainder(dividingBy: 1.8) / 1.8
            if r < 0.7 {
                let k = 1 - pow(1 - r / 0.7, 2)
                p.ringScale = 1 + 0.5 * k
                p.ringAlpha = 0.9 * (1 - r / 0.7)
            } else {
                p.ringScale = 1.5
                p.ringAlpha = 0
            }
        }
        if look.hop {
            let h = t.truncatingRemainder(dividingBy: 2.2) / 2.2
            let keys: [(Double, Double)] = [(0, 0), (0.62, 0), (0.7, -3), (0.8, 0), (0.86, -1.5), (0.92, 0), (1, 0)]
            for i in 1..<keys.count where h <= keys[i].0 {
                let a = keys[i - 1], b = keys[i]
                let u = (h - a.0) / (b.0 - a.0)
                let e = u * u * (3 - 2 * u)
                p.hop = CGFloat(a.1 + (b.1 - a.1) * e)
                break
            }
        }
        return p
    }
}

private struct StaticSpark: View {
    var look: SparkLook
    var size: CGFloat
    var glyph: CGFloat
    var fill: Color?
    var separator: Color?
    var phase: SparkPhase

    var body: some View {
        ZStack {
            if let fill {
                if let separator { Circle().fill(separator).padding(-1.5) }
                Circle().fill(fill)
            }
            GlyphShape(glyph: glyph)
                .stroke(Color(nsColor: look.color), style: StrokeStyle(lineWidth: SparkGlyph.lineWidth(glyph), lineCap: .round))
                .rotationEffect(.degrees(phase.rotation))
                .opacity(phase.glyphAlpha)
            if look.ring {
                Circle()
                    .strokeBorder(Color(nsColor: look.ringColor), lineWidth: 1.5)
                    .scaleEffect(phase.ringScale)
                    .opacity(phase.ringAlpha)
            }
        }
        .offset(y: phase.hop)
    }
}

private struct TimelineSpark: View {
    var look: SparkLook
    var size: CGFloat
    var glyph: CGFloat
    var fill: Color?
    var separator: Color?

    var body: some View {
        let moving = look.motion != .still || look.ring || look.hop
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !moving)) { ctx in
            StaticSpark(look: look, size: size, glyph: glyph, fill: fill, separator: separator,
                        phase: moving ? .at(ctx.date.timeIntervalSinceReferenceDate, look) : SparkPhase())
        }
    }
}

private struct LiveSpark: NSViewRepresentable {
    var look: SparkLook
    var size: CGFloat
    var glyph: CGFloat
    var fill: NSColor?
    var separator: NSColor?
    var hidden: Bool

    func makeNSView(context: Context) -> SparkLayerView {
        let v = SparkLayerView(size: size, glyph: glyph, fill: fill, separator: separator)
        v.apply(look)
        v.setHidden(hidden, fade: false)
        return v
    }

    func updateNSView(_ v: SparkLayerView, context: Context) {
        v.apply(look)
        v.setHidden(hidden, fade: context.transaction.animation != nil)
    }
}

final class SparkLayerView: NSView {
    private let container = CALayer()
    private let circle = CAShapeLayer()
    private let glyphLayer = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let size: CGFloat
    private var look: SparkLook?

    init(size: CGFloat, glyph: CGFloat, fill: NSColor?, separator: NSColor?) {
        self.size = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.masksToBounds = false
        let still: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "fillColor": NSNull(),
                                         "strokeColor": NSNull(), "opacity": NSNull(), "transform": NSNull()]
        let box = CGRect(x: 0, y: 0, width: size, height: size)
        container.actions = still
        container.bounds = box
        layer?.addSublayer(container)
        for l in [circle, glyphLayer, ring] {
            l.actions = still
            l.bounds = box
            l.position = CGPoint(x: size / 2, y: size / 2)
            l.contentsScale = 2
            container.addSublayer(l)
        }
        circle.path = CGPath(ellipseIn: box, transform: nil)
        circle.fillColor = fill?.cgColor
        if let separator, fill != nil {
            circle.strokeColor = separator.cgColor
            circle.lineWidth = 1.5
            circle.path = CGPath(ellipseIn: box.insetBy(dx: -0.75, dy: -0.75), transform: nil)
        }
        glyphLayer.path = SparkGlyph.path(size: glyph, origin: CGPoint(x: (size - glyph) / 2, y: (size - glyph) / 2))
        glyphLayer.fillColor = nil
        glyphLayer.lineWidth = SparkGlyph.lineWidth(glyph)
        glyphLayer.lineCap = .round
        ring.path = CGPath(ellipseIn: box.insetBy(dx: 0.75, dy: 0.75), transform: nil)
        ring.fillColor = nil
        ring.lineWidth = 1.5
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        container.position = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        for l in [circle, glyphLayer, ring] { l.contentsScale = s }
    }

    func setHidden(_ hidden: Bool, fade: Bool) {
        guard let layer else { return }
        let target: Float = hidden ? 0 : 1
        guard layer.opacity != target else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = target
        CATransaction.commit()
        guard !hidden, fade else { return }
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 0
        a.toValue = 1
        a.duration = 0.2
        a.beginTime = CACurrentMediaTime() + 0.12
        a.fillMode = .backwards
        layer.add(a, forKey: "reveal")
    }

    func apply(_ next: SparkLook) {
        guard next != look else { return }
        let old = look
        look = next
        glyphLayer.strokeColor = next.color.cgColor
        ring.strokeColor = next.ringColor.cgColor
        let calm = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if old?.hop != next.hop {
            container.removeAllAnimations()
            if next.hop && !calm {
                let a = CAKeyframeAnimation(keyPath: "transform.translation.y")
                a.values = [0, 0, -3, 0, -1.5, 0, 0]
                a.keyTimes = [0, 0.62, 0.7, 0.8, 0.86, 0.92, 1]
                a.duration = 2.2
                a.repeatCount = .infinity
                a.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 6)
                a.isRemovedOnCompletion = false
                container.add(a, forKey: "hop")
            }
        }
        if old?.motion != next.motion {
            glyphLayer.removeAllAnimations()
            glyphLayer.opacity = 1
            switch calm ? .still : next.motion {
            case .spin:
                let a = CABasicAnimation(keyPath: "transform.rotation.z")
                a.fromValue = 0
                a.toValue = 2 * Double.pi
                a.duration = 6
                a.repeatCount = .infinity
                a.isRemovedOnCompletion = false
                glyphLayer.add(a, forKey: "spin")
            case .breathe:
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 0.45
                a.toValue = 1
                a.duration = 1.2
                a.autoreverses = true
                a.repeatCount = .infinity
                a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                a.isRemovedOnCompletion = false
                glyphLayer.add(a, forKey: "breathe")
            default:
                break
            }
        }
        if old?.ring != next.ring {
            ring.removeAllAnimations()
            ring.opacity = next.ring && calm ? 0.9 : 0
            if next.ring && !calm {
                let s = CAKeyframeAnimation(keyPath: "transform.scale")
                s.values = [1, 1.5, 1.5]
                s.keyTimes = [0, 0.7, 1]
                let o = CAKeyframeAnimation(keyPath: "opacity")
                o.values = [0.9, 0, 0]
                o.keyTimes = [0, 0.7, 1]
                let g = CAAnimationGroup()
                g.animations = [s, o]
                g.duration = 1.8
                g.timingFunction = CAMediaTimingFunction(name: .easeOut)
                g.repeatCount = .infinity
                g.isRemovedOnCompletion = false
                ring.add(g, forKey: "ring")
            }
        }
    }
}
