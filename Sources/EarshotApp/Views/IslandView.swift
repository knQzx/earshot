import EarshotCore
import SwiftUI

struct IslandView: View {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 1)

    @ObservedObject var state: NotchState

    var body: some View {
        let layout = state.layout
        let shape = IslandShape(layout)
        let stack = state.stack
        VStack(spacing: IslandLayout.panelGap) {
            IslandContent(state: state, layout: layout)
                .frame(width: layout.bodyWidth, height: layout.bodyHeight)
                .padding(.top, layout.topInset)
                .clipShape(shape)
                .background {
                    IslandBackground(shape: shape, layout: layout, metrics: state.metrics, glass: state.glass)
                        .overlay {
                            if case .finished = state.mode, let key = state.glowKey {
                                ClayGlow(shape: shape).id(key).transition(.identity)
                            }
                        }
                }
                .contentShape(shape)
                .background(alignment: .top) {
                    StackCards(behind: Array(stack.dropFirst().prefix(IslandLayout.stackDepth)), hidden: max(0, stack.count - 1 - IslandLayout.stackDepth),
                               layout: layout, fanned: state.stackHovered)
                }
            if state.expanded {
                PanelCard(state: state)
                    .frame(width: IslandLayout.panelWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(GeometryReader { Color.clear.preference(key: ContentHeightKey.self, value: $0.size.height) })
                    .transition(.panelCard)
            }
        }
        .onPreferenceChange(ContentHeightKey.self) { h in
            MainActor.assumeIsolated { state.actions.contentHeight(h) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct CardReveal: ViewModifier {
    var amount: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
            .scaleEffect(1 - 0.08 * amount, anchor: .top)
            .offset(y: -10 * amount)
    }
}

extension AnyTransition {
    static var panelCard: AnyTransition {
        .asymmetric(
            insertion: .modifier(active: CardReveal(amount: 1), identity: CardReveal(amount: 0))
                .animation(IslandView.spring),
            removal: .modifier(active: CardReveal(amount: 1), identity: CardReveal(amount: 0))
                .animation(.easeIn(duration: 0.14)))
    }
}

struct IslandBackground: View {
    var shape: IslandShape
    var layout: IslandLayout
    var metrics: NotchMetrics
    var glass: Bool

    var body: some View {
        if glass {
            ZStack(alignment: .top) {
                IslandGlass(shape: shape)
                if metrics.hasNotch {
                    UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
                        .fill(Color.black)
                        .frame(width: metrics.notchWidth, height: metrics.height)
                }
            }
        } else {
            ZStack {
                shape.fill(Color.black)
                    .shadow(color: .black.opacity(0.42), radius: 15, y: 10)
                    .opacity(layout.shadow ? 1 : 0)
                shape.fill(Color.black)
            }
        }
    }
}

struct StackCards: View {
    var behind: [AlertItem]
    var hidden: Int
    var layout: IslandLayout
    var fanned: Bool

    var body: some View {
        let step = fanned ? IslandLayout.stackFan : IslandLayout.stackStep
        ZStack(alignment: .top) {
            ForEach(Array(behind.enumerated()).reversed(), id: \.element.id) { index, item in
                let level = CGFloat(index + 1)
                let shape = IslandShape(layout)
                shape
                    .fill(Color(white: index == 0 ? 0.13 : 0.1))
                    .frame(width: layout.width * (1 - 0.04 * level), height: layout.height)
                    .opacity(index == 0 ? 0.85 : 0.7)
                    .offset(y: step * level)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: -step)),
                        removal: .opacity.combined(with: .offset(y: -step))))
            }
            if hidden > 0 {
                Text("+\(hidden)")
                    .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                    .foregroundStyle(Color.black)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(Capsule().fill(Color(nsColor: Theme.clayOnBlack)))
                    .offset(y: layout.height + step * CGFloat(behind.count) - 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .frame(width: layout.width, height: layout.height, alignment: .top)
        .allowsHitTesting(false)
    }
}
