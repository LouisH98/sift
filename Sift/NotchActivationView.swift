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
    @ObservedObject var notchModel: NotchAnimationModel
    @State private var processingFadeStartedAt: TimeInterval?

    let notchSize: CGSize
    let size: CGSize
    let usesTopEdgeLine: Bool

    private let topEdgeLineHeight: CGFloat = 5

    private var glowStrength: CGFloat {
        guard appearanceSettings.isGlowEnabled else {
            return 0
        }

        return model.glowStrengthForTransition
    }

    private var isDistilling: Bool {
        processor.notchProcessingState.isDistilling
    }

    private var canRenderProcessingGlow: Bool {
        !notchModel.isPanelVisible
    }

    private var isProcessingGlowActive: Bool {
        canRenderProcessingGlow && (isDistilling || processingFadeStartedAt != nil)
    }

    private var processingGlowStrength: CGFloat {
        guard appearanceSettings.isGlowEnabled, canRenderProcessingGlow, isDistilling else {
            return 0
        }

        return NotchProcessingGlowFade.steadyStrength
    }

    private var displayedGlowStrength: CGFloat {
        isProcessingGlowActive ? processingGlowStrength : glowStrength
    }

    private var glowColorMotion: CGFloat {
        isProcessingGlowActive ? 1 : min(1, glowStrength * 0.86)
    }

    private var shadowGlowStrength: CGFloat {
        isProcessingGlowActive ? processingGlowStrength * 0.74 : glowStrength
    }

    private var surfaceOpacity: CGFloat {
        let hoverOpacity = model.isHovered ? 0.82 * NotchActivationHoverModel.smoothProximity(model.proximity) : 0
        let processingOpacity: CGFloat = processor.notchProcessingState.isDistilling ? 0.16 : 0

        return max(hoverOpacity, processingOpacity)
    }

    private var activationSize: CGSize {
        usesTopEdgeLine ? CGSize(width: notchSize.width, height: topEdgeLineHeight) : notchSize
    }

    private var feedbackProgress: CGFloat {
        NotchActivationHoverModel.smoothProximity(model.activationProgress)
    }

    private var feedbackSize: CGSize {
        CGSize(
            width: activationSize.width + (feedbackProgress * (usesTopEdgeLine ? 82 : 22)),
            height: activationSize.height + (feedbackProgress * (usesTopEdgeLine ? 20 : 9))
        )
    }

    private var glowShape: NotchGlowShape {
        usesTopEdgeLine ? .topEdgeLine : .notch
    }

    private var glowStrengthAnimation: Animation? {
        if isDistilling {
            return nil
        }

        if processingFadeStartedAt != nil {
            return .smooth(duration: NotchProcessingGlowFade.duration)
        }

        return .smooth(duration: 0.08)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if appearanceSettings.isGlowEnabled {
                if let processingFadeStartedAt {
                    TimelineView(.animation(minimumInterval: 1 / 120)) { timeline in
                        let fadeStrength = NotchProcessingGlowFade.strength(
                            startedAt: processingFadeStartedAt,
                            seconds: timeline.date.timeIntervalSinceReferenceDate
                        )

                        glowField(
                            strength: fadeStrength,
                            colorMotion: NotchProcessingGlowFade.motionStrength(for: fadeStrength)
                        )
                    }
                } else {
                    glowField(strength: displayedGlowStrength, colorMotion: glowColorMotion)
                }

                if usesTopEdgeLine {
                    notchSurface
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .preferredColorScheme(.dark)
        .onChange(of: isDistilling) { _, isDistilling in
            updateProcessingFade(isDistilling: isDistilling)
        }
        .onChange(of: notchModel.isPanelVisible) { _, isPanelVisible in
            if isPanelVisible {
                processingFadeStartedAt = nil
            }
        }
    }

    private func glowField(strength: CGFloat, colorMotion: CGFloat) -> some View {
        NotchGlowField(
            strength: strength,
            notchSize: feedbackSize,
            shape: glowShape,
            colorMotion: colorMotion
        )
            .opacity(strength > 0.01 ? 1 : 0)
            .animation(glowStrengthAnimation, value: strength)
            .animation(.smooth(duration: 0.14), value: feedbackSize.width)
            .animation(.smooth(duration: 0.14), value: feedbackSize.height)
            .animation(.smooth(duration: NotchProcessingGlowFade.duration), value: isDistilling)
            .allowsHitTesting(false)
    }

    private func updateProcessingFade(isDistilling: Bool) {
        guard canRenderProcessingGlow else {
            processingFadeStartedAt = nil
            return
        }

        if isDistilling {
            processingFadeStartedAt = nil
            return
        }

        let startedAt = Date().timeIntervalSinceReferenceDate
        processingFadeStartedAt = startedAt

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(NotchProcessingGlowFade.duration))
            if processingFadeStartedAt == startedAt {
                processingFadeStartedAt = nil
            }
        }
    }

    @ViewBuilder
    private var notchSurface: some View {
        if usesTopEdgeLine {
            Capsule()
                .fill(.clear)
                .frame(width: feedbackSize.width, height: feedbackSize.height)
                .animation(.smooth(duration: 0.12), value: model.isHovered)
                .animation(.smooth(duration: 0.08), value: model.isPressed)
                .animation(.smooth(duration: 0.14), value: model.activationProgress)
                .animation(.smooth(duration: 1.15), value: processor.notchProcessingState.isDistilling)
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
                .shadow(color: appearanceSettings.glowColor.opacity(shadowGlowStrength * 0.34), radius: 18 + (shadowGlowStrength * 18), x: 0, y: 8)
                .shadow(color: appearanceSettings.glowColor.opacity(shadowGlowStrength * 0.22), radius: 34 + (shadowGlowStrength * 24), x: 0, y: 18)
                .scaleEffect(
                    x: 1 + (feedbackProgress * 0.05),
                    y: 1 + (feedbackProgress * 0.12),
                    anchor: .top
                )
                .animation(.smooth(duration: 0.12), value: model.isHovered)
                .animation(.smooth(duration: 0.08), value: model.isPressed)
                .animation(.smooth(duration: 0.14), value: model.activationProgress)
                .animation(.smooth(duration: 1.15), value: processor.notchProcessingState.isDistilling)
        }
    }
}

enum NotchProcessingGlowFade {
    static let steadyStrength: CGFloat = 0.3
    static let duration: TimeInterval = 1.15

    static func strength(startedAt: TimeInterval, seconds: TimeInterval) -> CGFloat {
        let elapsed = seconds - startedAt
        guard elapsed >= 0, elapsed <= duration else {
            return 0
        }

        let progress = CGFloat(elapsed / duration)
        let fade = 1 - smootherStep(progress)

        return steadyStrength * fade
    }

    static func motionStrength(for strength: CGFloat) -> CGFloat {
        max(0, min(1, strength / max(steadyStrength, 0.001)))
    }

    private static func smootherStep(_ progress: CGFloat) -> CGFloat {
        let clamped = max(0, min(1, progress))

        return clamped * clamped * clamped * (clamped * ((clamped * 6) - 15) + 10)
    }
}

enum NotchGlowClock {
    private static let startedAt = CACurrentMediaTime()

    static var seconds: TimeInterval {
        CACurrentMediaTime() - startedAt
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
    let colorMotion: CGFloat

    init(
        strength: CGFloat,
        notchSize: CGSize,
        topCornerRadius: CGFloat = 6,
        bottomCornerRadius: CGFloat = 14,
        topOffset: CGFloat = 0,
        shape: NotchGlowShape = .notch,
        colorMotion: CGFloat = 0
    ) {
        self.strength = strength
        notchWidth = notchSize.width
        notchHeight = notchSize.height
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.topOffset = topOffset
        self.shape = shape
        self.colorMotion = colorMotion
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

    @ViewBuilder
    var body: some View {
        if colorMotion > 0.001 {
            TimelineView(.animation(minimumInterval: 1 / 120)) { timeline in
                metalView(renderTime: NotchGlowClock.seconds)
            }
        } else {
            metalView(renderTime: NotchGlowClock.seconds)
        }
    }

    private func metalView(renderTime: TimeInterval) -> some View {
        NotchGlowMetalView(
            strength: strength,
            notchSize: CGSize(width: notchWidth, height: notchHeight),
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            topOffset: topOffset,
            shape: shape,
            glowColor: appearanceSettings.nsGlowColor,
            renderTime: renderTime,
            colorMotion: colorMotion
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
    let renderTime: TimeInterval
    let colorMotion: CGFloat

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
            glowColor: glowColor,
            renderTime: renderTime,
            colorMotion: colorMotion
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
    private var renderTime: TimeInterval = 0
    private var colorMotion: CGFloat = 0

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
        glowColor: NSColor,
        renderTime: TimeInterval,
        colorMotion: CGFloat
    ) {
        self.strength = strength
        self.notchSize = notchSize
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.topOffset = topOffset
        self.shape = shape
        self.glowColor = glowColor.usingColorSpace(.deviceRGB) ?? glowColor
        self.renderTime = renderTime
        self.colorMotion = colorMotion
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
                Float(renderTime)
            ),
            notchGain: SIMD4(
                Float(notchSize.width) * scale,
                Float(notchSize.height) * scale,
                1.85,
                Float(max(0, min(1, colorMotion)))
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
