import AppKit
import Combine
import SwiftUI

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

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

    let size: CGSize
    let hitSize: CGSize
    let activationSize: CGSize
    let opensOnTopEdgePush: Bool
    let onActivate: () -> Void

    private let notchSize = CGSize(width: 185, height: 32)

    private var glowStrength: CGFloat {
        guard appearanceSettings.isGlowEnabled else {
            return 0
        }

        let proximityBoost = pow(model.proximity, 1.35)
        let hoverFloor: CGFloat = model.isHovered ? 0.18 : 0
        let pressBoost: CGFloat = model.isPressed ? 0.12 : 0

        return min(1, hoverFloor + proximityBoost + pressBoost)
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

            NotchActivationTrackingView(
                model: model,
                activationSize: activationSize,
                opensOnTopEdgePush: opensOnTopEdgePush,
                onActivate: onActivate
            )
            .frame(width: hitSize.width, height: hitSize.height)
            .frame(width: size.width, height: size.height, alignment: .top)
        }
        .frame(width: size.width, height: size.height)
        .preferredColorScheme(.dark)
    }

    private var notchSurface: some View {
        NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
            .fill(.black.opacity(model.isHovered ? 0.82 : 0))
            .frame(width: notchSize.width, height: notchSize.height)
            .shadow(color: appearanceSettings.glowColor.opacity(glowStrength * 0.34), radius: 18 + (glowStrength * 18), x: 0, y: 8)
            .shadow(color: appearanceSettings.glowColor.opacity(glowStrength * 0.22), radius: 34 + (glowStrength * 24), x: 0, y: 18)
            .scaleEffect(model.isPressed ? 0.985 : 1, anchor: .top)
            .animation(.smooth(duration: 0.12), value: model.isHovered)
            .animation(.smooth(duration: 0.08), value: model.isPressed)
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

private struct NotchActivationTrackingView: NSViewRepresentable {
    @ObservedObject var model: NotchActivationHoverModel

    let activationSize: CGSize
    let opensOnTopEdgePush: Bool
    let onActivate: () -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.model = model
        view.activationSize = activationSize
        view.opensOnTopEdgePush = opensOnTopEdgePush
        view.onActivate = onActivate
        return view
    }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.model = model
        view.activationSize = activationSize
        view.opensOnTopEdgePush = opensOnTopEdgePush
        view.onActivate = onActivate
    }

    final class TrackingView: NSView {
        weak var model: NotchActivationHoverModel?
        var activationSize: CGSize = .zero
        var opensOnTopEdgePush = false
        var onActivate: (() -> Void)?

        private var trackingArea: NSTrackingArea?

        override var acceptsFirstResponder: Bool {
            true
        }

        override var isFlipped: Bool {
            false
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            activationRect.contains(point) ? self : nil
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()

            if let trackingArea {
                removeTrackingArea(trackingArea)
            }

            let options: NSTrackingArea.Options = [
                .activeAlways,
                .inVisibleRect,
                .mouseEnteredAndExited,
                .mouseMoved
            ]
            let nextTrackingArea = NSTrackingArea(
                rect: bounds,
                options: options,
                owner: self,
                userInfo: nil
            )

            addTrackingArea(nextTrackingArea)
            trackingArea = nextTrackingArea
        }

        override func mouseEntered(with event: NSEvent) {
            updateHover(with: event)
        }

        override func mouseMoved(with event: NSEvent) {
            updateHover(with: event)
            activateOnTopEdgePushIfNeeded(with: event)
        }

        override func mouseDragged(with event: NSEvent) {
            updateHover(with: event)
            activateOnTopEdgePushIfNeeded(with: event)
        }

        override func mouseExited(with event: NSEvent) {
            model?.endHover()
        }

        override func mouseDown(with event: NSEvent) {
            model?.setPressed(true)
            updateHover(with: event)

            if activationRect.contains(convert(event.locationInWindow, from: nil)) {
                onActivate?()
            }
        }

        override func mouseUp(with event: NSEvent) {
            model?.setPressed(false)
            updateHover(with: event)
        }

        private func updateHover(with event: NSEvent) {
            model?.updateHover(location: convert(event.locationInWindow, from: nil), in: bounds.size)
        }

        private var activationRect: NSRect {
            let width = min(bounds.width, max(1, activationSize.width))
            let height = min(bounds.height, max(1, activationSize.height))
            let x = bounds.midX - (width / 2)
            let y = bounds.maxY - height

            return NSRect(x: x, y: y, width: width, height: height)
        }

        private func activateOnTopEdgePushIfNeeded(with event: NSEvent) {
            guard opensOnTopEdgePush else {
                return
            }

            if activationRect.contains(convert(event.locationInWindow, from: nil)) {
                onActivate?()
            }
        }
    }
}

final class NotchActivationPanel: NSPanel {
    var onActivate: (() -> Void)?

    override var canBecomeKey: Bool {
        false
    }

    override var canBecomeMain: Bool {
        false
    }

    func activateFromMouse() {
        onActivate?()
    }
}
