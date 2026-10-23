import AppKit
import SwiftUI

struct GlassBackdrop {
    var space: String
    var size: CGSize
    var view: AnyView
}

private struct GlassBackdropKey: EnvironmentKey {
    static let defaultValue: GlassBackdrop? = nil
}

extension EnvironmentValues {
    var glassBackdrop: GlassBackdrop? {
        get { self[GlassBackdropKey.self] }
        set { self[GlassBackdropKey.self] = newValue }
    }
}

struct GlassBackground: View {
    var radius: CGFloat
    @Environment(\.glassBackdrop) private var backdrop

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if backdrop != nil {
                GlassApproximation(shape: shape, tint: 0.52)
            } else if LiquidGlass.available {
                LiquidGlass.Surface(shape: shape, tint: 0.32)
            } else {
                VisualEffect(radius: radius)
                    .overlay(Color(.sRGB, red: 30 / 255, green: 30 / 255, blue: 34 / 255, opacity: 0.18))
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            }
        }
        .background(shape.fill(Color.black.opacity(0.35)).blur(radius: 25).offset(y: 20))
    }
}

struct IslandGlass<S: Shape>: View {
    var shape: S
    @Environment(\.glassBackdrop) private var backdrop

    var body: some View {
        if backdrop != nil {
            GlassApproximation(shape: shape, tint: 0.62)
        } else if LiquidGlass.available {
            LiquidGlass.Surface(shape: shape, tint: 0.5)
        } else {
            shape.fill(Color.black)
        }
    }

    static var supported: Bool { LiquidGlass.available }
}

enum LiquidGlass {
    static var available: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }
}

extension LiquidGlass {
    struct Surface<S: Shape>: View {
        var shape: S
        var tint: Double

        var body: some View {
            #if compiler(>=6.2)
            if #available(macOS 26, *) {
                Color.clear.glassEffect(.regular.tint(Color.black.opacity(tint)), in: shape)
            }
            #endif
        }
    }
}



struct GlassApproximation<S: Shape>: View {
    var shape: S
    var tint: Double
    @Environment(\.glassBackdrop) private var backdrop

    var body: some View {
        Group {
            if let backdrop {
                GeometryReader { g in
                    let f = g.frame(in: .named(backdrop.space))
                    backdrop.view
                        .frame(width: backdrop.size.width, height: backdrop.size.height)
                        .offset(x: -f.minX, y: -f.minY)
                        .blur(radius: 30)
                        .saturation(1.8)
                }
                .overlay(Color(.sRGB, red: 22 / 255, green: 22 / 255, blue: 26 / 255, opacity: tint))
            }
        }
        .clipShape(shape)
        .overlay(shape.stroke(LinearGradient(colors: [Color.white.opacity(0.04), Color.white.opacity(0.26)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
    }
}

private struct VisualEffect: NSViewRepresentable {
    var radius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        v.maskImage = Self.mask(radius)
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}

    static func mask(_ r: CGFloat) -> NSImage {
        let side = r * 2 + 1
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
    }
}
