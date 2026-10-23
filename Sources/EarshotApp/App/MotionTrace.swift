import AppKit
import QuartzCore

#if DEBUG
@MainActor
enum MotionTrace {
    nonisolated(unsafe) static var traceShapes = false
    static var enabled = false { didSet { traceShapes = enabled } }
    static var start = CACurrentMediaTime()
    static var shape: CGRect = .zero
    static var shapeCalls = 0

    static func log(_ s: String) {
        print(String(format: "%7.3f ", CACurrentMediaTime() - start) + s)
        fflush(stdout)
    }

    static func noteShape(_ r: CGRect) {
        shapeCalls += 1
        shape = r
    }



    static var alphas: [CGFloat] = []

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    static func glass(_ view: NSView) -> String {
        var found: NSView?
        func walk(_ v: NSView) {
            if found == nil, v is NSVisualEffectView { found = v }
            v.subviews.forEach(walk)
        }
        walk(view)
        guard let g = found, let w = g.window, let gl = g.layer else { return "none" }
        var opacity: Float = 1
        var scale: CGFloat = 1
        var l: CALayer? = gl
        var origin = CGPoint.zero
        while let cur = l {
            let p = cur.presentation() ?? cur
            opacity *= p.opacity
            scale *= p.transform.m11 == 0 ? 1 : p.transform.m11
            l = cur.superlayer
        }
        let r = g.convert(g.bounds, to: nil)
        origin = CGPoint(x: r.minX, y: w.frame.height - r.maxY)
        let pres = gl.presentation() ?? gl
        return "\(Int(origin.x)),\(Int(origin.y)) \(String(format: "%.1fx%.1f", pres.bounds.width, pres.bounds.height)) op\(String(format: "%.2f", opacity)) sc\(String(format: "%.3f", scale))"
    }

    static func layerCount(_ view: NSView) -> Int {
        func count(_ l: CALayer) -> Int { 1 + (l.sublayers ?? []).reduce(0) { $0 + count($1) } }
        return view.layer.map(count) ?? 0
    }

    static func shapeLayers(_ view: NSView) -> String {
        var out: [String] = []
        func walk(_ l: CALayer) {
            if String(describing: type(of: l)) == "SDFLayer", l.bounds.width > 100 {
                let p = l.superlayer?.presentation() ?? l.superlayer ?? l
                let b = (l.presentation() ?? l).bounds
                out.append("glass \(String(format: "%.1fx%.1f", b.width, b.height))@\(Int(p.position.x))")
            }
            if String(describing: type(of: l)) == "ColorShapeLayer" {
                let p = l.presentation() ?? l
                let inner = (l.sublayers?.first as? CAShapeLayer).map { ($0.presentation() ?? $0).path?.boundingBox ?? .zero } ?? .zero
                if inner.width > 100 {
                    out.append("\(String(format: "%.1fx%.1f", inner.width, inner.height))@\(Int(p.position.x))op\(String(format: "%.2f", p.opacity))")
                }
            }
            l.sublayers?.forEach(walk)
        }
        if let l = view.layer { walk(l) }
        return out.joined(separator: ",")
    }

    static func sparks(in view: NSView) -> [NSRect] {
        alphas = []
        var out: [NSRect] = []
        func walk(_ v: NSView) {
            if v is SparkLayerView, let w = v.window {
                let r = v.convert(v.bounds, to: nil)
                out.append(NSRect(x: r.minX, y: w.frame.height - r.maxY, width: r.width, height: r.height))
            }
            if v is SparkLayerView { alphas.append(v.alphaValue * CGFloat(v.superview?.layer?.presentation()?.opacity ?? 1)) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return out
    }
}
#endif
