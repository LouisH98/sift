import AppKit
import Combine
import SwiftUI

@MainActor
final class NotchActivationHoverModel: ObservableObject {
    @Published var isHovered = false
    @Published var isPressed = false
    @Published var proximity: CGFloat = 0

    func updateHover(location: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else {
            return
        }

        let target = CGPoint(x: size.width / 2, y: size.height)
        let normalizedX = (location.x - target.x) / (size.width * 0.32)
        let normalizedY = (location.y - target.y) / (size.height * 0.62)
        let distance = sqrt((normalizedX * normalizedX) + (normalizedY * normalizedY))
        let nextProximity = max(0, min(1, 1 - (distance * 1.14)))

        withAnimation(.smooth(duration: 0.12)) {
            isHovered = true
            proximity = nextProximity
        }
    }

    func endHover() {
        withAnimation(.smooth(duration: 0.22)) {
            isHovered = false
            isPressed = false
            proximity = 0
        }
    }

    func setPressed(_ isPressed: Bool) {
        withAnimation(.smooth(duration: 0.08)) {
            self.isPressed = isPressed
        }
    }
}

struct NotchActivationView: View {
    @ObservedObject var model: NotchActivationHoverModel
    @ObservedObject var appearanceSettings: NotchAppearanceSettings
    @ObservedObject var processor: ThoughtProcessor

    let notchSize: CGSize
    let size: CGSize

    private var glowStrength: CGFloat {
        guard appearanceSettings.isGlowEnabled else {
            return 0
        }

        let proximityBoost = pow(model.proximity, 1.35)
        let hoverFloor: CGFloat = model.isHovered ? 0.18 : 0
        let pressBoost: CGFloat = model.isPressed ? 0.12 : 0

        return min(1, hoverFloor + proximityBoost + pressBoost)
    }

    private var surfaceOpacity: CGFloat {
        if model.isHovered {
            return 0.82
        }

        return processor.notchProcessingState.isDistilling ? 0.16 : 0
    }

    var body: some View {
        ZStack(alignment: .top) {
            if appearanceSettings.isGlowEnabled {
                NotchGlowField(strength: glowStrength)
                    .opacity(glowStrength > 0.01 ? 1 : 0)
                    .animation(.smooth(duration: 0.16), value: glowStrength)
                    .allowsHitTesting(false)

                notchSurface
                    .padding(.top, -2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .preferredColorScheme(.dark)
    }

    private var notchSurface: some View {
        NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
            .fill(.black.opacity(surfaceOpacity))
            .frame(width: notchSize.width, height: notchSize.height)
            .overlay {
                NotchProcessingEffect(
                    state: processor.notchProcessingState,
                    topCornerRadius: 6,
                    bottomCornerRadius: 14,
                    glowColor: appearanceSettings.glowColor,
                    segmentLengthScale: 1.35
                )
                .frame(width: notchSize.width + 10, height: notchSize.height + 6)
            }
            .shadow(color: appearanceSettings.glowColor.opacity(glowStrength * 0.34), radius: 18 + (glowStrength * 18), x: 0, y: 8)
            .shadow(color: appearanceSettings.glowColor.opacity(glowStrength * 0.22), radius: 34 + (glowStrength * 24), x: 0, y: 18)
            .scaleEffect(model.isPressed ? 0.985 : 1, anchor: .top)
            .animation(.smooth(duration: 0.12), value: model.isHovered)
            .animation(.smooth(duration: 0.08), value: model.isPressed)
            .animation(.smooth(duration: 0.28), value: processor.notchProcessingState.isDistilling)
    }
}

private struct NotchGlowField: View {
    @ObservedObject private var appearanceSettings = NotchAppearanceSettings.shared

    let strength: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
            GeometryReader { proxy in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let color = appearanceSettings.nsGlowColor
                let shader = ShaderLibrary.notchGlow(
                    .float2(proxy.size),
                    .float(Float(strength)),
                    .float(Float(seconds.truncatingRemainder(dividingBy: 120))),
                    .float(Float(color.redComponent)),
                    .float(Float(color.greenComponent)),
                    .float(Float(color.blueComponent))
                )

                shaderLayer(shader: shader)
            }
        }
    }

    private func shaderLayer(shader: Shader) -> some View {
        Rectangle()
            .fill(.white.opacity(max(0.08, strength)))
            .colorEffect(shader)
            .blur(radius: 1.25)
            .blendMode(.plusLighter)
            .compositingGroup()
    }
}

final class NotchActivationPanel: NSPanel {
    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }
}
