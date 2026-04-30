import AppKit
import Metal
import QuartzCore
import simd
import SwiftUI

struct NotchProcessingEffect: View {
    let state: NotchProcessingState
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    let metalGlowColor: NSColor
    var motionDurationScale: TimeInterval = 1
    var segmentLengthScale: CGFloat = 1

    var body: some View {
        EmptyView()
    }
}

enum NotchProcessingRenderShape: Float {
    case notch = 0
    case topEdgeLine = 1
}

struct NotchProcessingMetalField: NSViewRepresentable {
    let seconds: TimeInterval
    let isDistilling: Bool
    let queuedOpacity: CGFloat
    let completionProgress: CGFloat
    let tracerPhase: CGFloat
    let topCornerRadius: CGFloat
    let bottomCornerRadius: CGFloat
    let segmentLength: CGFloat
    let renderShape: NotchProcessingRenderShape
    let glowColor: NSColor

    func makeNSView(context: Context) -> NotchProcessingRenderView {
        NotchProcessingRenderView()
    }

    func updateNSView(_ nsView: NotchProcessingRenderView, context: Context) {
        nsView.update(
            seconds: seconds,
            isDistilling: isDistilling,
            queuedOpacity: queuedOpacity,
            completionProgress: completionProgress,
            tracerPhase: tracerPhase,
            topCornerRadius: topCornerRadius,
            bottomCornerRadius: bottomCornerRadius,
            segmentLength: segmentLength,
            renderShape: renderShape,
            glowColor: glowColor
        )
    }
}

struct NotchProcessingUniforms {
    var sizeTimeShape: SIMD4<Float>
    var state: SIMD4<Float>
    var shape: SIMD4<Float>
    var glowColor: SIMD4<Float>
}

final class NotchProcessingRenderView: NSView {
    private let metalLayer = CAMetalLayer()
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLRenderPipelineState?

    private var seconds: TimeInterval = 0
    private var isDistilling = false
    private var queuedOpacity: CGFloat = 0
    private var completionProgress: CGFloat = 1
    private var tracerPhase: CGFloat = 0
    private var topCornerRadius: CGFloat = 6
    private var bottomCornerRadius: CGFloat = 14
    private var segmentLength: CGFloat = 0.17
    private var renderShape: NotchProcessingRenderShape = .notch
    private var glowColor: NSColor = .systemCyan

    override init(frame frameRect: NSRect) {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        commandQueue = device?.makeCommandQueue()

        if let device,
           let library = device.makeDefaultLibrary(),
           let vertexFunction = library.makeFunction(name: "notchGlowVertex"),
           let fragmentFunction = library.makeFunction(name: "notchProcessingFragment") {
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
        seconds: TimeInterval,
        isDistilling: Bool,
        queuedOpacity: CGFloat,
        completionProgress: CGFloat,
        tracerPhase: CGFloat,
        topCornerRadius: CGFloat,
        bottomCornerRadius: CGFloat,
        segmentLength: CGFloat,
        renderShape: NotchProcessingRenderShape,
        glowColor: NSColor
    ) {
        self.seconds = seconds
        self.isDistilling = isDistilling
        self.queuedOpacity = queuedOpacity
        self.completionProgress = completionProgress
        self.tracerPhase = tracerPhase
        self.topCornerRadius = topCornerRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.segmentLength = segmentLength
        self.renderShape = renderShape
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
        var uniforms = NotchProcessingUniforms(
            sizeTimeShape: SIMD4(
                Float(bounds.width) * scale,
                Float(bounds.height) * scale,
                Float(seconds.truncatingRemainder(dividingBy: 120)),
                renderShape.rawValue
            ),
            state: SIMD4(
                isDistilling ? 1 : 0,
                Float(max(0, min(1, queuedOpacity))),
                Float(max(0, min(1, completionProgress))),
                Float(max(0, min(1, tracerPhase)))
            ),
            shape: SIMD4(
                Float(topCornerRadius) * scale,
                Float(bottomCornerRadius) * scale,
                Float(segmentLength),
                0
            ),
            glowColor: SIMD4(
                Float(glowColor.redComponent),
                Float(glowColor.greenComponent),
                Float(glowColor.blueComponent),
                1.85
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
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<NotchProcessingUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

private final class NotchProcessingMotionClock {
    static let shared = NotchProcessingMotionClock()

    private var phase: CGFloat = 0
    private var lastSeconds: TimeInterval?

    func phase(at seconds: TimeInterval, duration: TimeInterval) -> CGFloat {
        guard duration > 0 else {
            return phase
        }

        defer {
            lastSeconds = seconds
        }

        guard let lastSeconds else {
            return phase
        }

        let elapsed = max(0, min(seconds - lastSeconds, 0.12))
        phase = (phase + CGFloat(elapsed / duration)).truncatingRemainder(dividingBy: 1)

        return phase
    }
}
