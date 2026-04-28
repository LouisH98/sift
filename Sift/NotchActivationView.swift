import AppKit
import Combine
import Metal
import QuartzCore
import simd
import SwiftUI

@MainActor
final class NotchActivationHoverModel: ObservableObject {
    @Published var isHovered = false
    @Published var isPressed = false
    @Published var proximity: CGFloat = 0
    @Published var activationProgress: CGFloat = 0

    var glowStrengthForTransition: CGFloat {
        let proximity = Self.smoothProximity(proximity)
        let proximityBoost = pow(proximity, 1.18)
        let progressBoost = pow(Self.smoothProximity(activationProgress), 0.82) * 0.58
        let pressBoost: CGFloat = isPressed ? 0.08 : 0

        return min(1, max(proximityBoost, progressBoost) + pressBoost)
    }

    func updateHover(location: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else {
            return
        }

        let target = CGPoint(x: size.width / 2, y: size.height)
        let normalizedX = (location.x - target.x) / (size.width * 0.34)
        let normalizedY = (location.y - target.y) / (size.height * 0.68)
        let distance = sqrt((normalizedX * normalizedX) + (normalizedY * normalizedY))
        let nextProximity = max(0, min(1, 1 - (distance * 1.02)))

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
            activationProgress = 0
        }
    }

    func updateActivationProgress(_ progress: CGFloat) {
        withAnimation(.smooth(duration: 0.14)) {
            activationProgress = max(0, min(1, progress))
            isPressed = activationProgress > 0.01
        }
    }

    static func smoothProximity(_ proximity: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, proximity))

        return clamped * clamped * (3 - (2 * clamped))
    }
}

struct NotchActivationView: View {
    @ObservedObject var model: NotchActivationHoverModel
    @ObservedObject var appearanceSettings: NotchAppearanceSettings
    @ObservedObject var processor: ThoughtProcessor

    let notchSize: CGSize
    let size: CGSize
    let usesTopEdgeLine: Bool

    private let topEdgeNotchHeight: CGFloat = 24

    private var glowStrength: CGFloat {
        guard appearanceSettings.isGlowEnabled else {
            return 0
        }

        return model.glowStrengthForTransition
    }

    private var surfaceOpacity: CGFloat {
        let hoverOpacity = model.isHovered ? 0.82 * NotchActivationHoverModel.smoothProximity(model.proximity) : 0
        let processingOpacity: CGFloat = processor.notchProcessingState.isDistilling ? 0.16 : 0

        return max(hoverOpacity, processingOpacity)
    }

    private var activationSize: CGSize {
        usesTopEdgeLine ? CGSize(width: notchSize.width, height: topEdgeNotchHeight) : notchSize
    }

    private var feedbackProgress: CGFloat {
        NotchActivationHoverModel.smoothProximity(model.activationProgress)
    }

    private var feedbackSize: CGSize {
        CGSize(
            width: activationSize.width + (feedbackProgress * (usesTopEdgeLine ? 56 : 22)),
            height: activationSize.height + (feedbackProgress * (usesTopEdgeLine ? 8 : 9))
        )
    }

    private var glowShape: NotchGlowShape {
        usesTopEdgeLine ? .topEdgeLine : .notch
    }

    var body: some View {
        ZStack(alignment: .top) {
            if appearanceSettings.isGlowEnabled {
                NotchGlowField(strength: glowStrength, notchSize: feedbackSize, shape: glowShape)
                    .opacity(glowStrength > 0.01 ? 1 : 0)
                    .animation(.smooth(duration: 0.16), value: glowStrength)
                    .animation(.smooth(duration: 0.14), value: feedbackSize.width)
                    .animation(.smooth(duration: 0.14), value: feedbackSize.height)
                    .allowsHitTesting(false)

                notchSurface
                    .padding(.top, usesTopEdgeLine ? 0 : -2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var notchSurface: some View {
        if usesTopEdgeLine {
            TopEdgeNotchShape(topShoulderRadius: 7, bottomCornerRadius: 15)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.42, blue: 1.0),
                            appearanceSettings.glowColor,
                            Color(red: 0.76, green: 0.34, blue: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .opacity(min(0.92, surfaceOpacity * 1.08))
                .frame(width: feedbackSize.width, height: feedbackSize.height)
                .overlay {
                    TopEdgeNotchShape(topShoulderRadius: 7, bottomCornerRadius: 15)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.42),
                                    .white.opacity(0.08),
                                    .clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .opacity(surfaceOpacity)
                }
                .overlay {
                    TopEdgeLineProcessingEffect(
                        state: processor.notchProcessingState,
                        metalGlowColor: appearanceSettings.nsGlowColor
                    )
                    .frame(width: feedbackSize.width + 12, height: feedbackSize.height + 8)
                    .offset(y: -1)
                }
                .shadow(color: .black.opacity(surfaceOpacity * 0.34), radius: 8, x: 0, y: 2)
                .shadow(color: appearanceSettings.glowColor.opacity(glowStrength * 0.30), radius: 18 + (glowStrength * 16), x: 0, y: 8)
                .shadow(color: appearanceSettings.glowColor.opacity(glowStrength * 0.16), radius: 34 + (glowStrength * 18), x: 0, y: 16)
                .animation(.smooth(duration: 0.12), value: model.isHovered)
                .animation(.smooth(duration: 0.08), value: model.isPressed)
                .animation(.smooth(duration: 0.14), value: model.activationProgress)
                .animation(.smooth(duration: 0.28), value: processor.notchProcessingState.isDistilling)
        } else {
            NotchShape(topCornerRadius: 6, bottomCornerRadius: 14)
                .fill(.black.opacity(surfaceOpacity))
                .frame(width: notchSize.width, height: notchSize.height)
                .overlay {
                    NotchProcessingEffect(
                        state: processor.notchProcessingState,
                        topCornerRadius: 6,
                        bottomCornerRadius: 14,
                        metalGlowColor: appearanceSettings.nsGlowColor,
                        segmentLengthScale: 1.35
                    )
                    .frame(width: notchSize.width + 10, height: notchSize.height + 6)
                }
                .shadow(color: appearanceSettings.glowColor.opacity(glowStrength * 0.34), radius: 18 + (glowStrength * 18), x: 0, y: 8)
                .shadow(color: appearanceSettings.glowColor.opacity(glowStrength * 0.22), radius: 34 + (glowStrength * 24), x: 0, y: 18)
                .scaleEffect(
                    x: 1 + (feedbackProgress * 0.05),
                    y: 1 + (feedbackProgress * 0.12),
                    anchor: .top
                )
                .animation(.smooth(duration: 0.12), value: model.isHovered)
                .animation(.smooth(duration: 0.08), value: model.isPressed)
                .animation(.smooth(duration: 0.14), value: model.activationProgress)
                .animation(.smooth(duration: 0.28), value: processor.notchProcessingState.isDistilling)
        }
    }
}

private struct TopEdgeNotchShape: Shape {
    private var topShoulderRadius: CGFloat
    private var bottomCornerRadius: CGFloat

    init(topShoulderRadius: CGFloat, bottomCornerRadius: CGFloat) {
        self.topShoulderRadius = topShoulderRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get {
            .init(topShoulderRadius, bottomCornerRadius)
        }
        set {
            topShoulderRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()

        guard rect.width > 0, rect.height > 0 else {
            return path
        }

        let topShoulderRadius = min(topShoulderRadius, rect.width * 0.08, rect.height * 0.38)
        let topInset = topShoulderRadius * 1.65
        let bottomCornerRadius = min(bottomCornerRadius, rect.width * 0.5, rect.height * 0.58)

        path.move(to: CGPoint(x: rect.minX + topInset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topInset, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + topShoulderRadius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomCornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - bottomCornerRadius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + bottomCornerRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - bottomCornerRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topShoulderRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topInset, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()

        return path
    }
}

private struct TopEdgeLineProcessingEffect: View {
    let state: NotchProcessingState
    let metalGlowColor: NSColor

    @State private var pulseStartedAt: TimeInterval?
    @State private var queuedFadeStartedAt: TimeInterval?

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1 / 60)) { timeline in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let completion = completionProgress(seconds: seconds)
                let queuedFade = queuedFadeProgress(seconds: seconds)
                let queuedOpacity = state.isQueued ? 1 : max(0, 1 - queuedFade)
                let isVisible = state.isQueued || queuedOpacity > 0 || completion < 1
                let phase = state.isDistilling ? CGFloat(seconds.truncatingRemainder(dividingBy: 1.95) / 1.95) : 0

                ZStack(alignment: .top) {
                    NotchProcessingMetalField(
                        seconds: seconds,
                        isDistilling: state.isDistilling,
                        queuedOpacity: queuedOpacity,
                        completionProgress: 1,
                        tracerPhase: phase,
                        topCornerRadius: 0,
                        bottomCornerRadius: 0,
                        segmentLength: 0.24,
                        renderShape: .topEdgeLine,
                        glowColor: metalGlowColor
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)

                    if completion < 1 {
                        NotchProcessingMetalField(
                            seconds: seconds,
                            isDistilling: false,
                            queuedOpacity: 0,
                            completionProgress: completion,
                            tracerPhase: phase,
                            topCornerRadius: 0,
                            bottomCornerRadius: 0,
                            segmentLength: 0.24,
                            renderShape: .topEdgeLine,
                            glowColor: metalGlowColor
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height + 28)
                        .offset(y: -2)
                    }
                }
                .opacity(isVisible ? 1 : 0)
                .animation(.smooth(duration: 0.28), value: state.isDistilling)
                .animation(.smooth(duration: 0.22), value: state.completionPulse)
            }
        }
        .compositingGroup()
        .onChange(of: state.completionPulse) { _, newValue in
            guard newValue > 0 else {
                pulseStartedAt = nil
                return
            }

            pulseStartedAt = Date().timeIntervalSinceReferenceDate
        }
        .onChange(of: state.isQueued) { _, isQueued in
            queuedFadeStartedAt = isQueued ? nil : Date().timeIntervalSinceReferenceDate
        }
    }

    private func completionProgress(seconds: TimeInterval) -> CGFloat {
        guard let pulseStartedAt else {
            return 1
        }

        let duration: TimeInterval = 0.72
        let elapsed = seconds - pulseStartedAt
        guard elapsed >= 0, elapsed <= duration else {
            return 1
        }

        return CGFloat(elapsed / duration)
    }

    private func queuedFadeProgress(seconds: TimeInterval) -> CGFloat {
        guard let queuedFadeStartedAt else {
            return 1
        }

        let duration: TimeInterval = 0.7
        let elapsed = seconds - queuedFadeStartedAt
        guard elapsed >= 0, elapsed <= duration else {
            return 1
        }

        let progress = CGFloat(elapsed / duration)

        return progress * progress * (3 - (2 * progress))
    }
}

enum NotchGlowShape: Float {
    case notch = 0
    case topEdgeLine = 1
}

struct NotchGlowField: View, Animatable {
    @ObservedObject private var appearanceSettings = NotchAppearanceSettings.shared

    var strength: CGFloat
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var topCornerRadius: CGFloat
    var bottomCornerRadius: CGFloat
    let topOffset: CGFloat
    let shape: NotchGlowShape

    init(
        strength: CGFloat,
        notchSize: CGSize,
        topCornerRadius: CGFloat = 6,
        bottomCornerRadius: CGFloat = 14,
        topOffset: CGFloat = 0,
        shape: NotchGlowShape = .notch
    ) {
        self.strength = strength
        notchWidth = notchSize.width
        notchHeight = notchSize.height
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.topOffset = topOffset
        self.shape = shape
    }

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>>> {
        get {
            AnimatablePair(
                strength,
                AnimatablePair(
                    notchWidth,
                    AnimatablePair(
                        notchHeight,
                        AnimatablePair(topCornerRadius, bottomCornerRadius)
                    )
                )
            )
        }
        set {
            strength = newValue.first
            notchWidth = newValue.second.first
            notchHeight = newValue.second.second.first
            topCornerRadius = newValue.second.second.second.first
            bottomCornerRadius = newValue.second.second.second.second
        }
    }

    var body: some View {
        NotchGlowMetalView(
            strength: strength,
            notchSize: CGSize(width: notchWidth, height: notchHeight),
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            topOffset: topOffset,
            shape: shape,
            glowColor: appearanceSettings.nsGlowColor
        )
    }
}

private struct NotchGlowMetalView: NSViewRepresentable {
    let strength: CGFloat
    let notchSize: CGSize
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    let topOffset: CGFloat
    let shape: NotchGlowShape
    let glowColor: NSColor

    func makeNSView(context: Context) -> NotchGlowRenderView {
        NotchGlowRenderView()
    }

    func updateNSView(_ nsView: NotchGlowRenderView, context: Context) {
        nsView.update(
            strength: strength,
            notchSize: notchSize,
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            topOffset: topOffset,
            shape: shape,
            glowColor: glowColor
        )
    }
}

private struct NotchGlowUniforms {
    var sizeStrengthTime: SIMD4<Float>
    var notchGain: SIMD4<Float>
    var glowColor: SIMD4<Float>
    var shape: SIMD4<Float>
}

final class NotchGlowRenderView: NSView {
    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLRenderPipelineState?

    private var strength: CGFloat = 0
    private var notchSize: CGSize = .zero
    private var topCornerRadius: CGFloat = 6
    private var bottomCornerRadius: CGFloat = 14
    private var topOffset: CGFloat = 0
    private var shape: NotchGlowShape = .notch
    private var glowColor: NSColor = .systemCyan

    override init(frame frameRect: NSRect) {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()

        if let device,
           let library = device.makeDefaultLibrary(),
           let vertexFunction = library.makeFunction(name: "notchGlowVertex"),
           let fragmentFunction = library.makeFunction(name: "notchGlowFragment") {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].rgbBlendOperation = .add
            descriptor.colorAttachments[0].alphaBlendOperation = .add
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            pipelineState = try? device.makeRenderPipelineState(descriptor: descriptor)
        } else {
            pipelineState = nil
        }

        super.init(frame: frameRect)

        wantsLayer = true
        layer = metalLayer
        metalLayer.device = device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.backgroundColor = NSColor.clear.cgColor
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        syncDrawableMetrics()

        if #available(macOS 26.0, *) {
            metalLayer.preferredDynamicRange = .constrainedHigh
            metalLayer.contentsHeadroom = 2.4
        } else {
            metalLayer.wantsExtendedDynamicRangeContent = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func layout() {
        super.layout()
        syncDrawableMetrics()
        render()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncDrawableMetrics()
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableMetrics()
        render()
    }

    func update(
        strength: CGFloat,
        notchSize: CGSize,
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat,
        topOffset: CGFloat,
        shape: NotchGlowShape,
        glowColor: NSColor
    ) {
        self.strength = strength
        self.notchSize = notchSize
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.topOffset = topOffset
        self.shape = shape
        self.glowColor = glowColor.usingColorSpace(.deviceRGB) ?? glowColor
        render()
    }

    private func syncDrawableMetrics() {
        let scale = window?.backingScaleFactor ?? window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.rasterizationScale = scale
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
    }

    private func render() {
        guard
            bounds.width > 1,
            bounds.height > 1,
            let drawable = metalLayer.nextDrawable(),
            let commandQueue,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let pipelineState
        else {
            return
        }

        let scale = Float(metalLayer.contentsScale)
        var uniforms = NotchGlowUniforms(
            sizeStrengthTime: SIMD4(
                Float(bounds.width) * scale,
                Float(bounds.height) * scale,
                Float(strength),
                Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 120))
            ),
            notchGain: SIMD4(
                Float(notchSize.width) * scale,
                Float(notchSize.height) * scale,
                1.85,
                0
            ),
            glowColor: SIMD4(
                Float(glowColor.redComponent),
                Float(glowColor.greenComponent),
                Float(glowColor.blueComponent),
                0
            ),
            shape: SIMD4(
                Float(topCornerRadius) * scale,
                Float(bottomCornerRadius) * scale,
                Float(topOffset) * scale,
                shape.rawValue
            )
        )

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = drawable.texture
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<NotchGlowUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
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
